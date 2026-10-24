#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdlib.h>

// LiveContainer's multitasking virtual windows are DecoratedAppSceneViewController:
// a vertical stack of [44pt UINavigationBar, content]. The bar holds the app
// title (with its title menu, the "AssppPro v" control) and three
// traffic-light UIBarButtonItems: close (red, closeWindow), maximize (green,
// maximizeWindow), minimize (yellow, minimizeWindow).
//
// This tweak strips the window chrome down to just the three traffic-light
// buttons, floating directly over the app:
//  1. The app title and its menu are removed (title and titleMenuProvider
//     cleared), so no app name shows.
//  2. The navigation bar itself becomes fully transparent (empty background
//     image, no hairline) — NOT translucent-dark. The hosted scene is
//     re-pinned to the full window (top = view.top, bottom = view.bottom)
//     instead of leaving a 44pt gap under the bar, so the top of the window
//     is entirely the app, with only the three buttons overlaid on it.
//     The bar stays an arranged subview in front of the scene, so it keeps
//     its drag-to-move gesture, and the resize handle is untouched.
//  3. The side multitask dock is removed: MultitaskDockManager's showDock
//     is neutralized so the dock view never appears, and any already-visible
//     dock is hidden when a window is created. (updateDockFrame only moves
//     the dock's frame and never touches its alpha, so blocking showDock —
//     the only place that fades the dock in — keeps it gone for good. The
//     edge-swipe gestures remain but do nothing visible.)
//  4. The existing auto-hide behavior is respected: when the dock is
//     collapsed and the window is maximized, LiveContainer hides the bar
//     (height 0); this tweak does not un-hide it. In practice the collapse
//     toggle lives in the dock itself, so once the dock is gone the bar
//     stays visible.
//
// Safety (learned the hard way with AutoDarkIcon): the constructor runs at
// dyld init, before UIKit is ready. It does ONLY pure runtime calls
// (class lookup, method swizzles). All UIKit work happens later, when
// windows are created and laid out (post-launch), never in the constructor.
// No %hook: a %hook build links /Library/Frameworks/CydiaSubstrate, which
// does not exist on jailed devices, so the tweak would fail to load.
//
// Install: put the built dylib in the global Tweaks folder, sign it, then
// in LiveContainer Settings tap the version number 5 times and enable
// "Load Tweaks to LiveContainer Itself", and restart LiveContainer. The
// classes only exist in LiveContainer itself, so in guest apps this tweak
// is a no-op.

// Minimal interface: only what this tweak touches. The real headers pull in
// private headers or are Swift-generated, so they cannot be imported here.
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
static BOOL dockSwizzled = NO;

// MultitaskDockManager is a Swift class; its ObjC runtime name may carry
// the module prefix, so look it up by substring instead of exact name.
static Class MultitaskFloatDockManagerClass(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!list) return Nil;
    count = objc_getClassList(list, count);
    Class found = Nil;
    for (int i = 0; i < count; i++) {
        const char *name = class_getName(list[i]);
        if (name && strstr(name, "MultitaskDockManager") != NULL) { found = list[i]; break; }
    }
    free(list);
    return found;
}

static void MultitaskFloatSwizzleDock(void) {
    if (dockSwizzled) return;
    Class cls = MultitaskFloatDockManagerClass();
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(showDock));
    if (!m) return;
    // Neutralize showDock: it is the only place that fades the dock in.
    // Replacing it with a no-op keeps the dock gone permanently.
    method_setImplementation(m, imp_implementationWithBlock(^(id self) {}));
    dockSwizzled = YES;
}

static void MultitaskFloatHideDock(void) {
    Class cls = MultitaskFloatDockManagerClass();
    if (!cls) return;
    id manager = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(shared));
    if (manager) ((void (*)(id, SEL))objc_msgSend)(manager, @selector(hideDock));
}

static void MultitaskFloatStripBar(DecoratedAppSceneViewController *vc) {
    if (!vc.navigationItem) return;
    // No app name, no menu chevron.
    vc.navigationItem.title = nil;
    vc.navigationItem.titleMenuProvider = nil;
    // Fully transparent bar: no background, no hairline, no dark tint.
    UINavigationBar *bar = vc.navigationBar;
    if (bar) {
        bar.translucent = YES;
        [bar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
        bar.shadowImage = [UIImage new];
    }
}

static id MultitaskFloatInit(id self, SEL _cmd, NSString *windowName, NSString *bundleId, NSString *dataUUID, UIViewController *rootVC) {
    id vc = origDecoratedInit(self, _cmd, windowName, bundleId, dataUUID, rootVC);
    if (vc) {
        DecoratedAppSceneViewController *dvc = (DecoratedAppSceneViewController *)vc;
        // All three traffic-light buttons stay; only the title/bar go away.
        MultitaskFloatStripBar(dvc);
        // Dock: make sure the swizzle is in place, and hide any dock that
        // is already visible.
        MultitaskFloatSwizzleDock();
        MultitaskFloatHideDock();
    }
    return vc;
}

static void MultitaskFloatUpdateVerticalConstraints(id self, SEL _cmd) {
    origUpdateVerticalConstraints(self, _cmd);
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    // Re-apply the strip in case the title was ever re-set.
    MultitaskFloatStripBar(vc);
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
    MultitaskFloatSwizzleDock();
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
