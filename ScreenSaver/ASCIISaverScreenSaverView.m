#import "ASCIISaverScreenSaverView.h"
#import "ConfigureSheetController.h"
#import "ASCIISaver-Swift.h"
@import Cocoa;
@import ScreenSaver;

static NSString *const kAgentStartNotification     = @"com.jorviksoftware.ASCIISaver.agent.start";
static NSString *const kAgentStopNotification      = @"com.jorviksoftware.ASCIISaver.agent.stop";
static NSString *const kAgentHeartbeatNotification = @"com.jorviksoftware.ASCIISaver.agent.heartbeat";

extern NSString * const ASCIISaverConfigDidChangeNotification;

@implementation ASCIISaverScreenSaverView {
    ConfigureSheetController *_configController;
    NSView *_hostView;
    BOOL _agentStarted;
    BOOL _isPreview;
    NSTimer *_heartbeatTimer;
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        _agentStarted = NO;
        _isPreview = isPreview;
        [self setAnimationTimeInterval:1.0/30.0];

        Class hostClass = NSClassFromString(@"ASCIISaverHostView");

        if (hostClass) {
            _hostView = [[hostClass alloc] initWithFrame:frame isPreview:isPreview];

            if (_hostView) {
                _hostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                [self addSubview:_hostView];
            }
        }

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(configDidChange:)
                                                     name:ASCIISaverConfigDidChangeNotification
                                                   object:nil];

        NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
        [dnc addObserver:self
                selector:@selector(screenDidLock:)
                    name:@"com.apple.screenIsLocked"
                  object:nil];
        [dnc addObserver:self
                selector:@selector(screenDidUnlock:)
                    name:@"com.apple.screenIsUnlocked"
                  object:nil];

        NSNotificationCenter *wsnc = [[NSWorkspace sharedWorkspace] notificationCenter];
        [wsnc addObserver:self
                 selector:@selector(screenDidSleep:)
                     name:NSWorkspaceScreensDidSleepNotification
                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [_heartbeatTimer invalidate];
    _heartbeatTimer = nil;
    if (_agentStarted) {
        [self sendStop];
    }
}

#pragma mark - Screen state observers

- (void)screenDidLock:(NSNotification *)note {
    if (!_isPreview && !_agentStarted) {
        [self sendStart];
        [self startHeartbeatTimer];
    }
}

- (void)screenDidUnlock:(NSNotification *)note {
    if (_agentStarted && !_isPreview) {
        [self sendStop];
    }
}

- (void)screenDidSleep:(NSNotification *)note {
    if (_agentStarted) {
        [self sendStop];
    }
}

#pragma mark - View lifecycle

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];

    if (self.window) {
        if (_isPreview && !_agentStarted) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!self->_agentStarted) {
                    [self sendStart];
                    [self startHeartbeatTimer];
                }
            });
        }
    }
}

- (void)startAnimation {
    [super startAnimation];
}

- (void)stopAnimation {
    [_heartbeatTimer invalidate];
    _heartbeatTimer = nil;

    if (_agentStarted) {
        [self sendStop];
    }

    [super stopAnimation];
}

- (void)animateOneFrame {
}

- (void)configDidChange:(NSNotification *)note {
    if ([_hostView respondsToSelector:@selector(applyDefaults)]) {
        [_hostView performSelector:@selector(applyDefaults)];
    }
}

- (void)drawRect:(NSRect)rect {
    if (!_hostView) {
        [[NSColor blackColor] setFill];
        NSRectFill(rect);
    }
}

#pragma mark - Heartbeat timer

- (void)startHeartbeatTimer {
    [_heartbeatTimer invalidate];
    _heartbeatTimer = [NSTimer timerWithTimeInterval:2.0
                                              target:self
                                            selector:@selector(sendHeartbeat)
                                            userInfo:nil
                                             repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_heartbeatTimer forMode:NSDefaultRunLoopMode];
}

- (void)sendHeartbeat {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFNotificationName)kAgentHeartbeatNotification,
        NULL, NULL, true);
}

#pragma mark - Agent signalling

- (void)sendStart {
    _agentStarted = YES;

    if ([_hostView respondsToSelector:@selector(screensaverDidStart)]) {
        [_hostView performSelector:@selector(screensaverDidStart)];
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFNotificationName)kAgentStartNotification,
        NULL, NULL, true);
}

- (void)sendStop {
    _agentStarted = NO;

    [_heartbeatTimer invalidate];
    _heartbeatTimer = nil;

    if ([_hostView respondsToSelector:@selector(screensaverDidStop)]) {
        [_hostView performSelector:@selector(screensaverDidStop)];
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFNotificationName)kAgentStopNotification,
        NULL, NULL, true);

    [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/ASCIISaver/framebuffer.bin" error:nil];
}

#pragma mark - Configuration Sheet

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    _configController = [[ConfigureSheetController alloc] init];
    [_configController loadDefaults];
    return _configController.window;
}

@end
