#import "ConfigureSheetController.h"
#import <ScreenSaver/ScreenSaver.h>

static NSString * const kModuleName = @"com.jorviksoftware.ASCIISaver";

NSString * const ASCIISaverConfigDidChangeNotification = @"ASCIISaverConfigDidChange";

static NSString * const kColourFilter = @"colourFilter";
static NSString * const kInvertColours = @"invertColours";
static NSString * const kFontSize = @"fontSize";
static NSString * const kTargetFPS = @"targetFPS";
static NSString * const kRotation = @"rotation";
static NSString * const kMirrorX = @"mirrorX";
static NSString * const kMirrorY = @"mirrorY";
static NSString * const kScanlinesEnabled = @"scanlinesEnabled";
static NSString * const kPersistenceEnabled = @"persistenceEnabled";
static NSString * const kGlitchEnabled = @"glitchEnabled";
static NSString * const kInterferenceEnabled = @"interferenceEnabled";

@implementation ConfigureSheetController {
    NSWindow *_window;
    
    NSPopUpButton *_colourFilterPopup;
    NSButton *_invertColoursCheckbox;
    NSSlider *_fontSizeSlider;
    NSTextField *_fontSizeLabel;
    NSSlider *_fpsSlider;
    NSTextField *_fpsLabel;
    NSPopUpButton *_rotationPopup;
    NSButton *_mirrorXCheckbox;
    NSButton *_mirrorYCheckbox;
    NSButton *_scanlinesCheckbox;
    NSButton *_persistenceCheckbox;
    NSButton *_glitchCheckbox;
    NSButton *_interferenceCheckbox;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self buildWindow];
    }
    return self;
}

- (NSWindow *)window {
    return _window;
}

- (ScreenSaverDefaults *)defaults {
    return [ScreenSaverDefaults defaultsForModuleWithName:kModuleName];
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 340, 552);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskTitled
                                            backing:NSBackingStoreBuffered
                                              defer:YES];
    _window.title = @"ASCIISaver Options";
    _window.delegate = self;
    
    NSView *content = _window.contentView;
    CGFloat y = frame.size.height - 40;
    CGFloat labelX = 20;
    CGFloat controlX = 120;
    CGFloat controlW = 180;
    CGFloat rowH = 32;
    
    // === LOOK Section ===
    [self addSectionLabel:@"Look" toView:content atY:y];
    y -= rowH;
    
    [self addLabel:@"Colour:" toView:content atX:labelX y:y];
    _colourFilterPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, controlW, 24) pullsDown:NO];
    [_colourFilterPopup addItemsWithTitles:@[@"Classic", @"Matrix", @"Amber", @"Raw Feed", @"Silhouette"]];
    [_colourFilterPopup setTarget:self];
    [_colourFilterPopup setAction:@selector(controlChanged:)];
    [content addSubview:_colourFilterPopup];
    y -= rowH;
    
    _invertColoursCheckbox = [NSButton checkboxWithTitle:@"Invert colours" target:self action:@selector(controlChanged:)];
    _invertColoursCheckbox.frame = NSMakeRect(controlX, y, controlW, 20);
    [content addSubview:_invertColoursCheckbox];
    y -= rowH;
    
    [self addLabel:@"Font size:" toView:content atX:labelX y:y];
    _fontSizeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, controlW - 45, 20)];
    _fontSizeSlider.minValue = 6;
    _fontSizeSlider.maxValue = 18;
    _fontSizeSlider.continuous = YES;
    [_fontSizeSlider setTarget:self];
    [_fontSizeSlider setAction:@selector(sliderChanged:)];
    [content addSubview:_fontSizeSlider];
    _fontSizeLabel = [self addValueLabel:@"9" toView:content atX:controlX + controlW - 35 y:y];
    y -= rowH;
    
    [self addLabel:@"FPS:" toView:content atX:labelX y:y];
    _fpsSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y, controlW - 45, 20)];
    _fpsSlider.minValue = 5;
    _fpsSlider.maxValue = 60;
    _fpsSlider.continuous = YES;
    [_fpsSlider setTarget:self];
    [_fpsSlider setAction:@selector(sliderChanged:)];
    [content addSubview:_fpsSlider];
    _fpsLabel = [self addValueLabel:@"24" toView:content atX:controlX + controlW - 35 y:y];
    y -= rowH + 15;
    
    // === TRANSFORM Section ===
    [self addSectionLabel:@"Transform" toView:content atY:y];
    y -= rowH;
    
    [self addLabel:@"Rotation:" toView:content atX:labelX y:y];
    _rotationPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, controlW, 24) pullsDown:NO];
    [_rotationPopup addItemsWithTitles:@[@"None", @"Right 90°", @"Left 90°", @"180°"]];
    [_rotationPopup setTarget:self];
    [_rotationPopup setAction:@selector(controlChanged:)];
    [content addSubview:_rotationPopup];
    y -= rowH;
    
    _mirrorXCheckbox = [NSButton checkboxWithTitle:@"Mirror X" target:self action:@selector(controlChanged:)];
    _mirrorXCheckbox.frame = NSMakeRect(controlX, y, controlW, 20);
    [content addSubview:_mirrorXCheckbox];
    y -= rowH;
    
    _mirrorYCheckbox = [NSButton checkboxWithTitle:@"Mirror Y" target:self action:@selector(controlChanged:)];
    _mirrorYCheckbox.frame = NSMakeRect(controlX, y, controlW, 20);
    [content addSubview:_mirrorYCheckbox];
    y -= rowH + 15;
    
    // === EFFECTS Section ===
    [self addSectionLabel:@"Effects" toView:content atY:y];
    y -= rowH;
    
    _scanlinesCheckbox = [NSButton checkboxWithTitle:@"Scanlines" target:self action:@selector(controlChanged:)];
    _scanlinesCheckbox.frame = NSMakeRect(controlX, y, controlW, 20);
    [content addSubview:_scanlinesCheckbox];
    y -= rowH;
    
    _persistenceCheckbox = [NSButton checkboxWithTitle:@"Persistence" target:self action:@selector(controlChanged:)];
    _persistenceCheckbox.frame = NSMakeRect(controlX, y, controlW, 20);
    [content addSubview:_persistenceCheckbox];
    y -= rowH;
    
    _glitchCheckbox = [NSButton checkboxWithTitle:@"Glitch" target:self action:@selector(controlChanged:)];
    _glitchCheckbox.frame = NSMakeRect(controlX, y, controlW, 20);
    [content addSubview:_glitchCheckbox];
    y -= rowH;
    
    _interferenceCheckbox = [NSButton checkboxWithTitle:@"Interference" target:self action:@selector(controlChanged:)];
    _interferenceCheckbox.frame = NSMakeRect(controlX, y, controlW, 20);
    [content addSubview:_interferenceCheckbox];
    y -= rowH + 20;
    
    // === Buttons ===
    NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(frame.size.width - 190, 15, 80, 28)];
    cancelButton.title = @"Cancel";
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.keyEquivalent = @"\033";
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(cancelPressed:)];
    [content addSubview:cancelButton];
    
    NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(frame.size.width - 100, 15, 80, 28)];
    okButton.title = @"OK";
    okButton.bezelStyle = NSBezelStyleRounded;
    okButton.keyEquivalent = @"\r";
    [okButton setTarget:self];
    [okButton setAction:@selector(okPressed:)];
    [content addSubview:okButton];
}

#pragma mark - Helpers

- (void)addSectionLabel:(NSString *)text toView:(NSView *)view atY:(CGFloat)y {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont boldSystemFontOfSize:13];
    label.frame = NSMakeRect(10, y, 200, 20);
    [view addSubview:label];
}

- (void)addLabel:(NSString *)text toView:(NSView *)view atX:(CGFloat)x y:(CGFloat)y {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = NSMakeRect(x, y, 95, 20);
    label.alignment = NSTextAlignmentRight;
    [view addSubview:label];
}

- (NSTextField *)addValueLabel:(NSString *)text toView:(NSView *)view atX:(CGFloat)x y:(CGFloat)y {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = NSMakeRect(x, y, 35, 20);
    label.alignment = NSTextAlignmentRight;
    [view addSubview:label];
    return label;
}

#pragma mark - Load / Save

- (void)loadDefaults {
    ScreenSaverDefaults *defs = [self defaults];
    
    [defs registerDefaults:@{
        kColourFilter: @0,
        kInvertColours: @NO,
        kFontSize: @9.0,
        kTargetFPS: @24.0,
        kRotation: @0,
        kMirrorX: @YES,
        kMirrorY: @NO,
        kScanlinesEnabled: @YES,
        kPersistenceEnabled: @NO,
        kGlitchEnabled: @NO,
        kInterferenceEnabled: @NO
    }];
    
    // Re-read from disk
    [defs synchronize];
    
    [_colourFilterPopup selectItemAtIndex:[defs integerForKey:kColourFilter]];
    _invertColoursCheckbox.state = [defs boolForKey:kInvertColours] ? NSControlStateValueOn : NSControlStateValueOff;
    
    _fontSizeSlider.doubleValue = [defs doubleForKey:kFontSize];
    _fontSizeLabel.stringValue = [NSString stringWithFormat:@"%d", (int)_fontSizeSlider.doubleValue];
    
    _fpsSlider.doubleValue = [defs doubleForKey:kTargetFPS];
    _fpsLabel.stringValue = [NSString stringWithFormat:@"%d", (int)_fpsSlider.doubleValue];
    
    [_rotationPopup selectItemAtIndex:[defs integerForKey:kRotation]];
    _mirrorXCheckbox.state = [defs boolForKey:kMirrorX] ? NSControlStateValueOn : NSControlStateValueOff;
    _mirrorYCheckbox.state = [defs boolForKey:kMirrorY] ? NSControlStateValueOn : NSControlStateValueOff;
    
    _scanlinesCheckbox.state = [defs boolForKey:kScanlinesEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    _persistenceCheckbox.state = [defs boolForKey:kPersistenceEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    _glitchCheckbox.state = [defs boolForKey:kGlitchEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    _interferenceCheckbox.state = [defs boolForKey:kInterferenceEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)saveAllToDefaults {
    ScreenSaverDefaults *defs = [self defaults];
    
    [defs setInteger:_colourFilterPopup.indexOfSelectedItem forKey:kColourFilter];
    [defs setBool:(_invertColoursCheckbox.state == NSControlStateValueOn) forKey:kInvertColours];
    [defs setDouble:_fontSizeSlider.doubleValue forKey:kFontSize];
    [defs setDouble:_fpsSlider.doubleValue forKey:kTargetFPS];
    [defs setInteger:_rotationPopup.indexOfSelectedItem forKey:kRotation];
    [defs setBool:(_mirrorXCheckbox.state == NSControlStateValueOn) forKey:kMirrorX];
    [defs setBool:(_mirrorYCheckbox.state == NSControlStateValueOn) forKey:kMirrorY];
    [defs setBool:(_scanlinesCheckbox.state == NSControlStateValueOn) forKey:kScanlinesEnabled];
    [defs setBool:(_persistenceCheckbox.state == NSControlStateValueOn) forKey:kPersistenceEnabled];
    [defs setBool:(_glitchCheckbox.state == NSControlStateValueOn) forKey:kGlitchEnabled];
    [defs setBool:(_interferenceCheckbox.state == NSControlStateValueOn) forKey:kInterferenceEnabled];
    
    [defs synchronize];
    
    NSLog(@"ASCIISaver [Config]: Saved all defaults and synchronised");
}

#pragma mark - Actions

- (void)controlChanged:(id)sender {
    [self saveAllToDefaults];
    [self writeSharedConfig];
    [[NSNotificationCenter defaultCenter] postNotificationName:ASCIISaverConfigDidChangeNotification object:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jorviksoftware.ASCIISaver.configChanged"), NULL, NULL, true);
}

- (void)sliderChanged:(id)sender {
    _fontSizeLabel.stringValue = [NSString stringWithFormat:@"%d", (int)_fontSizeSlider.doubleValue];
    _fpsLabel.stringValue = [NSString stringWithFormat:@"%d", (int)_fpsSlider.doubleValue];
    [self saveAllToDefaults];
    [self writeSharedConfig];
    [[NSNotificationCenter defaultCenter] postNotificationName:ASCIISaverConfigDidChangeNotification object:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jorviksoftware.ASCIISaver.configChanged"), NULL, NULL, true);
}

- (void)cancelPressed:(id)sender {
    // Reload to discard any changes made before cancel
    [self loadDefaults];
    [_window.sheetParent endSheet:_window];
}

- (void)okPressed:(id)sender {
    [self saveAllToDefaults];
    [self writeSharedConfig];
    [[NSNotificationCenter defaultCenter] postNotificationName:ASCIISaverConfigDidChangeNotification object:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.jorviksoftware.ASCIISaver.configChanged"), NULL, NULL, true);
    [_window.sheetParent endSheet:_window];
}

- (void)writeSharedConfig {
    NSDictionary *config = @{
        @"colourFilter": @(_colourFilterPopup.indexOfSelectedItem),
        @"invertColours": @(_invertColoursCheckbox.state == NSControlStateValueOn),
        @"fontSize": @(_fontSizeSlider.doubleValue),
        @"targetFPS": @(_fpsSlider.doubleValue),
        @"rotation": @(_rotationPopup.indexOfSelectedItem),
        @"mirrorX": @(_mirrorXCheckbox.state == NSControlStateValueOn),
        @"mirrorY": @(_mirrorYCheckbox.state == NSControlStateValueOn),
        @"scanlinesEnabled": @(_scanlinesCheckbox.state == NSControlStateValueOn),
        @"persistenceEnabled": @(_persistenceCheckbox.state == NSControlStateValueOn),
        @"glitchEnabled": @(_glitchCheckbox.state == NSControlStateValueOn),
        @"interferenceEnabled": @(_interferenceCheckbox.state == NSControlStateValueOn)
    };
    
    NSString *dir = @"/tmp/ASCIISaver";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [config writeToURL:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"config.plist"]] error:nil];
}

@end
