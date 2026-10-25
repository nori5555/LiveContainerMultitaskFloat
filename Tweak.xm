#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
//     extended to the full window so the top of the window is entirely the
//     app, with only the three buttons overlaid on it. The bar stays an
//     arranged subview in front of the scene, so it keeps its drag-to-move
//     gesture, and the resize handle is untouched.
//  3. The side multitask dock is removed using LiveContainer's own hidden
//     state: hideDockToSide moves the dock off-screen through updateDockFrame
//     (the designed mechanism), and the paths that would bring it back
//     (showDockFromHidden, toggleDockVisibility) are redirected to hide it
//     again. Nothing is neutralized outright, so window creation keeps all
//     of its internal state consistent.
//
// v4 notes (crash fix): the first release crashed when opening multitask
// windows. Two mechanisms were replaced with strictly less invasive ones:
//  - Scene height: instead of deactivating the scene's top/bottom constraints
//    and activating new ones (restructuring the layout during window setup),
//    this version only zeroes the CONSTANT of the existing scene top/bottom
//    constraints that the original just installed. Same final layout, no
//    layout-engine restructuring.
//  - Dock: instead of replacing showDock with a no-op (which left window
//    creation's dock state inconsistent), the dock is hidden through the
//    supported hideDockToSide path, and only the re-show paths are redirected.
//
// v6 notes: v5 stopped the crash (user confirmed 2026-10-25 14:04), two
// finish issues remain. (1) Status bar strip stays white: the decorated
// view itself starts below the status bar (safe-area inset) and its
// background is systemBackground, so the band above it is white. Fix:
// shift the scene's top constraint up by exactly the decorated view's
// top offset within its window, so the app paints under the status bar;
// the nav bar and its three buttons stay where they are, floating over
// the app. (2) Dock "hidden" is not gone: hideDockToSide only moves the
// dock to the side and deliberately leaves a ~40pt sliver visible at 0.4
// opacity as an edge-swipe handle. Fix: also hide the dock's hosting
// view itself (hidden survives updateDockFrame's frame resets); re-show
// attempts come back through ForceHideDock and are re-hidden. If the
// dock view appears late, the layout hook re-applies the full hide.
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

// MultitaskDockManager is a Swift class; its ObjC runtime name is either
// the bare name or module-prefixed (e.g. "LiveContainerSwiftUI.
// MultitaskDockManager"). Look it up by exact name first, then by
// module-prefixed suffix — never by substring, because the class list
// also holds pure-Swift types whose mangled names contain the substring,
// and messaging one of those crashes (see v5 notes above). Accept only a
// class that is NSObject-derived and answers +shared.
static Class MultitaskFloatDockManagerClass(void) {
    Class cls = objc_getClass("MultitaskDockManager");
    if (!cls) {
        int count = objc_getClassList(NULL, 0);
        if (count <= 0) return Nil;
        Class *list = (Class *)malloc(sizeof(Class) * (size_t)count);
        if (!list) return Nil;
        count = objc_getClassList(list, count);
        const char *suffix = ".MultitaskDockManager";
        size_t slen = strlen(suffix);
        for (int i = 0; i < count; i++) {
            const char *name = class_getName(list[i]);
            if (!name) continue;
            size_t nlen = strlen(name);
            if (nlen > slen && strcmp(name + nlen - slen, suffix) == 0) { cls = list[i]; break; }
        }
        free(list);
    }
    if (!cls) return Nil;
    BOOL isNSObjectDerived = NO;
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        if (strcmp(class_getName(c), "NSObject") == 0) { isNSObjectDerived = YES; break; }
    }
    if (!isNSObjectDerived) return Nil;
    if (!class_respondsToSelector(cls, @selector(shared))) return Nil;
    return cls;
}

// Any path that would bring the dock back is redirected to hide it again.
static void MultitaskFloatHideDockManager(id manager) {
    if (!manager) return;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(manager, @selector(hideDockToSide));
        // hideDockToSide alone leaves a ~40pt sliver on screen; hide the
        // hosting view itself for a true removal. hidden survives the
        // frame resets updateDockFrame performs.
        id hc = [manager valueForKey:@"hostingController"];
        UIView *dockView = hc ? [hc valueForKey:@"view"] : nil;
        if (dockView && !dockView.hidden) dockView.hidden = YES;
    } @catch (id e) {
        // Dock hiding is cosmetic; never let it take the app down.
    }
}

static void MultitaskFloatHideDockFully(void) {
    Class cls = MultitaskFloatDockManagerClass();
    if (!cls) return;
    if (!class_getInstanceMethod(cls, @selector(hideDockToSide))) return;
    id manager = nil;
    @try {
        manager = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(shared));
    } @catch (id e) {
        manager = nil;
    }
    MultitaskFloatHideDockManager(manager);
}

static void MultitaskFloatForceHideDock(id self, SEL _cmd) {
    MultitaskFloatHideDockManager(self);
}

static void MultitaskFloatSwizzleDock(void) {
    if (dockSwizzled) return;
    Class cls = MultitaskFloatDockManagerClass();
    if (!cls) return;
    // Only redirect the re-show paths when the hide path actually exists,
    // so the redirect never sends an unimplemented selector.
    if (!class_getInstanceMethod(cls, @selector(hideDockToSide))) return;
    Method mShow = class_getInstanceMethod(cls, @selector(showDockFromHidden));
    if (mShow) method_setImplementation(mShow, (IMP)MultitaskFloatForceHideDock);
    Method mToggle = class_getInstanceMethod(cls, @selector(toggleDockVisibility));
    if (mToggle) method_setImplementation(mToggle, (IMP)MultitaskFloatForceHideDock);
    dockSwizzled = YES;
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

static id MultitaskFloatInitImpl(id self, SEL _cmd, NSString *windowName, NSString *bundleId, NSString *dataUUID, UIViewController *rootVC) {
    id vc = origDecoratedInit(self, _cmd, windowName, bundleId, dataUUID, rootVC);
    if (vc) {
        DecoratedAppSceneViewController *dvc = (DecoratedAppSceneViewController *)vc;
        // All three traffic-light buttons stay; only the title/bar go away.
        MultitaskFloatStripBar(dvc);
        // Dock: make sure the re-show redirects are in place, and move the
        // dock off-screen through the supported path.
        MultitaskFloatSwizzleDock();
        MultitaskFloatHideDockFully();
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
    // Only change the CONSTANTs of the scene's top/bottom constraints
    // that the original just installed. The constraints themselves, and
    // the bar's own height constraint, are left untouched, so the layout
    // structure never changes. Top: the decorated view starts below the
    // status bar (safe-area inset), which leaves a white strip at the
    // top; shift the scene up by exactly the decorated view's top offset
    // within its window so the app itself paints under the status bar.
    // Bottom stays at the decorated view's bottom edge. The bar keeps
    // overlaying the scene, so the three buttons stay floating over the
    // app exactly where they are.
    CGFloat topOffset = 0;
    if (vc.view.window) {
        topOffset = [vc.view convertRect:vc.view.bounds toView:vc.view.window].origin.y;
    }
    BOOL changed = NO;
    for (NSLayoutConstraint *c in vc.activatedVerticalConstraints) {
        if (c.firstItem == sceneView &&
            (c.firstAttribute == NSLayoutAttributeTop || c.firstAttribute == NSLayoutAttributeBottom)) {
            CGFloat target = (c.firstAttribute == NSLayoutAttributeTop) ? -topOffset : 0;
            if (c.constant != target) {
                c.constant = target;
                changed = YES;
            }
        }
    }
    if (changed) {
        [UIView animateWithDuration:0.3 animations:^{
            [vc.view layoutIfNeeded];
        }];
    }
    // Keep the dock fully gone even if its view appears late.
    MultitaskFloatHideDockFully();
}

__attribute__((constructor))
static void MultitaskFloatConstructor(void) {
    // Dyld-init time: ONLY pure runtime calls. No UIKit, no defaults, no
    // Security. Everything else happens when windows are created/laid out.
    MultitaskFloatSwizzleDock();
    Class cls = objc_getClass("DecoratedAppSceneViewController");
    if (!cls) return;
    Method mInit = class_getInstanceMethod(cls, @selector(initWindowName:bundleId:dataUUID:rootVC:));
    if (mInit) {
        origDecoratedInit = (DecoratedInitIMP)method_getImplementation(mInit);
        method_setImplementation(mInit, (IMP)MultitaskFloatInitImpl);
    }
    Method mLayout = class_getInstanceMethod(cls, @selector(updateVerticalConstraints));
    if (mLayout) {
        origUpdateVerticalConstraints = (VoidIMP)method_getImplementation(mLayout);
        method_setImplementation(mLayout, (IMP)MultitaskFloatUpdateVerticalConstraints);
    }
}
