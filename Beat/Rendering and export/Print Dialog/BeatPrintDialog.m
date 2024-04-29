//
//  BeatPrintDialog.m
//  Beat
//
//  Created by Lauri-Matti Parppei on 25.4.2022.
//  Copyright © 2022 Lauri-Matti Parppei. All rights reserved.
//

/*
 
 This class works as an intermediate between PrintView and the Beat document
 and handles the UI side of printing, too. The printing itself is done in PrintView,
 which also does all the necessary preprocessing.
 
 This is a HORRIBLY convoluted system. I'm sorry for any inconvenience.
 
 NOTE: PrintView is stored into HOST DOCUMENT to keep it in memory after
 closing the dialog.
 
 */

#import <BeatParsing/BeatParsing.h>
#import "BeatPrintDialog.h"
#import "Beat-Swift.h"

#define ADVANCED_PRINT_OPTIONS_KEY @"Show Advanced Print Options"

@interface BeatPrintDialog () <NSTextFieldDelegate, PDFViewDelegate>

@property (weak) IBOutlet NSButton* printSceneNumbers;
@property (weak) IBOutlet NSButton* radioA4;
@property (weak) IBOutlet NSButton* radioLetter;
@property (weak) IBOutlet PDFView* pdfView;
@property (weak) IBOutlet NSButton* primaryButton;
@property (weak) IBOutlet NSButton* secondaryButton;
@property (weak) IBOutlet NSTextField* title;
@property (weak) IBOutlet NSTextField* headerText;
@property (weak) IBOutlet NSSegmentedControl* headerAlign;
@property (weak) IBOutlet NSPopUpButton *revisedPageColorMenu;
@property (weak) IBOutlet NSButton *colorCodePages;
@property (weak) IBOutlet NSView *advancedOptions;
@property (weak) IBOutlet NSButton* advancedOptionsButton;


@property (weak) IBOutlet NSProgressIndicator* progressIndicator;

@property (weak) IBOutlet NSLayoutConstraint *advancedOptionsWidthConstraint;

@property (weak) IBOutlet NSButton* revisionFirst;
@property (weak) IBOutlet NSButton* revisionSecond;
@property (weak) IBOutlet NSButton* revisionThird;
@property (weak) IBOutlet NSButton* revisionFourth;

@property (weak) IBOutlet NSButton* printSections;
@property (weak) IBOutlet NSButton* printSynopsis;
@property (weak) IBOutlet NSButton* printNotes;

@property (nonatomic) NSString *compareWith;

@property (nonatomic) bool automaticPreview;

@property (nonatomic) NSMutableArray<BeatNativePrinting*>* renderQueue;

@property (nonatomic) NSTimer* previewTimer;

@property (nonatomic) bool firstPreview;

@end

@implementation BeatPrintDialog

static CGFloat panelWidth;

+ (BeatPrintDialog*)showForPDF:(id)delegate
{
	BeatPrintDialog *dialog = [BeatPrintDialog.alloc initWithWindowNibName:self.className];
	dialog.documentDelegate = delegate;
	[dialog openForPDF:nil];
	return dialog;
}
+ (BeatPrintDialog*)showForPrinting:(id)delegate
{
	BeatPrintDialog *dialog = [BeatPrintDialog.alloc initWithWindowNibName:self.className];
	dialog.documentDelegate = delegate;
	[dialog open:nil];
	return dialog;
}

-(instancetype)initWithWindowNibName:(NSNibName)windowNibName
{
	return [super initWithWindowNibName:windowNibName owner:self];
}

#pragma mark - Window actions

-(void)awakeFromNib
{
	self.renderQueue = NSMutableArray.new;
	
	// Show advanced options?
	panelWidth = self.window.frame.size.width;
	bool showAdvancedOptions = [NSUserDefaults.standardUserDefaults boolForKey:ADVANCED_PRINT_OPTIONS_KEY];
	if (showAdvancedOptions) _advancedOptionsButton.state = NSOnState; else _advancedOptionsButton.state = NSOffState;
	
	// Restore settings for note/synopsis/section printing
	if ([self.documentDelegate.documentSettings getBool:DocSettingPrintSections]) _printSections.state = NSOnState;
	if ([self.documentDelegate.documentSettings getBool:DocSettingPrintSynopsis]) _printSynopsis.state = NSOnState;
	if ([self.documentDelegate.documentSettings getBool:DocSettingPrintNotes]) _printNotes.state = NSOnState;
	
	BeatExportSettings* settings = self.exportSettings;
	
	self.headerText.stringValue = settings.header;
	[self.headerAlign setSelectedSegment:[self.documentDelegate.documentSettings getInt:DocSettingHeaderAlignment]];
	
	[self toggleAdvancedOptions:_advancedOptionsButton];
}

- (IBAction)open:(id)sender
{
	[self openPanel];
	
	// Change panel title
	_title.stringValue = NSLocalizedString(@"print.print", nil);
		
	// Switch buttons to prioritize printing
	_primaryButton.title = NSLocalizedString(@"print.printButton", nil);
	_primaryButton.action = @selector(print:);
	
	_secondaryButton.title = NSLocalizedString(@"print.pdfButton", nil);
	_secondaryButton.action = @selector(pdf:);
}

- (IBAction)openForPDF:(id)sender
{
	[self openPanel];
	
	// Change panel title
	[_title setStringValue:NSLocalizedString(@"print.createPDF", nil)];
	
	// Switch buttons to prioritize PDF creation
	_primaryButton.title = NSLocalizedString(@"print.pdfButton", nil);
	_primaryButton.action = @selector(pdf:);
	
	_secondaryButton.title = NSLocalizedString(@"print.printButton", nil);
	_secondaryButton.action = @selector(print:);
}

- (void)openPanel
{
	// Remove the previous preview
	[_pdfView setDocument:nil];
					
	[self loadWindow];
		
	// Get setting from document
	self.printSceneNumbers.state = (_documentDelegate.printSceneNumbers) ? NSOnState : NSOffState;
	
	// Check the paper size
	// WIP: Unify these so the document knows its BeatPaperSize too
	if (_documentDelegate.pageSize == BeatA4) [_radioA4 setState:NSOnState];
	else [_radioLetter setState:NSOnState];
		
	// Reload PDF preview
	_firstPreview = YES;
	[self loadPreview];
	
	NSRect frame = self.window.frame;
	NSRect screen = self.window.screen.frame;
	
	CGPoint origin = CGPointMake((screen.size.width - frame.size.width) / 2.0, (screen.size.height - frame.size.height) / 2.0);
	[self.window setFrameOrigin:origin];
	
	// We have to show the panel here to be able to set the radio buttons, because I can't figure out how to load the window.
	[self.documentDelegate.documentWindow beginSheet:self.window completionHandler:^(NSModalResponse returnCode) {
		[self.documentDelegate releasePrintDialog];
	}];
}

- (IBAction)close:(id)sender
{
	// Remove timer
	[self.previewTimer invalidate];
	
	// End sheet in host window and release this dialog
	[self.documentDelegate.documentWindow endSheet:self.window];
	[self.documentDelegate releasePrintDialog];
	
}

#pragma mark - Printing

/// Exports the file using the given print operation (pdf/print)
- (void)exportWithType:(BeatPrintingOperation)type
{
	// Create a print operation and add it to the render queue.
	BeatNativePrinting* printing = [BeatNativePrinting.alloc initWithWindow:self.window operation:type settings:self.exportSettings delegate:self.documentDelegate screenplays:nil callback:^(BeatNativePrinting * _Nonnull operation, id _Nullable value) {
		// Remove from queue
		[self.renderQueue removeObject:operation];
		[self printingDidFinish];
	}];

	// Add to render queue (to keep the printing operation in memory)
	[self.renderQueue addObject:printing];
}

- (IBAction)print:(id)sender
{
	[self exportWithType:BeatPrintingOperationToPrint];
}

- (IBAction)pdf:(id)sender
{
	[self exportWithType:BeatPrintingOperationToPDF];
}

/// Once the operation finishes, we'll close this dialog
- (void)printingDidFinish
{
	[self.documentDelegate.documentWindow endSheet:self.window];
}

/// Recreates PDF preview after a small delay.
- (void)loadPreview
{
	[self.previewTimer invalidate];

	// Start progress indicator
	[self.progressIndicator startAnimation:nil];
	self.pdfView.alphaValue = 0.5;
	
	self.previewTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:false block:^(NSTimer * _Nonnull timer) {
		[self updatePreview];
	}];
}

/// Creates a PDF preview with current settings.
- (void)updatePreview
{
	// Update PDF preview
	BeatExportSettings *settings = [self exportSettings];
	
	dispatch_async(dispatch_get_main_queue(), ^(void) {
		BeatNativePrinting* operation = [BeatNativePrinting.alloc initWithWindow:self.window operation:BeatPrintingOperationToPreview settings:settings delegate:self.documentDelegate screenplays:nil callback:^(BeatNativePrinting * _Nonnull operation, id _Nullable value) {
			[self.renderQueue removeObject:operation];
			
			NSURL* url = (NSURL*)value;
			[self didFinishPreviewAt:url];
		}];
		[self.renderQueue addObject:operation];
	});
}


#pragma mark - Export settings

- (BeatExportSettings*)exportSettings
{
	BeatExportSettings* settings = self.documentDelegate.exportSettings;

	// Set header
	// settings.header = (self.headerText.stringValue.length > 0) ? self.headerText.stringValue : @"";
	
	// Set custom settings from dialog
	settings.revisions = [self printedRevisions];
	
	settings.paperSize = self.documentDelegate.pageSize;
	settings.printNotes = (_printNotes.state == NSOnState);
	
	NSMutableIndexSet* additionalTypes = NSMutableIndexSet.new;
	if (_printSections.state == NSOnState) [additionalTypes addIndex:section];
	if (_printSynopsis.state == NSOnState) [additionalTypes addIndex:synopse];
	settings.additionalTypes = additionalTypes;
			
	return settings;
}


#pragma mark - Export setting actions

- (IBAction)selectPaperSize:(id)sender
{
	BeatPaperSize oldSize = _documentDelegate.pageSize;
	
	if ([(NSButton*)sender tag] == 1) {
		// A4
		_documentDelegate.pageSize = BeatA4;
	} else {
		// US Letter
		_documentDelegate.pageSize = BeatUSLetter;
	}
	
	// Preview needs refreshing
	if (oldSize != _documentDelegate.pageSize) {
		[self loadPreview];
	}
}

- (IBAction)selectSceneNumberPrinting:(id)sender
{
	_documentDelegate.printSceneNumbers = (_printSceneNumbers.state == NSOnState);
	[self loadPreview];
}

- (IBAction)toggleAdvancedOptions:(id)sender
{
	NSButton *button = sender;
	
	NSRect frame = self.window.contentView.frame;
	if (button.state == NSOffState) {
		frame.size.width = panelWidth - _advancedOptionsWidthConstraint.constant;
		[NSUserDefaults.standardUserDefaults setBool:NO forKey:ADVANCED_PRINT_OPTIONS_KEY];
	} else {
		frame.size.width = panelWidth;
		[NSUserDefaults.standardUserDefaults setBool:YES forKey:ADVANCED_PRINT_OPTIONS_KEY];
	}
	
	[self.window.animator setFrame:frame display:YES];
}

- (IBAction)toggleColorCodePages:(id)sender
{
	NSButton *checkbox = sender;
	if (checkbox.state == NSOnState) [_documentDelegate.documentSettings setBool:DocSettingColorCodePages as:YES];
	else [_documentDelegate.documentSettings setBool:DocSettingColorCodePages as:NO];

	[self loadPreview];
}

- (IBAction)setRevisedPageColor:(id)sender
{
	NSPopUpButton *menu = sender;
	NSString *color = menu.selectedItem.title.lowercaseString;
	
	[_documentDelegate.documentSettings set:DocSettingRevisedPageColor as:color];
	[self loadPreview];
}

- (IBAction)toggleRevision:(id)sender
{
	[self loadPreview];
}

- (IBAction)toggleInvisibleElement:(id)sender
{
	BeatUserDefaultCheckbox* checkbox = sender;

	if (checkbox.userDefaultKey.length > 0) {
		[self.documentDelegate.documentSettings setBool:checkbox.userDefaultKey as:(checkbox.state == NSOnState)];
	}
	
	[self loadPreview];
}

- (void)didFinishPreviewAt:(NSURL *)url
{
	// Stop progress indicator
	[self.progressIndicator stopAnimation:nil];
	self.pdfView.alphaValue = 1.0;

	// Load the actual PDF into the view
	PDFDocument *doc = [[PDFDocument alloc] initWithURL:url];
	[_pdfView setDocument:doc];
	
	_firstPreview = NO;
}

- (NSIndexSet*)printedRevisions
{
	// TODO: Make sense to this :----)
	NSMutableIndexSet* revisions = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, BeatRevisions.revisionGenerations.count)];
		
	if (self.revisionFirst.state != NSOnState) [revisions removeIndex:0];
	if (self.revisionSecond.state != NSOnState) [revisions removeIndex:1];
	if (self.revisionThird.state != NSOnState) [revisions removeIndex:2];
	if (self.revisionFourth.state != NSOnState) [revisions removeIndex:3];
	
	return revisions;
}

- (IBAction)toggleHeaderAlignment:(NSSegmentedControl*)sender
{
	[self.documentDelegate.documentSettings setInt:DocSettingHeaderAlignment as:sender.selectedSegment];
	[self loadPreview];
}


#pragma mark - Header text did change

- (void)controlTextDidChange:(NSNotification *)obj
{
	[self headerTextChange:nil];
}

- (IBAction)headerTextChange:(id)sender
{
	[self.documentDelegate.documentSettings setString:DocSettingHeader as:(self.headerText.stringValue != nil) ? self.headerText.stringValue : @""];
	[self loadPreview];
}

@end
