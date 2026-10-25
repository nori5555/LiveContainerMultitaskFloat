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
// v5 notes (root cause, proven by the 2026-10-25 13:49 crash log): v3 and
// v4 did NOT crash on constraints or on the dock-hide path. The log shows
// a Swift fatalError (doesNotRecognizeSelector on SwiftObject) from a
// message send inside this tweak during multitask window creation, and
// disassembly of the delivered dylib proves the crashing send is
// [foundClass shared] (selector ref 0xc090). Upstream confirms the real
// MultitaskDockManager is NSObject-derived with @objc shared, so that send
// is only fatal when the class lookup returns the WRONG class. The old
// lookup matched by substring, but the ObjC class list also holds
// pure-Swift types whose mangled runtime names contain the substring, and
// the first match wins — sending +shared to one of those is the crash.
// v5 therefore looks the class up by exact name (or module-prefixed
// suffix) and refuses to message any class that is not NSObject-derived
// or does not answer +shared; hideDockToSide is likewise only sent when
// the class actually implements it. If verification fails, the dock is
// left alone instead of crashing the app.
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
static void MultitaskFloatForceHideDock(id self, SEL _cmd) {
    ((void (*)(id, SEL))objc_msgSend)(self, @selector(hideDockToSide));
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

static void MultitaskFloatHideDockToSide(void) {
    Class cls = MultitaskFloatDockManagerClass();
    if (!cls) return;
    // Only send hideDockToSide when the class actually implements it;
    // otherwise leave the dock alone instead of crashing.
    if (!class_getInstanceMethod(cls, @selector(hideDockToSide))) return;
    @try {
        id manager = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(shared));
        if (manager) ((void (*)(id, SEL))objc_msgSend)(manager, @selector(hideDockToSide));
    } @catch (id e) {
        // Dock hiding is cosmetic; never let it take the app down.
    }
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
        MultitaskFloatHideDockToSide();
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
    // Only zero the CONSTANT of the scene's top/bottom constraints that the
    // original just installed (they leave a 44pt gap for the bar). The
    // constraints themselves, and the bar's own height constraint, are left
    // untouched, so the layout structure never changes — the scene simply
    // extends to the full window and the bar overlays it.
    BOOL changed = NO;
    for (NSLayoutConstraint *c in vc.activatedVerticalConstraints) {
        if (c.firstItem == sceneView &&
            (c.firstAttribute == NSLayoutAttributeTop || c.firstAttribute == NSLayoutAttributeBottom)) {
            if (c.constant != 0) {
                c.constant = 0;
                changed = YES;
            }
        }
    }
    if (changed) {
        [UIView animateWithDuration:0.3 animations:^{
            [vc.view layoutIfNeeded];
        }];
    }
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
