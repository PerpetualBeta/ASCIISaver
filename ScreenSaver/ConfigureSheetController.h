#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ConfigureSheetController : NSObject <NSWindowDelegate>

@property (nonatomic, strong, readonly) NSWindow *window;

- (void)loadDefaults;

@end

NS_ASSUME_NONNULL_END
