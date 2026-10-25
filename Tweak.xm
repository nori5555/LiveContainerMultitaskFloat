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
// v11 notes (build fixes, 2026-10-25): v9 and v10 both failed to build,
// for two different reasons. (1) v9 used a category @implementation on
// the host class: it compiled but failed to LINK, because a category
// references the host class symbol (_OBJC_CLASS_$), which lives in
// LiveContainer, not in this dylib. (2) v10 had two plain C++ errors:
// a const object without an initializer (illegal in C++), and a call
// to AddFloatingPill from InitImpl before its definition (fixed with
// a forward declaration, as with AddDragGesture). v11 keeps the
// safe-area compensation but installs it as a C-function IMP with the
// method's exact UIEdgeInsets signature — no category, no %hook, no
// CydiaSubstrate, no host class symbol at link time.
//
// v12 notes (2026-10-25): v11 still slid the top controls up. Cause:
// the first maximized recompute runs before the decorated view's
// frame is final, so the swizzle computes off = 0 and no compensation
// is applied — and nothing re-triggers a recompute after layout
// settles, until a dock change forces one (that is why collapsing
// the sidebar "fixed" it). Fix: viewDidAppear pushes the compensated
// safe area directly on the next runloop tick, when the frame is
// final; the swizzle keeps later recomputes at the same value, so
// it cannot double-add. Sidebar: the dock is now collapsed
// automatically (isCollapsed) and the collapsed-hidden state is
// persisted (LCHideCollapsedDock in the app-group defaults, the same
// store the dock view reads on launch), so the sidebar stays gone
// across window opens and relaunches instead of needing a manual
// shrink every time.
//
// v13 notes (2026-10-25): v12 failed to build, two compile errors.
// (1) Messaging a Class variable with an undeclared class method
// ([lcUtils appGroupID]) is a hard error: the compiler has no
// interface declaring +appGroupID. Fixed by calling it through
// objc_msgSend with a cast (the file's existing pattern for runtime
// calls), keeping the respondsToSelector: guard. (2) ViewDidAppear
// called FixTopSafeArea before its definition (same use-before-
// definition class of error as v10's pill call); fixed with a forward
// declaration, as with AddDragGesture and AddFloatingPill.
//
// Install: put the built dylib in the global Tweaks folder, sign it, then
// in LiveContainer Settings tap the version number 5 times and enable
// "Load Tweaks to LiveContainer Itself", and restart LiveContainer. The
// classes only exist in LiveContainer itself, so in guest apps this tweak
// is a no-op.

// v7 notes: v6 changed nothing on the user's device. Two causes, both
// timing. (1) The top-extension hook ran before the view entered a
// window (and before the dock existed), so the window offset computed
// to 0 and the dock view was nil — both fixes silently no-opped. v7
// re-applies everything in viewDidAppear, when the window and the dock
// are guaranteed to exist. (2) The user correctly pointed out that just
// shifting the scene up would slide the app's top content up with it:
// the guest's top safe area is 0 in maximized mode (the host already
// insets the scene below the status bar), so moving the scene moves
// the content. v7 therefore grows the guest's top safe area by the
// same amount (via updateSettingsWithBlock), so content stays put and
// only background/map fills the status-bar strip. (3) New: dragging
// the three buttons when maximized. moveWindow: early-returns when
// maximized, so the buttons could never be a drag handle. v7 adds a
// pan gesture on the nav bar whose delegate only lets it begin when
// maximized (the original move gesture is required to fail then, so
// there is no double move); on drag start it restores the window
// (maximizeWindow, without animation) and then moves it like
// moveWindow: does. When not maximized the delegate refuses, so the
// original gesture moves the window exactly as before.
// v9 notes: v8 fixed the strip and the hard edge, but the app's own
// controls slid up under the status bar (user's bookshelf screenshots:
// bell/more buttons clipped by the status bar, everything shifted up).
// Cause: v7/v8 compensated the guest's top safe area with an async
// updateSettingsWithBlock after the fact, but that change triggers the
// host's own settings recompute (didUpdate -> updateMaximizedFrame ->
// updateMaximizedSafeArea), which resets the top inset to 0 — the
// compensation erased itself, so the scene extension moved content up.
// v9 moves the compensation INTO the recompute path: it swaps
// updateMaximizedSafeAreaWithSettings: with a category method (a real
// ObjC method, so the UIEdgeInsets struct return uses the right ABI)
// that runs the original computation and then grows the guest's top
// safe area by the same amount the scene was extended. Every recompute
// now produces the compensated value, so it can no longer be wiped.
// The async settings block is removed; the swizzle is the single
// source of truth for the safe area.
// v10 notes: the three buttons sit fixed at the top-right and block
// the app's own controls behind them. v10 detaches them from the nav
// bar into a floating pill on the decorated view itself: same symbols,
// colors and point size as the originals, left to right minimize /
// maximize / close, calling the same window methods. The pill drags
// anywhere (pan on the pill; taps still work because the pan only
// takes over once the finger moves) and docks to the nearest
// left/right edge on release, AssistiveTouch-style; it is clamped to
// the window when maximized and to the decorated view when windowed
// (windowed mode still clips subviews). The bar's own items are
// cleared on both sides. The pill's maximize icon is synced from the
// window state on every layout and after maximize/restore.

// Minimal interface: only what this tweak touches. The real headers pull in
// private headers or are Swift-generated, so they cannot be imported here.
@interface UIMutableApplicationSceneSettings : NSObject
@property(nonatomic) UIEdgeInsets peripheryInsets;
@property(nonatomic) UIEdgeInsets safeAreaInsetsPortrait;
@end

@interface AppSceneViewController : UIViewController
- (void)updateSettingsWithBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block;
@end

@interface DecoratedAppSceneViewController : UIViewController
@property(nonatomic) UINavigationBar *navigationBar;
@property(nonatomic) UINavigationItem *navigationItem;
@property(nonatomic) AppSceneViewController *appSceneVC;
@property(nonatomic) NSArray *activatedVerticalConstraints;
@property(nonatomic) BOOL isMaximized;
- (void)maximizeWindow;
- (void)minimizeWindow;
- (void)closeWindow;
- (void)moveWindow:(UIPanGestureRecognizer *)sender;
- (void)updateOriginalFrame;
@end


typedef id (*DecoratedInitIMP)(id, SEL, NSString *, NSString *, NSString *, UIViewController *);
typedef void (*VoidIMP)(id, SEL);
typedef void (*ViewDidAppearIMP)(id, SEL, BOOL);
typedef BOOL (*GestureShouldBeginIMP)(id, SEL, UIGestureRecognizer *);
static DecoratedInitIMP origDecoratedInit = NULL;
static VoidIMP origUpdateVerticalConstraints = NULL;
static ViewDidAppearIMP origViewDidAppear = NULL;
static GestureShouldBeginIMP origGestureShouldBegin = NULL;
static BOOL dockSwizzled = NO;

// Floating pill (v10): the three buttons detached from the nav bar so
// the user can drag them anywhere like AssistiveTouch instead of
// having them block the app's own controls. Stored on the VC.
static const char kMultitaskFloatPillKey = 0;
static const char kMultitaskFloatPillPlacedKey = 0;

// Forward declaration: defined after InitImpl, used by it.
static void MultitaskFloatAddDragGesture(DecoratedAppSceneViewController *vc);

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
    // Collapse the dock and persist the collapsed-hidden state, so the
    // sidebar stays gone across window opens and relaunches, instead
    // of the user having to shrink it by hand every time: isCollapsed
    // moves it to the side, and LCHideCollapsedDock (app-group
    // defaults, read by the dock view on launch) makes the collapsed
    // dock render at 0.01 opacity instead of the 0.4 sliver. Each write
    // is guarded so it only fires once; failures are ignored.
    @try {
        id collapsed = [manager valueForKey:@"isCollapsed"];
        if (!collapsed || ![collapsed boolValue]) {
            [manager setValue:@YES forKey:@"isCollapsed"];
        }
    } @catch (id e) {}
    @try {
        Class lcUtils = objc_getClass("LCSharedUtils");
        if (lcUtils && [lcUtils respondsToSelector:@selector(appGroupID)]) {
            NSString *gid = ((NSString *(*)(id, SEL))objc_msgSend)(lcUtils, @selector(appGroupID));
            if (gid) {
                NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:gid];
                if (![d boolForKey:@"LCHideCollapsedDock"]) {
                    [d setBool:YES forKey:@"LCHideCollapsedDock"];
                }
            }
        }
    } @catch (id e) {}
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

// Forward declaration: defined after InitImpl, used by it.
static void MultitaskFloatAddFloatingPill(DecoratedAppSceneViewController *vc);

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
        // Drag handle for the buttons when maximized (once per window).
        MultitaskFloatAddDragGesture(dvc);
        // Floating pill replacing the bar's buttons (once per window).
        MultitaskFloatAddFloatingPill(dvc);
    }
    return vc;
}

// Floating pill (v10). The bar's own three buttons are replaced by a
// pill that lives on the decorated view itself, so the user can drag
// it anywhere (AssistiveTouch-style) instead of having it fixed at the
// top-right blocking the app's own controls. Taps still work: the pan
// only takes over once the finger moves, otherwise the button fires.
static void MultitaskFloatSyncPill(DecoratedAppSceneViewController *vc) {
    if (!vc) return;
    UIView *pill = objc_getAssociatedObject(vc, &kMultitaskFloatPillKey);
    if (!pill) return;
    for (UIView *v in pill.subviews) {
        if ([v isKindOfClass:[UIButton class]] && v.tag == 1) {
            NSString *name = vc.isMaximized ? @"arrow.down.right.and.arrow.up.left.circle" : @"arrow.up.left.and.arrow.down.right.circle";
            UIImage *img = [UIImage systemImageNamed:name];
            UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
            [(UIButton *)v setImage:[img imageWithConfiguration:cfg] forState:UIControlStateNormal];
            break;
        }
    }
}

static void MultitaskFloatPillPan(id self, SEL _cmd, UIPanGestureRecognizer *sender) {
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    UIView *pill = objc_getAssociatedObject(vc, &kMultitaskFloatPillKey);
    if (!pill || !vc.view) return;
    CGRect allowed;
    if (vc.isMaximized && vc.view.window) {
        allowed = [vc.view convertRect:vc.view.window.bounds fromView:vc.view.window];
    } else {
        allowed = vc.view.bounds;
    }
    CGFloat hw = pill.bounds.size.width / 2, hh = pill.bounds.size.height / 2;
    if (sender.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [sender translationInView:vc.view];
        [sender setTranslation:CGPointZero inView:vc.view];
        CGPoint c = CGPointMake(pill.center.x + t.x, pill.center.y + t.y);
        c.x = fmax(allowed.origin.x + hw, fmin(c.x, allowed.origin.x + allowed.size.width - hw));
        c.y = fmax(allowed.origin.y + hh, fmin(c.y, allowed.origin.y + allowed.size.height - hh));
        pill.center = c;
    } else if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        // Dock to the nearest left/right edge on release, keep the height.
        CGFloat midX = allowed.origin.x + allowed.size.width / 2;
        CGFloat targetX = (pill.center.x < midX) ? (allowed.origin.x + hw + 8) : (allowed.origin.x + allowed.size.width - hw - 8);
        [UIView animateWithDuration:0.25 animations:^{
            pill.center = CGPointMake(targetX, pill.center.y);
        }];
    }
}

static void MultitaskFloatPillButton(id self, SEL _cmd, UIButton *sender) {
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    if (sender.tag == 0) {
        [vc minimizeWindow];
    } else if (sender.tag == 1) {
        [vc maximizeWindow];
        // The maximize icon flips in the completion (~0.3s); sync after it.
        __weak DecoratedAppSceneViewController *weakVC = vc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            MultitaskFloatSyncPill(weakVC);
        });
    } else if (sender.tag == 2) {
        [vc closeWindow];
    }
}

static void MultitaskFloatAddFloatingPill(DecoratedAppSceneViewController *vc) {
    if (!vc.view) return;
    if (objc_getAssociatedObject(vc, &kMultitaskFloatPillKey)) return;
    // The pill replaces the bar's buttons (both sides: bottom-bar mode
    // puts them on the left). Clearing both also neuters the left/right
    // swap that runs when the bottom-bar setting changes.
    vc.navigationItem.leftBarButtonItems = @[];
    vc.navigationItem.rightBarButtonItems = @[];
    CGFloat btn = 28, pad = 8, gap = 8;
    CGFloat pillW = pad * 2 + btn * 3 + gap * 2;
    CGFloat pillH = 40;
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pillW, pillH)];
    pill.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.75];
    pill.layer.cornerRadius = pillH / 2;
    pill.layer.masksToBounds = YES;
    // Left to right, matching the screenshots: minimize (yellow),
    // maximize (green), close (red). Same symbols, colors and point
    // size as the bar's original buttons.
    NSArray *names = @[@"minus.circle", @"arrow.up.left.and.arrow.down.right.circle", @"xmark.circle"];
    NSArray *colors = @[[UIColor systemYellowColor], [UIColor systemGreenColor], [UIColor systemRedColor]];
    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
    for (NSInteger i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(pad + i * (btn + gap), (pillH - btn) / 2, btn, btn);
        UIImage *img = [[UIImage systemImageNamed:names[i]] imageWithConfiguration:cfg];
        [b setImage:img forState:UIControlStateNormal];
        b.tintColor = colors[i];
        b.tag = i;
        [b addTarget:vc action:@selector(MultitaskFloatPillButton:) forControlEvents:UIControlEventTouchUpInside];
        [pill addSubview:b];
    }
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:vc action:@selector(MultitaskFloatPillPan:)];
    pan.minimumNumberOfTouches = 1;
    pan.maximumNumberOfTouches = 1;
    [pill addGestureRecognizer:pan];
    pill.alpha = 0; // placed (and shown) on first layout, once the window exists
    [vc.view addSubview:pill];
    [vc.view bringSubviewToFront:pill];
    objc_setAssociatedObject(vc, &kMultitaskFloatPillKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &kMultitaskFloatPillPlacedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Shared layout pass: strip the bar, extend the scene, hide the dock.
// Called from updateVerticalConstraints (covers maximize/restore and bar
// toggles) and from viewDidAppear (covers first appearance, when the
// window and the dock are guaranteed to exist — the v6 lesson).
static void MultitaskFloatApplyLayout(DecoratedAppSceneViewController *vc) {
    MultitaskFloatStripBar(vc);
    UIView *sceneView = vc.appSceneVC.view;
    if (sceneView && vc.view) {
        BOOL maximized = vc.isMaximized;
        CGFloat topOffset = 0;
        BOOL portrait = YES;
        if (maximized && vc.view.window) {
            topOffset = [vc.view convertRect:vc.view.bounds toView:vc.view.window].origin.y;
            UIWindowScene *ws = vc.view.window.windowScene;
            if (ws) portrait = UIInterfaceOrientationIsPortrait(ws.interfaceOrientation);
        }
        if (maximized) {
            // The decorated view clips subviews to its bounds
            // (cornerRadius 10, masksToBounds YES), and the scene is a
            // plain subview of it. Without this, the part of the scene
            // shifted above the decorated view's top edge is cut off
            // exactly there: the strip stays, and the cut reads as a
            // hard line at the top. Let the scene paint past the top
            // edge under the status bar. Windowed mode is left alone
            // so a floating window keeps its rounded corners.
            vc.view.layer.masksToBounds = NO;
        }
        BOOL changed = NO;
        for (NSLayoutConstraint *c in vc.activatedVerticalConstraints) {
            if (c.firstItem == sceneView &&
                (c.firstAttribute == NSLayoutAttributeTop || c.firstAttribute == NSLayoutAttributeBottom)) {
                CGFloat target;
                if (c.firstAttribute == NSLayoutAttributeTop) {
                    // Maximized + portrait: shift the scene up by the
                    // decorated view's window offset so the app paints
                    // under the status bar. Otherwise keep v5 behavior
                    // (scene under the bar, no gap).
                    target = (maximized && portrait) ? -topOffset : 0;
                } else {
                    target = 0;
                }
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
        // No settings update here: the guest's top safe area is grown
        // inside updateMaximizedSafeAreaWithSettings: (see the C-function
        // IMP below), so every host recompute produces the compensated
        // value instead of wiping an after-the-fact update.
    }
    // Keep the dock fully gone even if its view appears late.
    MultitaskFloatHideDockFully();
    // Place the floating pill once, when the window exists: top-right,
    // just below the status bar when maximized, at the decorated view's
    // top-right when windowed. After that the user owns the position.
    UIView *pill = objc_getAssociatedObject(vc, &kMultitaskFloatPillKey);
    NSNumber *placed = objc_getAssociatedObject(vc, &kMultitaskFloatPillPlacedKey);
    if (pill && (!placed || !placed.boolValue) && vc.view.window) {
        CGRect ref;
        CGFloat topInset = 0;
        if (vc.isMaximized) {
            ref = [vc.view convertRect:vc.view.window.bounds fromView:vc.view.window];
            topInset = vc.view.window.safeAreaInsets.top;
        } else {
            ref = vc.view.bounds;
        }
        CGFloat hw = pill.bounds.size.width / 2, hh = pill.bounds.size.height / 2;
        pill.center = CGPointMake(ref.origin.x + ref.size.width - hw - 12, ref.origin.y + topInset + hh + 8);
        pill.alpha = 1.0;
        objc_setAssociatedObject(vc, &kMultitaskFloatPillPlacedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Keep the pill's maximize icon in step with the window state.
    MultitaskFloatSyncPill(vc);
}

static void MultitaskFloatUpdateVerticalConstraints(id self, SEL _cmd) {
    origUpdateVerticalConstraints(self, _cmd);
    MultitaskFloatApplyLayout((DecoratedAppSceneViewController *)self);
}

// Forward declaration: defined after ViewDidAppear, used by it.
static void MultitaskFloatFixTopSafeArea(DecoratedAppSceneViewController *vc);

static void MultitaskFloatViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (origViewDidAppear) origViewDidAppear(self, _cmd, animated);
    MultitaskFloatApplyLayout((DecoratedAppSceneViewController *)self);
    MultitaskFloatFixTopSafeArea((DecoratedAppSceneViewController *)self);
}

// The initial maximized recompute runs before the decorated view's
// frame is final (during setup/activation), so the swizzle below
// computes off = 0 and the guest's top controls slide up — and
// nothing re-triggers a recompute after layout settles, until
// something like a dock change forces one (which is why collapsing
// the sidebar "fixes" it). So once the window appears and the frame
// is final, push the compensated safe area directly on the next
// runloop tick. This cannot double-add: the swizzle keeps every
// later recompute at the same value, because the original resets the
// base first and the swizzle adds on top each time.
static void MultitaskFloatFixTopSafeArea(DecoratedAppSceneViewController *vc) {
    if (!vc.isMaximized || !vc.view.window || !vc.appSceneVC) return;
    AppSceneViewController *appVC = vc.appSceneVC;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!vc.isMaximized || !vc.view.window) return;
        UIWindow *w = vc.view.window;
        BOOL portrait = YES;
        if (w.windowScene) portrait = UIInterfaceOrientationIsPortrait(w.windowScene.interfaceOrientation);
        if (!portrait) return;
        CGFloat off = [vc.view convertRect:vc.view.bounds toView:w].origin.y;
        if (off <= 0) return;
        CGFloat scale = 1.0;
        @try {
            NSNumber *n = [vc valueForKey:@"scaleRatio"];
            double v = [n doubleValue];
            if (v > 0) scale = (CGFloat)v;
        } @catch (id e) {}
        CGFloat add = off / scale;
        [appVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            UIEdgeInsets p = settings.peripheryInsets;
            p.top = add;
            settings.peripheryInsets = p;
            UIEdgeInsets pa = settings.safeAreaInsetsPortrait;
            pa.top = add;
            settings.safeAreaInsetsPortrait = pa;
        }];
    });
}

// Drag handle for the three buttons when maximized. moveWindow:
// early-returns when maximized, so the buttons could never drag the
// window. This gesture only begins when maximized (see the delegate
// below); on drag start it restores the window without animation and
// then moves it exactly like moveWindow: does.
static void MultitaskFloatDragWindow(id self, SEL _cmd, UIPanGestureRecognizer *sender) {
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    if (sender.state == UIGestureRecognizerStateBegan && vc.isMaximized) {
        [UIView performWithoutAnimation:^{
            [vc maximizeWindow];
        }];
        // Restore completed synchronously, so the icon flips now.
        MultitaskFloatSyncPill(vc);
    }
    [vc moveWindow:sender];
}

// Only take over button drags when maximized; otherwise let the
// original bar gesture move the window (and require it to fail when
// this one begins, so a maximized drag never moves twice).
static BOOL MultitaskFloatDragShouldBegin(id self, SEL _cmd, UIGestureRecognizer *gr) {
    BOOL origOK = origGestureShouldBegin ? origGestureShouldBegin(self, _cmd, gr) : YES;
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    return origOK && vc.isMaximized;
}

static void MultitaskFloatAddDragGesture(DecoratedAppSceneViewController *vc) {
    UINavigationBar *bar = vc.navigationBar;
    if (!bar) return;
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:vc action:@selector(MultitaskFloatDragWindow:)];
    drag.minimumNumberOfTouches = 1;
    drag.maximumNumberOfTouches = 1;
    drag.delegate = (id<UIGestureRecognizerDelegate>)vc;
    for (UIGestureRecognizer *g in bar.gestureRecognizers) {
        if ([g isKindOfClass:[UIPanGestureRecognizer class]]) {
            [g requireGestureRecognizerToFail:drag];
        }
    }
    [bar addGestureRecognizer:drag];
}

// Safe-area compensation inside the recompute path. A C-function IMP
// installed with method_setImplementation (see the constructor): it
// does NOT link CydiaSubstrate (unlike %hook, which would make the
// dylib fail to load on a jailed device) and does NOT reference the
// host class symbol at link time (unlike a category, which failed to
// link: _OBJC_CLASS_$_DecoratedAppSceneViewController lives in the
// host, not the dylib). The function is declared with the method's
// exact signature (UIEdgeInsets return), so on arm64 the compiler
// generates the same struct-return convention (result address in x8)
// as a real method — the ABI matches, and the original type encoding
// is left untouched, so NSInvocation-style callers stay correct too.
// Runs the original maximized safe-area computation, then grows the
// guest's top safe area by the same amount the scene was extended
// upward, so the app's top controls stay where they were and only
// background fills the status-bar strip. This must live inside the
// recompute path: an after-the-fact settings update gets wiped when
// the host recomputes (didUpdate -> maximized frame -> this method),
// but a value produced here survives every recompute, because the
// original resets the base first and this adds on top each time.
// The frame insets returned are left untouched: the decorated view
// itself stays below the status bar; only the scene extends past it.
typedef UIEdgeInsets (*MaximizedSafeAreaIMP)(id, SEL, UIMutableApplicationSceneSettings *);
static MaximizedSafeAreaIMP origMaximizedSafeArea;
static UIEdgeInsets MultitaskFloatMaximizedSafeArea(id self, SEL _cmd, UIMutableApplicationSceneSettings *settings) {
    UIEdgeInsets r = origMaximizedSafeArea(self, _cmd, settings);
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    if (vc.isMaximized && vc.view.window) {
        UIWindow *w = vc.view.window;
        BOOL portrait = YES;
        if (w.windowScene) portrait = UIInterfaceOrientationIsPortrait(w.windowScene.interfaceOrientation);
        CGFloat off = [vc.view convertRect:vc.view.bounds toView:w].origin.y;
        if (portrait && off > 0) {
            CGFloat scale = 1.0;
            @try {
                NSNumber *n = [vc valueForKey:@"scaleRatio"];
                double v = [n doubleValue];
                if (v > 0) scale = (CGFloat)v;
            } @catch (id e) {}
            CGFloat add = off / scale;
            UIEdgeInsets p = settings.peripheryInsets;
            p.top += add;
            settings.peripheryInsets = p;
            UIEdgeInsets pa = settings.safeAreaInsetsPortrait;
            pa.top += add;
            settings.safeAreaInsetsPortrait = pa;
        }
    }
    return r;
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
    // Safe-area compensation inside the recompute path (see above):
    // swap the method's implementation for the C function; the
    // original IMP is kept and called first.
    Method mSafe = class_getInstanceMethod(cls, @selector(updateMaximizedSafeAreaWithSettings:));
    if (mSafe) {
        origMaximizedSafeArea = (MaximizedSafeAreaIMP)method_getImplementation(mSafe);
        method_setImplementation(mSafe, (IMP)MultitaskFloatMaximizedSafeArea);
    }
    // viewDidAppear: the class does not define it, so adding an override
    // is safe; chain to UIViewController's implementation.
    Method mAppear = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    if (mAppear) {
        origViewDidAppear = (ViewDidAppearIMP)method_getImplementation(mAppear);
        if (!class_addMethod(cls, @selector(viewDidAppear:), (IMP)MultitaskFloatViewDidAppear, method_getTypeEncoding(mAppear))) {
            method_setImplementation(mAppear, (IMP)MultitaskFloatViewDidAppear);
        }
    }
    // Drag-gesture delegate: the class does not define it, so adding it
    // is safe; if it ever appears, chain to the original.
    if (!class_addMethod(cls, @selector(gestureRecognizerShouldBegin:), (IMP)MultitaskFloatDragShouldBegin, "c@:@")) {
        Method mDel = class_getInstanceMethod(cls, @selector(gestureRecognizerShouldBegin:));
        if (mDel) {
            origGestureShouldBegin = (GestureShouldBeginIMP)method_getImplementation(mDel);
            method_setImplementation(mDel, (IMP)MultitaskFloatDragShouldBegin);
        }
    }
    // The drag handler itself is a new selector, so adding it is safe.
    class_addMethod(cls, @selector(MultitaskFloatDragWindow:), (IMP)MultitaskFloatDragWindow, "v@:@");
    // Floating pill handlers are new selectors too, so adding them is safe.
    class_addMethod(cls, @selector(MultitaskFloatPillPan:), (IMP)MultitaskFloatPillPan, "v@:@");
    class_addMethod(cls, @selector(MultitaskFloatPillButton:), (IMP)MultitaskFloatPillButton, "v@:@");
}
