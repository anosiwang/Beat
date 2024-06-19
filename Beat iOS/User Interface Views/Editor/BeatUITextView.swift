//
//  BeatUITextView.swift
//  Beat iOS
//
//  Created by Lauri-Matti Parppei on 14.5.2022.
//  Copyright © 2022 Lauri-Matti Parppei. All rights reserved.
//

import UIKit
import BeatCore
import BeatParsing

@objc protocol BeatTextEditorDelegate:BeatEditorDelegate {
	@objc var revisionTracking:BeatRevisions { get }
	@objc var formattingActions:BeatEditorFormattingActions { get }
	@objc var textActions:BeatTextIO { get }
	@objc var formatting:BeatEditorFormatting { get }
	
	//@property (nonatomic, weak) IBOutlet UIBarButtonItem* screenplayButton;
	@objc var screenplayButton:UIBarButtonItem? { get }
	@objc var dismissKeyboardButton:UIBarButtonItem? { get }
	
	@objc func textViewDidEndSelection(_ textView:UITextView, selectedRange:NSRange)
}

class BeatUITextView: UITextView, BeatTextEditor, UIEditMenuInteractionDelegate, InputAssistantViewDelegate {

	//@IBInspectable var documentWidth:CGFloat = 640
	@IBOutlet weak var editorDelegate:BeatTextEditorDelegate?
	@IBOutlet weak var enclosingScrollView:BeatScrollView!
	@IBOutlet weak var pageView:UIView!
	
	@objc public var assistantView:InputAssistantView?
	
	@objc public var floatingCursor = false
	
	var insets:UIEdgeInsets = UIEdgeInsets(top: 50, left: 0, bottom: 50, right: 0)
	var pinchRecognizer = UIGestureRecognizer()
	var customLayoutManager:BeatLayoutManager
	
	var mobileMode:Bool { return UIDevice.current.userInterfaceIdiom == .phone }
	var mobileKeyboardManager:KeyboardManager?
	
	var mobileDismissButton:UIBarButtonItem?
	
	class func linePadding() -> CGFloat {
		// We'll use very tight padding for iPhone
		if UIDevice.current.userInterfaceIdiom == .phone {
			return 30.0
		} else {
			return 70.0
		}
	}
	
	// MARK: - Initializers
	
	/// This class function creates and sets up the main editor text view. We can't create a text view in IB, because layout manager can't be replaced when initializing through `NSCoder`.
	@objc class func createTextView(editorDelegate:BeatEditorDelegate, frame:CGRect, pageView:BeatPageView, scrollView:BeatScrollView) -> BeatUITextView {
		// First create core text system
		let textContainer = NSTextContainer()
		let layoutManager = BeatLayoutManager(delegate: editorDelegate)
		let textStorage = NSTextStorage(string: "")
		
		// Set up layout manager & text storage
		layoutManager.addTextContainer(textContainer)
		textStorage.addLayoutManager(layoutManager)
		layoutManager.delegate = layoutManager
		
		// Create the text view and connect the container + layout manager
		let textView = BeatUITextView(frame: frame, textContainer: textContainer, layoutManager: layoutManager)
		textView.autoresizingMask = [.flexibleHeight, .flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
				
		// Set up the container views
		textView.pageView = pageView
		textView.enclosingScrollView = scrollView
		
		// Set up assistant view
		textView.assistantView = InputAssistantView(editorDelegate: editorDelegate, inputAssistantDelegate: textView)
		textView.assistantView?.attach(to: textView)
		
		// The same object will be responsible for all of these delegations
		textView.editorDelegate = editorDelegate as? BeatTextEditorDelegate
		textView.delegate = editorDelegate as? UITextViewDelegate
		textView.inputDelegate = editorDelegate as? UITextInputDelegate
		
		textView.setup()
				
		return textView
	}
	
	init(frame: CGRect, textContainer: NSTextContainer?, layoutManager:BeatLayoutManager) {
		customLayoutManager = layoutManager
		super.init(frame: frame, textContainer: textContainer)
	}
	
	override var textLayoutManager: NSTextLayoutManager? {
		return nil
	}
	
	required init?(coder: NSCoder) {
		customLayoutManager = BeatLayoutManager()
		super.init(coder: coder)

		self.textStorage.removeLayoutManager(self.textStorage.layoutManagers.first!)
		
		customLayoutManager.addTextContainer(self.textContainer)
		customLayoutManager.textStorage = self.textStorage
		
		self.textContainer.replaceLayoutManager(customLayoutManager)
	}
	
	
	// MARK: - Layout manager
	
	override var layoutManager: NSLayoutManager {
		return customLayoutManager
	}
	
	
	// MARK: - Setup
	
	override func awakeFromNib() {
		super.awakeFromNib()
		setup()
	}
	
	func setup() {
		// Delegates
		enclosingScrollView?.delegate = self
		
		self.enclosingScrollView.keyboardDismissMode = .onDrag
		
		// Text container setup
		self.textContainer.widthTracksTextView = false
		self.textContainer.heightTracksTextView = false
		// Set text container size. Note that in mobile mode, this varies!
		self.textContainer.size = CGSize(width: self.documentWidth, height: self.textContainer.size.height)
		self.textContainer.lineFragmentPadding = BeatUITextView.linePadding()
		
		// Text view behavior
		self.smartDashesType = .no
		self.smartQuotesType = .no
		self.smartInsertDeleteType = .no
		self.keyboardAppearance = .dark
				
		resizePaper()
		resize()
		
		setupInputAssistantButtons()
		
		if !mobileMode {
			// Tablet setup. We'll have an external scroll view on iPad, so let's disable scroll for text view.
			isScrollEnabled = false
			self.textContainerInset = insets
		} else {
			// Mobile mode setup
			self.contentInsetAdjustmentBehavior = .automatic
			
			self.mobileKeyboardManager = KeyboardManager()
			self.mobileKeyboardManager?.delegate = self
			
			// Disable pinch gesture recognizer
			let pinchGestureRecognizer = UIPinchGestureRecognizer(target: nil, action: nil)
			pinchGestureRecognizer.delegate = self
			self.addGestureRecognizer(pinchGestureRecognizer)
		}
		
		// Set a new frame for this view for mobile mode
		if mobileMode, let contentView = self.enclosingScrollView.superview {
			self.frame = CGRectMake(0.0, 0.0, contentView.frame.width, contentView.frame.height)
			self.autoresizingMask = [.flexibleWidth, .flexibleHeight, .flexibleTopMargin, .flexibleBottomMargin, .flexibleLeftMargin, .flexibleRightMargin]
			
			self.maximumZoomScale = 2.0
			self.minimumZoomScale = 1.0
		}
	}
	
	
	
	// MARK: - Document view width
	
	@objc var documentWidth:CGFloat {
		var width = 0.0
		let padding = BeatUITextView.linePadding()
		
		guard let delegate = self.editorDelegate else { return 0.0 }
		
		if delegate.pageSize == .A4 {
			width = BeatFonts.characterWidth() * 60
		} else {
			width = BeatFonts.characterWidth() * 62
		}
		
		width += padding * 2
		
		// For iPhone, we'll fit the viewport to view
		if mobileMode {
			let availableWidth = self.frame.size.width * (1/self.zoomScale)
			width = min(availableWidth, width)
		}
		
		return width
	}
	
	private var isUpdatingLayout = false
	override func layoutSubviews() {
		super.layoutSubviews()
		
		// Avoid infinite loop
		guard !isUpdatingLayout else { return }
		
		isUpdatingLayout = true
		mobileViewResize()
		isUpdatingLayout = false
	}
	

	// MARK: - Mobile sizing
	
	var mobileScale:CGFloat {
		let scale = BeatUserDefaults.shared().getInteger(BeatSettingPhoneFontSize)
		return 1.1 + CGFloat(scale) * 0.15
		
	}
	
	@objc public func updateMobileScale() {
		self.zoomScale = mobileScale
	}
	
	func mobileViewResize() {
		let documentWidth = self.documentWidth
		self.textContainer.size.width = documentWidth
		
		let factor = 1 / self.zoomScale
		let scaledFrame = self.frame.width * factor
		
		var insets = self.insets
		
		if (documentWidth < scaledFrame) {
			insets.left = ((self.frame.size.width - documentWidth - BeatUITextView.linePadding() * 2) / 2) * factor
		}
		
		self.textContainerInset = insets
	}
	
	
	// MARK: - Scroll to range
	
	@objc func scroll(to line: Line!) {
		selectAndScroll(to: line.textRange())
	}
	
	func scroll(to range: NSRange) {
		self.scroll(to:range, animated: true)
	}
			
	func scroll(to range: NSRange, animated:Bool = true) {
		if mobileMode {
			super.scrollRangeToVisible(range)
			return
		}

		// Current bounds
		let bounds = self.enclosingScrollView.bounds
		
		// The *actually* visible frame (why won't iOS give this automatically?)
		let visible = CGRectMake(bounds.origin.x, bounds.origin.y, bounds.width, bounds.height - self.enclosingScrollView.adjustedContentInset.bottom - self.enclosingScrollView.contentInset.bottom)
				
		// Current selection frame
		var selectionRect = self.rectForRange(range: self.selectedRange)
		if selectionRect.size.width < 1.0 { selectionRect.size.width += 1.0 }
		
		// Account for top margin
		selectionRect.origin.y += self.textContainerInset.top
		
		let scaledRect = convert(selectionRect, to: self.enclosingScrollView)

		// If the rect is not visible, scroll to that range
		if CGRectIntersection(scaledRect, visible).height < 16.0 {
			self.enclosingScrollView.safelyScrollRectToVisible(scaledRect, animated: animated)
		}

	}
	
	override func scrollRangeToVisible(_ range: NSRange) {
		self.scroll(to:range)
		//super.scrollRangeToVisible(range)
	}
	
	func scroll(to range: NSRange, callback callbackBlock: (() -> Void)!) {
		scroll(to: range)
		callbackBlock()
	}
	
	func scroll(to scene: OutlineScene!) {
		selectAndScroll(to: scene.line.textRange())
	}
	
	@objc func selectAndScroll(to range:NSRange) {
		self.selectedRange = NSMakeRange(NSMaxRange(range), 0)
		self.scroll(to: range)
	}
	

	// MARK: - Dialogue input
	
	func shouldCancelCharacterInput() -> Bool {
		guard let editorDelegate = self.editorDelegate,
			  let line = editorDelegate.currentLine()
		else { return true }
		
		/// We'll return `true` when current line is empty (what is this)
		if editorDelegate.characterInput && line.string.count == 0 {
			return true
		} else {
			return false
		}
	}
	
	@objc func cancelCharacterInput() {
		guard let editorDelegate = self.editorDelegate else { return }
		
		let line = editorDelegate.characterInputForLine
		
		editorDelegate.characterInput = false
		editorDelegate.characterInputForLine = nil
		
		let paragraphStyle = NSMutableParagraphStyle()
		paragraphStyle.firstLineHeadIndent = 0.0
		paragraphStyle.minimumLineHeight = self.editorDelegate?.editorStyles.page().lineHeight ?? 12.0
		
		let attributes:[NSAttributedString.Key:Any] = [
			NSAttributedString.Key.font: editorDelegate.fonts.regular,
			NSAttributedString.Key.paragraphStyle: paragraphStyle
		]
		
		self.updateAssistingViews()
		
		self.typingAttributes = attributes
		self.setNeedsDisplay()
		self.setNeedsLayout()
		
		editorDelegate.setTypeAndFormat(line, type: .empty)
	}
		

	// MARK: - Rects for ranges
	
	@objc func rectForRange (range: NSRange) -> CGRect {
		let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
		let rect = self.layoutManager.boundingRect(forGlyphRange: glyphRange, in: self.textContainer)
		
		return rect
	}
	
	
	// MARK: - Touch events
	
	var selectedRangeBeforeTouch = NSRange(location: -1, length: 0)
	
	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		// Convert to enclosing scroll view coordinate
		if !mobileMode {
			for touch in touches {
				touch.location(in: self.enclosingScrollView)
			}
		}
		
		super.touchesBegan(touches, with: event)
	}
	
	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		// Convert to enclosing scroll view coordinate
		if !mobileMode {
			for touch in touches {
				touch.location(in: self.enclosingScrollView)
			}
		}
		
		super.touchesMoved(touches, with: event)
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		if !mobileMode {
			for touch in touches {
				touch.location(in: self.enclosingScrollView)
			}
		}
				
		super.touchesEnded(touches, with: event)
	}
	
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		super.touchesCancelled(touches, with: event)
	}
	
	
	override func beginFloatingCursor(at point: CGPoint) {
		super.beginFloatingCursor(at: point)
		
		floatingCursor = true
		self.selectedRangeBeforeTouch = self.selectedRange
	}
	
	override func endFloatingCursor() {
		super.endFloatingCursor()

		floatingCursor = false
		
		if self.selectedRangeBeforeTouch != self.selectedRange {
			self.editorDelegate?.textViewDidEndSelection(self, selectedRange: self.selectedRange)
		}
	}
	
	// MARK: - Update assisting views
	
	@objc func updateAssistingViews () {
		guard let editorDelegate = self.editorDelegate
		else { return }
		
		if (editorDelegate.currentLine().isAnyParenthetical()) {
			self.autocapitalizationType = .none
		} else {
			self.autocapitalizationType = .sentences
		}
		
		assistantView?.reloadData()
	}
	
	
	// MARK: - Menu
	
	override func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
		var originalActions = suggestedActions
		var actions:[UIMenuElement] = []
		
		for m in suggestedActions {
			guard let menu = m as? UIMenu else { continue }
			
			if menu.identifier == .standardEdit ||
				menu.identifier == .replace ||
				menu.identifier == .find
			{
				actions.append(menu)
				originalActions.removeObject(object: menu)
			}
		}
		
		guard let line = editorDelegate?.currentLine() else { return UIMenu(children: actions) }
		
		if line.isAnyDialogue() || line.type == .action {
			let formatMenu = UIMenu(image: UIImage(systemName: "bold.italic.underline"), options: [], children: [
				UIAction(image: UIImage(named: "button_bold")) { _ in
					self.editorDelegate?.formattingActions.makeBold(nil)
				},
				UIAction(image: UIImage(named: "button_italic")) { _ in
					self.editorDelegate?.formattingActions.makeItalic(nil)
				},
				UIAction(image: UIImage(systemName: "underline")) { _ in
					self.editorDelegate?.formattingActions.makeUnderlined(nil)
				}
			])
			
			actions.append(formatMenu)
		}
		
		if self.selectedRange.length > 0 {
			let revisionMenu = UIMenu(subtitle: "Revisions", image: UIImage(systemName: "asterisk"), options: [], children: [
				UIAction(title: "Mark As Revised") { _ in
					self.editorDelegate?.revisionTracking.markerAction(.addition)
				},
				UIMenu(options: [.destructive, .displayInline], children: [
					UIAction(title: "Clear Revisions") { _ in
						self.editorDelegate?.revisionTracking.markerAction(.none)
					}
				])
			])
			
			actions.append(revisionMenu)
		}
		
		let textIO = editorDelegate?.textActions
		let sceneMenu = UIMenu(title: "Scene...", options: [], children: [
			UIAction(title: "Omit Scene") { _ in
				self.editorDelegate?.formattingActions.omitScene(nil)
			},
			UIAction(title: "Make Non-Numbered") { _ in
				self.editorDelegate?.formattingActions.makeSceneNonNumbered(nil)
			},
			UIAction(image: UIImage(named:"color.red")) { _ in
				textIO?.setColor("red", for: self.editorDelegate?.currentScene)
			},
			UIAction(image: UIImage(named:"color.blue")) { _ in
				textIO?.setColor("blue", for: self.editorDelegate?.currentScene)
			},
			UIAction(image: UIImage(named:"color.green")) { _ in
				textIO?.setColor("green", for: self.editorDelegate?.currentScene)
			},
			UIAction(image: UIImage(named:"color.pink")) { _ in
				textIO?.setColor("pink", for: self.editorDelegate?.currentScene)
			},
			UIAction(image: UIImage(named:"color.brown")) { _ in
				textIO?.setColor("brown", for: self.editorDelegate?.currentScene)
			},
			UIAction(image: UIImage(named:"color.cyan")) { _ in
				textIO?.setColor("cyan", for: self.editorDelegate?.currentScene)
			},
			UIAction(image: UIImage(named:"color.orange")) { _ in
				textIO?.setColor("orange", for: self.editorDelegate?.currentScene)
			},
			UIAction(image: UIImage(named:"color.magenta")) { _ in
				textIO?.setColor("magenta", for: self.editorDelegate?.currentScene)
			}
		])
		
		actions.append(sceneMenu)
				
		// Add remaining actions from original menu
		actions.append(contentsOf: originalActions)
		
		let menu = UIMenu(children: actions)
		
		return menu
	}
		
}


// MARK: - Scroll view delegation

extension BeatUITextView: UIScrollViewDelegate {
	func viewForZooming(in scrollView: UIScrollView) -> UIView? {
		return pageView
	}
	
	func scrollViewDidZoom(_ scrollView: UIScrollView) {
		//
	}
	
	func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
		var x = (scrollView.frame.width - pageView.frame.width) / 2
		if (x < 0) { x = 0; }
		
		var frame = pageView!.frame
		frame.origin.x = x
		
		var zoom = scrollView.zoomScale
		
		if (frame.height < scrollView.frame.height) {
			let factor = frame.height / scrollView.frame.height
			zoom = scrollView.zoomScale / factor
		}
		
		UIView.animate(withDuration: 0.1, delay: 0.0, options: .curveLinear) {
			self.pageView.frame = frame
			self.enclosingScrollView.zoomScale = zoom
		} completion: { _ in
			
		}
	}
	
	override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		guard let key = presses.first?.key else { return }
		
		if key.keyCode == .keyboardTab {
			editorDelegate?.handleTabPress()
			return
		}
		else if key.keyCode == .keyboardDeleteOrBackspace {
			// Check if we should cancel character input
			if self.shouldCancelCharacterInput() {
				self.cancelCharacterInput()
				return
			}
		}
		
		super.pressesBegan(presses, with: event)
	}
	
	override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		guard let key = presses.first?.key else { return }

		switch key.keyCode {
		case .keyboardTab:
			return
			
		default:
			super.pressesEnded(presses, with: event)
		}
	}
}

// Specify the decimal place to round to using an enum
public enum RoundingPrecision {
	case ones
	case tenths
	case hundredths
}

// Round to the specific decimal place
public func preciseRound(
	_ value: Double,
	precision: RoundingPrecision = .ones) -> Double
{
	switch precision {
	case .ones:
		return round(value)
	case .tenths:
		return round(value * 10) / 10.0
	case .hundredths:
		return round(value * 100) / 100.0
	}
}


// MARK: - Gesture recognizer delegate for mobile

extension BeatUITextView:UIGestureRecognizerDelegate {
	override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
		if gestureRecognizer is UIPinchGestureRecognizer, mobileMode {
			return false // Disable pinch zoom
		}
		
		return true
	}
}


// MARK: - Input assistant buttons

extension BeatUITextView {
	func setupInputAssistantButtons() {
		self.assistantView?.leadingActions = [
			InputAssistantAction(image: UIImage(systemName: "bubble.left.fill")!, target: self, action: #selector(addCue)),
			InputAssistantAction(image: UIImage(named: "Shortcut.INT")!, target: self, action: #selector(addINT)),
			InputAssistantAction(image: UIImage(named: "Shortcut.EXT")!, target: self, action: #selector(addEXT)),
			InputAssistantAction(image: UIImage(named: "Shortcut.Section")!, target: self, action: #selector(addSection)),
			InputAssistantAction(image: UIImage(named: "Shortcut.Synopsis")!, target: self, action: #selector(addSynopsis))
		]
		self.assistantView?.trailingActions = [
			InputAssistantAction(image: UIImage(systemName: "filemenu.and.selection")!, menu: UIMenu(title: "", children: [
				
				UIMenu(title:"", options: [.displayInline], children: [
					UIMenu(title: "Marker With Color...", children: [
						UIAction(title: "Pink", image: UIImage(named: "color.pink"),  handler: { (_) in
							self.editorDelegate?.textActions.addNewParagraph("[[marker pink:New marker]]", caretPosition: -2)
						}),
						UIAction(title: "Orange", image: UIImage(named: "color.orange"),  handler: { (_) in
							self.editorDelegate?.textActions.addNewParagraph("[[marker orange:New marker]]", caretPosition: -2)
						}),
						UIAction(title: "Purple", image: UIImage(named: "color.purple"),  handler: { (_) in
							self.editorDelegate?.textActions.addNewParagraph("[[marker purple:New marker]]", caretPosition: -2)
						}),
						UIAction(title: "Blue", image: UIImage(named: "color.blue"),  handler: { (_) in
							self.editorDelegate?.textActions.addNewParagraph("[[marker blue:New marker]]", caretPosition: -2)
						}),
						UIAction(title: "Green", image: UIImage(named: "color.green"),  handler: { (_) in
							self.editorDelegate?.textActions.addNewParagraph("[[marker green:New marker]]", caretPosition: -2)
						}),
						UIAction(title: "Red", image: UIImage(named: "color.red"),  handler: { (_) in
							self.editorDelegate?.textActions.addNewParagraph("[[marker red:New marker]]", caretPosition: -2)
						}),
					]),
					UIAction(title: "Add Marker", handler: { (_) in
						self.editorDelegate?.textActions.addNewParagraph("[[marker New marker]]", caretPosition: -2)
					}),
				]),
				
				UIMenu(title: "Transition...", children: [
					UIAction(title: "FADE IN", handler: { (_) in
						self.editorDelegate?.textActions.addNewParagraph("> FADE IN")
					}),
					UIAction(title: "CUT TO:", handler: { (_) in
						self.editorDelegate?.textActions.addNewParagraph("CUT TO:")
					}),
					UIAction(title: "DISSOLVE TO:", handler: { (_) in
						self.editorDelegate?.textActions.addNewParagraph("DISSOLVE TO:")
					}),
					UIAction(title: "FADE OUT", handler: { (_) in
						self.editorDelegate?.textActions.addNewParagraph("> FADE OUT")
					}),
					
				]),
				
				UIAction(title: "Make Centered", handler: { (_) in
					self.editorDelegate?.formattingActions.makeCentered(self)
				}),
				UIAction(title: "Omit", handler: { (_) in
					self.editorDelegate?.formattingActions.makeOmitted(self)
				}),
				UIAction(title: "Note", handler: { (_) in
					self.editorDelegate?.formattingActions.makeNote(self)
				}),
				
				UIMenu(title:"Force element...", children: [
					UIAction(title: "Scene heading", handler: { (_) in
						self.editorDelegate?.formattingActions.forceHeading(self)
					}),
					UIAction(title: "Action", handler: { (_) in
						self.editorDelegate?.formattingActions.forceAction(self)
					}),
					UIAction(title: "Character", handler: { (_) in
						self.editorDelegate?.formattingActions.forceCharacter(self)
					}),
					UIAction(title: "Transition", handler: { (_) in
						self.editorDelegate?.formattingActions.forceTransition(self)
					}),
					UIAction(title: "Lyrics", handler: { (_) in
						self.editorDelegate?.formattingActions.forceLyrics(self)
					}),
				]),
				
				UIMenu(title:"", options: [.displayInline], preferredElementSize: .small, children: [
					UIAction(image: UIImage(systemName: "bold"), handler: { (_) in
						self.editorDelegate?.formattingActions.makeBold(self)
					}),
					UIAction(image: UIImage(systemName: "italic"), handler: { (_) in
						self.editorDelegate?.formattingActions.makeItalic(self)
					}),
					UIAction(image: UIImage(systemName: "underline"), handler: { (_) in
						self.editorDelegate?.formattingActions.makeUnderlined(nil)
					})
				]),

			])),
			InputAssistantAction(image: UIImage(systemName: "arrow.uturn.backward")!, target: self, action: #selector(undo)),
			InputAssistantAction(image: UIImage(systemName: "arrow.uturn.forward")!, target: self, action: #selector(redo))
		]
	}
	
	@objc func addINT() {
		self.editorDelegate?.textActions.addNewParagraph("INT. ")
	}
	
	@objc func addSection() {
		self.editorDelegate?.textActions.addNewParagraph("# ")
	}
	
	@objc func addSynopsis() {
		self.editorDelegate?.textActions.addNewParagraph("= ")
	}
	
	@objc func addEXT() {
		self.editorDelegate?.textActions.addNewParagraph("EXT. ")
	}
	
	@objc func addCue() {
		self.editorDelegate?.formattingActions.addCue()
		self.updateAssistingViews()
	}
	
	@objc func undo() {
		self.editorDelegate?.undoManager.undo()
	}
	@objc func redo() {
		self.editorDelegate?.undoManager.redo()
	}
		
	
	func inputAssistantView(_ inputAssistantView: InputAssistantView, didSelectSuggestion suggestion: String) {
		guard let editorDelegate = self.editorDelegate, suggestion.count > 0 else { return }
		
		if suggestion[0] == "(" && editorDelegate.currentLine().isAnyCharacter() {
			// This is a character extension
			editorDelegate.textActions.addCueExtension(suggestion, on: editorDelegate.currentLine())
		} else {
			// This is something else
			let r = NSMakeRange(editorDelegate.currentLine().position, editorDelegate.currentLine().length)
			editorDelegate.replace(r, with: suggestion)
		}
	}
}

// MARK: - Mobile keyboard manager

extension BeatUITextView:KeyboardManagerDelegate {
	func keyboardWillShow(with size: CGSize, animationTime: Double) {
		let animator = UIViewPropertyAnimator(duration: animationTime, curve: .easeInOut) {
			self.contentInset.bottom = self.keyboardLayoutGuide.layoutFrame.height + self.insets.bottom
		}
		animator.startAnimation()
		//self.contentInset.bottom = self.keyboardLayoutGuide.layoutFrame.height
				
		self.editorDelegate?.dismissKeyboardButton?.isHidden = false
		self.editorDelegate?.screenplayButton?.isHidden = true
	}
	func keyboardDidShow() {
		//self.scroll(to: self.selectedRange, animated: false)
	}
	func keyboardWillHide() {
		self.contentInset.bottom = self.insets.bottom
		self.editorDelegate?.dismissKeyboardButton?.isHidden = true
		self.editorDelegate?.screenplayButton?.isHidden = false
	}
		
	@objc func dismissKeyboard() {
		self.endEditing(true)
	}
}

// MARK: - Assisting views

class BeatPageView:UIView {
	override func awakeFromNib() {
		super.awakeFromNib()
		
		layer.shadowRadius = 3.0
		layer.shadowColor = UIColor.black.cgColor
		layer.shadowOpacity = 0.2
		layer.shadowOffset = .zero
	}
}

class BeatScrollView: UIScrollView {
	@objc public var manualScroll = false
	
	override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
		super.scrollRectToVisible(rect, animated: animated)
	}
	
	@objc public func safelyScrollRectToVisible(_ rect: CGRect, animated: Bool) {
		super.scrollRectToVisible(rect, animated: animated)
	}
}


