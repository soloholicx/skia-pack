// Calls into the consumer library so the static SkiaPack archives are really linked.
#import <UIKit/UIKit.h>
#include "SkiaPackConsumer.h"
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    NSLog(@"consumer-app: check returned %d", skia_pack_consumer_check());
    return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
