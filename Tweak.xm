#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// LiveContainer's multitasking virtual windows are DecoratedAppSceneViewController:
// a vertical stack of [44pt UINavigationBar, content]. The bar holds the app
// title (with its title menu, the "AssppPro v" control) and three
// traffic-light UIBarButtonItems: close (red, closeWindow), maximize (green,
// maximizeWindow), minimize (yellow, minimizeWindow).
//
// This tweak keeps only the title menu and the minimize button, and turns
// the bar from a fixed row into a translucent strip floating over the app:
//  1. Filter the bar button items to the minimize item only (maximize and
//     close are removed; their methods stay, they just have no button).
//  2. Give the navigation bar a dark translucent background and remove its
//     hairline, so the app shows through behind the floating strip while
//     the controls stay readable. Title text is forced white for the same
//     reason.
//  3. Re-pin the hosted scene to the full window (top = view.top, bottom =
//     view.bottom) instead of leaving a 44pt gap under the bar, so the bar
//     overlays the app content instead of pushing it down. The bar itself
//     stays an arranged subview in front of the scene (inserted later, so
//     it renders above), so it keeps its drag-to-move gesture, and the
//     resize handle and the side multitask dock are untouched.
//  4. The existing auto-hide behavior is respected: when the dock is
//     collapsed and the window is maximized, LiveContainer hides the bar
//     (height 0); this tweak does not un-hide it, it only removes the
//     44pt gap in the states where the bar is visible.
//
// Safety (learned the hard way with AutoDarkIcon): the constructor runs at
// dyld init, before UIKit is ready. It does ONLY the method swizzles. All
// UIKit work happens later, when windows are created and laid out
// (post-launch), never in the constructor. No %hook: a %hook build links
// /Library/Frameworks/CydiaSubstrate, which does not exist on jailed
// devices, so the tweak would fail to load.
//
// Install: put the built dylib in the global Tweaks folder, sign it, then
// in LiveContainer Settings tap the version number 5 times and enable
// "Load Tweaks to LiveContainer Itself", and restart LiveContainer. The
// class only exists in LiveContainer itself, so in guest apps this tweak
// is a no-op.

// Minimal interface: only what this tweak touches. The real header pulls in
// private headers, so it cannot be imported in a tweak build.
@interface DecoratedAppSceneViewController : UIViewController
@property(nonatomic) UINavigationBar *navigationBar;
@property(nonatomic) UINavigationItem *navigationItem;
@property(nonatomic) UIViewController *appSceneVC;
@property(nonatomic) NSArray *activatedVerticalConstraints;
@end

typedef id (*DecoratedInitIMP)(id, SEL, NSString *, NSString *, NSString *, UIViewController *);
typedef void (*VoidIMP)(id, SEL);
static DecoratedInitIMP origDecoratedInit = NULL;
static VoidIMP origUpdateVerticalConstraints = NULL;

static NSArray *MultitaskFloatKeepMinimize(NSArray *items) {
    if (!items) return nil;
    NSMutableArray *kept = [NSMutableArray array];
    for (UIBarButtonItem *item in items) {
        if (item.action == @selector(minimizeWindow)) [kept addObject:item];
    }
    return kept;
}

static void MultitaskFloatFilterButtons(DecoratedAppSceneViewController *vc) {
    if (!vc.navigationItem) return;
    vc.navigationItem.rightBarButtonItems = MultitaskFloatKeepMinimize(vc.navigationItem.rightBarButtonItems);
    vc.navigationItem.leftBarButtonItems = MultitaskFloatKeepMinimize(vc.navigationItem.leftBarButtonItems);
}

static void MultitaskFloatStyleBar(UINavigationBar *bar) {
    if (!bar) return;
    bar.translucent = YES;
    // 1x1 dark translucent image as the bar background, so the app shows
    // through behind the floating strip while the controls stay readable.
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1, 1)];
    UIImage *bg = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor colorWithWhite:0.0 alpha:0.45] setFill];
        CGContextFillRect(ctx.CGContext, CGRectMake(0, 0, 1, 1));
    }];
    [bar setBackgroundImage:bg forBarMetrics:UIBarMetricsDefault];
    bar.shadowImage = [UIImage new];
    bar.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
}

static id MultitaskFloatInit(id self, SEL _cmd, NSString *windowName, NSString *bundleId, NSString *dataUUID, UIViewController *rootVC) {
    id vc = origDecoratedInit(self, _cmd, windowName, bundleId, dataUUID, rootVC);
    if (vc) {
        DecoratedAppSceneViewController *dvc = (DecoratedAppSceneViewController *)vc;
        MultitaskFloatFilterButtons(dvc);
        MultitaskFloatStyleBar(dvc.navigationBar);
        // The bar-button spacing pass runs 0.1s after init; re-apply the
        // filter after it, in case it ever re-adds items.
        __weak DecoratedAppSceneViewController *weakVC = dvc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            MultitaskFloatFilterButtons(weakVC);
        });
    }
    return vc;
}

static void MultitaskFloatUpdateVerticalConstraints(id self, SEL _cmd) {
    origUpdateVerticalConstraints(self, _cmd);
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    UIView *sceneView = vc.appSceneVC.view;
    if (!sceneView || !vc.view) return;
    // Drop only the scene's top/bottom constraints that the original just
    // installed (they leave a 44pt gap for the bar); keep the bar's own
    // height constraint untouched, so the hidden-bar state still works.
    NSMutableArray *drop = [NSMutableArray array];
    for (NSLayoutConstraint *c in vc.activatedVerticalConstraints) {
        if (c.firstItem == sceneView &&
            (c.firstAttribute == NSLayoutAttributeTop || c.firstAttribute == NSLayoutAttributeBottom)) {
            [drop addObject:c];
        }
    }
    if (drop.count == 0) return;
    [UIView animateWithDuration:0.3 animations:^{
        [NSLayoutConstraint deactivateConstraints:drop];
        [NSLayoutConstraint activateConstraints:@[
            [sceneView.topAnchor constraintEqualToAnchor:vc.view.topAnchor],
            [sceneView.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor]
        ]];
        [vc.view layoutIfNeeded];
    }];
}

__attribute__((constructor))
static void MultitaskFloatInit(void) {
    // Dyld-init time: ONLY pure runtime calls. No UIKit, no defaults, no
    // Security. Everything else happens when windows are created/laid out.
    Class cls = objc_getClass("DecoratedAppSceneViewController");
    if (!cls) return;
    Method mInit = class_getInstanceMethod(cls, @selector(initWindowName:bundleId:dataUUID:rootVC:));
    if (mInit) {
        origDecoratedInit = (DecoratedInitIMP)method_getImplementation(mInit);
        method_setImplementation(mInit, (IMP)MultitaskFloatInit);
    }
    Method mLayout = class_getInstanceMethod(cls, @selector(updateVerticalConstraints));
    if (mLayout) {
        origUpdateVerticalConstraints = (VoidIMP)method_getImplementation(mLayout);
        method_setImplementation(mLayout, (IMP)MultitaskFloatUpdateVerticalConstraints);
    }
}
