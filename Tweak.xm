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
// v14 notes (2026-10-25): v13 still left the sidebar up and the top
// slid up (user video 15:46: expanded dock with collapse chevron,
// minimize-all and an app icon, top still high). Root causes:
// (1) DockManagerClass used class_respondsToSelector to test +shared,
// but that function checks INSTANCE methods only, so it always
// returned NO for a class method and the dock code silently never
// ran in v5/v6/v11/v13 (crash fixed, dock never hidden). Fixed with
// class_getClassMethod, the correct test for a class method.
// (2) isCollapsed was set via KVC, which @Published properties do
// not reliably accept; now set via the real setIsCollapsed: setter
// (guarded, KVC fallback). (3) showDock re-adds the hosting view
// and was never redirected; now redirected to the hide helper too.
// (4) Top compensation derived off from the view's current frame,
// which is not final at first recompute / on maximize; now derived
// from the window's top safe-area inset (final from window creation,
// equal to the decorated view's final origin.y), and the fix is
// pushed from ApplyLayout so it covers maximize as well as
// appearance.
//
// v15 notes (2026-10-25): user on v14 reports minimize works but
// the top still slides up, and after shrinking to windowed mode the
// pill runs outside the app and cannot be tapped. Pill cause: a
// placed pill keeps its maximized coordinates after a resize, and
// ApplyLayout never re-clamped it, so in the smaller windowed view
// it sits outside the bounds where it is clipped (masksToBounds YES
// when windowed) and untappable; PillPan's maximized allowed rect
// also extended past the view's top edge. Fixed by clamping the
// pill to the decorated view's own bounds on every layout pass and
// in PillPan. Top hardening: off is now the max of the window safe
// area and the frame origin (a 0 from either source can no longer
// zero it), and the swizzle uses max instead of += so it cannot
// double-add when the nav bar is already hidden (the original then
// supplies the full top inset itself).
//
// v16 notes (2026-10-25): user screenshots (16:13, map app) show
// the pill still half outside the windowed window's right edge and
// the maximized search bar still under the status bar. The v15
// clamp lives in ApplyLayout, but ApplyLayout only runs from
// updateVerticalConstraints, which the host calls from the
// maximized branch (and setup/bar toggle) — never on restore to
// windowed or on minimize — so the clamp never fired on shrink.
// Fixed by swizzling maximizeWindow and minimizeWindow to run the
// layout pass after the original, so the clamp (and safe-area fix)
// apply on both directions of every window-state toggle.
//
// v17 notes (2026-10-25): user on v16 reports the top is still
// pushed under the status bar, and the shrunken small window has
// no drag place. Two causes, both in ApplyLayout: (1) The scene
// extension used the window safe area unconditionally, but when
// the bar is hidden (collapsed + maximized, the v14+ state) or at
// the bottom, the decorated view already starts at window y = 0,
// so extending by 59pt pushed the scene too far up and put the
// content under the status bar despite a correct safe area. The
// extension is now 0 when the bar is hidden or at the bottom, and
// the window safe area only when the top bar is visible. (2) The
// loop forced the scene top to 0 in windowed mode, moving the
// scene over the 44pt bar and covering the only drag handle, so
// the small window could not be dragged. The loop now only touches
// the top constraint in maximized + portrait and never touches
// the bottom constraint, leaving the host's windowed layout (scene
// below the bar) intact so the top strip stays draggable.
//
// v18 notes (2026-10-25): user diagnostics on v17 are decisive:
// v17 is installed the same way, EVERY app slides up (systemic,
// not app-specific), and only bringing out the sidebar and tapping
// it restores normal controls. That means only a dock interaction
// — a full host recompute with fully settled layout — has ever
// fixed the top; the settings-only fix does not replicate it.
// Fixed by forcing that same full recompute automatically: 0.5s
// after appearance (past the host's 0.3s layout animation),
// viewDidAppear schedules one updateVerticalConstraints call (via
// the swizzle, so orig + ApplyLayout run). It does not call
// viewDidAppear, so it cannot loop, and it is idempotent. The top
// may briefly start high and then drop to normal when the delayed
// recompute lands; that is expected.
//
// v19 notes (2026-10-25): user confirms v18 fixes the top, but on
// first open the pill lands in the status bar and has to be dragged
// down by hand. Cause: the pill is placed once, before the window
// safe area and view origin are final, so it lands at the view's
// top edge; the every-layout resize clamp only enforced the view
// bounds, which already contains the top edge, so it never moved
// the pill out of the status bar. Fixed by adding a status-bar
// floor to both the layout clamp and the drag clamp (maximized
// only): pill center.y must stay at or below windowSafeAreaTop -
// viewOriginY + half pill height + 4 in view coords. The delayed
// recompute runs with final values, so the pill auto-drops below
// the status bar without a manual drag (it may still briefly sit
// in the status bar for the first 0.5s). Windowed mode is left
// alone: the floating window does not fill the screen, so its top
// edge is not the status bar.
//
// v20 notes (2026-10-25): user accepts v19 (top + pill fixed) and
// asks for windowed-mode polish: device-like rounded corners and
// a draggable window (currently undraggable — the stripped bar is
// invisible, so there is no affordance to grab). Two changes, both
// windowed-only. (1) Corners: the maximized pass sets masksToBounds
// NO, which persisted into windowed mode and made the corners look
// square by letting content paint past them; windowed mode now
// restores masksToBounds YES and sets cornerRadius to the device's
// own display corner radius (via _displayCornerRadius KVC, fallback
// 28), so the floating window matches the handset. (2) Drag bar:
// an iPad-style capsule (40x5, gray, in an 80x28 hit area) at the
// top center of the window, shown only when windowed, re-centered
// on every layout pass; its pan reuses MultitaskFloatDragWindow:
// (moveWindow: moves the window directly when not maximized).
// The pill is kept on top so window controls win on overlap.
//
// v21 notes (2026-10-25): user confirms v20 IS installed, yet
// corners are still square and no capsule appears — a real v20
// bug, not a stale version. Cause: window chrome lived only in
// ApplyLayout, which never re-runs after a restore through a path
// this tweak does not hook (and host layout can reset cornerRadius
// after ApplyLayout runs), so the window kept its maximized layer
// state (masksToBounds NO, drag bar hidden) while floating.
// Fixed by factoring chrome into MultitaskFloatSyncWindowChrome
// (corners + drag bar, single source of truth) and calling it
// from viewDidLayoutSubviews as well, so it re-syncs after EVERY
// layout pass, after the host's layout code; it sets layer flags
// and positions only, never constraints, so it cannot loop. The
// capsule is also made conspicuous (48x6, 0.65 alpha, 88x30 hit
// area) so it cannot be missed.
//
// v22 notes (2026-10-25): user on v21 reports no effect at first;
// only dragging the bottom-right resize handle makes corners +
// capsule appear. That is decisive: the resize triggers a layout
// pass (viewDidLayoutSubviews) with final state, while initial
// appearance / restore runs with stale isMaximized or intermediate
// bounds and fires no further layout pass until a resize. Fixed by
// re-syncing chrome once settled: a delayed SyncWindowChrome
// (0.35s, past the 0.3s toggle animation) in the maximize/minimize
// swizzles, and in viewDidAppear's existing delayed block (0.5s).
// Same pattern as the v18 top fix (delayed recompute with final
// state). The sync sets layer flags + positions only, so it cannot
// loop, and it is idempotent.
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
- (void)updateVerticalConstraints;
@end


typedef id (*DecoratedInitIMP)(id, SEL, NSString *, NSString *, NSString *, UIViewController *);
typedef void (*VoidIMP)(id, SEL);
typedef void (*ViewDidAppearIMP)(id, SEL, BOOL);
typedef BOOL (*GestureShouldBeginIMP)(id, SEL, UIGestureRecognizer *);
static DecoratedInitIMP origDecoratedInit = NULL;
static VoidIMP origUpdateVerticalConstraints = NULL;
static ViewDidAppearIMP origViewDidAppear = NULL;
static VoidIMP origViewDidLayoutSubviews = NULL;
static GestureShouldBeginIMP origGestureShouldBegin = NULL;
static BOOL dockSwizzled = NO;

// Floating pill (v10): the three buttons detached from the nav bar so
// the user can drag them anywhere like AssistiveTouch instead of
// having them block the app's own controls. Stored on the VC.
static const char kMultitaskFloatPillKey = 0;
static const char kMultitaskFloatPillPlacedKey = 0;
static const char kMultitaskFloatDragBarKey = 0;
static const char kMultitaskFloatAnimatingOpenKey = 0;

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
    // NOTE (v14 fix): class_respondsToSelector checks INSTANCE methods
    // only, so it always returns NO for +shared (a class method) and
    // this function always returned Nil — which is why the dock code
    // silently never ran in v5/v6/v11/v13 even though the crash was
    // fixed. class_getClassMethod checks the metaclass, which is the
    // correct test for a class method.
    if (!class_getClassMethod(cls, @selector(shared))) return Nil;
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
    // Use the real setter (not KVC) for isCollapsed: @Published
    // properties do not reliably accept KVC writes, but the @objc
    // setter does notify SwiftUI. Fall back to KVC if no setter.
    @try {
        BOOL collapsed = NO;
        if ([manager respondsToSelector:@selector(isCollapsed)]) {
            collapsed = ((BOOL (*)(id, SEL))objc_msgSend)(manager, @selector(isCollapsed));
        } else {
            id v = [manager valueForKey:@"isCollapsed"];
            collapsed = v ? [v boolValue] : NO;
        }
        if (!collapsed) {
            if ([manager respondsToSelector:@selector(setIsCollapsed:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(manager, @selector(setIsCollapsed:), YES);
            } else {
                [manager setValue:@YES forKey:@"isCollapsed"];
            }
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
    // so the redirect never sends an unimplemented selector. showDock
    // is redirected too: it re-adds the hosting view and animates it
    // to full alpha, so leaving it alone would bring the dock back
    // even with the other paths redirected. Redirecting to the hide
    // helper (a supported hide, not a no-op) keeps state consistent.
    if (!class_getInstanceMethod(cls, @selector(hideDockToSide))) return;
    Method mShowDock = class_getInstanceMethod(cls, @selector(showDock));
    if (mShowDock) method_setImplementation(mShowDock, (IMP)MultitaskFloatForceHideDock);
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
// Pill border follows appearance (v27): black in light mode, white
// in dark mode (day-black / night-white). A layer borderColor is a
// resolved CGColor, so it does not follow trait changes on its own —
// it must be re-applied on every sync.
static void MultitaskFloatApplyPillBorder(UIView *pill, UIView *view) {
    if (!pill || !view) return;
    BOOL dark = (view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    UIColor *c = dark ? [[UIColor whiteColor] colorWithAlphaComponent:0.6] : [[UIColor blackColor] colorWithAlphaComponent:0.6];
    pill.layer.borderColor = c.CGColor;
}

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
    MultitaskFloatApplyPillBorder(pill, vc.view);
}

static void MultitaskFloatPillPan(id self, SEL _cmd, UIPanGestureRecognizer *sender) {
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    UIView *pill = objc_getAssociatedObject(vc, &kMultitaskFloatPillKey);
    if (!pill || !vc.view) return;
    // Always clamp to the decorated view's own bounds (the tappable
    // area): in maximized mode the old window-bounds rect extended
    // past the view's top edge, and after a shrink to windowed mode
    // a pill placed in maximized coordinates can sit outside the
    // smaller view, where it is clipped (masksToBounds YES when
    // windowed) and untappable.
    CGRect allowed = vc.view.bounds;
    CGFloat hw = pill.bounds.size.width / 2, hh = pill.bounds.size.height / 2;
    // Status-bar floor in maximized mode (same as the layout
    // clamp): the pill must stay below the status bar, not just
    // inside the view bounds, or it ends up overlapping the status
    // bar and has to be dragged down by hand.
    CGFloat minCenterY = allowed.origin.y + hh;
    if (vc.isMaximized && vc.view.window) {
        CGFloat floorY = vc.view.window.safeAreaInsets.top - vc.view.frame.origin.y;
        if (floorY > allowed.origin.y) minCenterY = fmax(minCenterY, floorY + hh + 4);
    }
    if (sender.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [sender translationInView:vc.view];
        [sender setTranslation:CGPointZero inView:vc.view];
        CGPoint c = CGPointMake(pill.center.x + t.x, pill.center.y + t.y);
        c.x = fmax(allowed.origin.x + hw, fmin(c.x, allowed.origin.x + allowed.size.width - hw));
        c.y = fmax(minCenterY, fmin(c.y, allowed.origin.y + allowed.size.height - hh));
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
    pill.backgroundColor = [UIColor clearColor];
    pill.layer.cornerRadius = pillH / 2;
    // masksToBounds NO so the shadow below is not clipped; the blur
    // view itself still clips to the pill shape (see below), and the
    // buttons sit inset by pad, so nothing overflows the rounded rect.
    pill.layer.masksToBounds = NO;
    pill.layer.borderWidth = 1.0;
    MultitaskFloatApplyPillBorder(pill, vc.view);
    pill.layer.shadowColor = [[UIColor blackColor] CGColor];
    pill.layer.shadowOpacity = 0.15;
    pill.layer.shadowRadius = 8;
    pill.layer.shadowOffset = CGSizeMake(0, 2);
    // Liquid glass (v29): v28 tried +[UIGlassEffect glassEffect],
    // but that factory does not exist — the real API is
    // [[UIGlassEffect alloc] init] (Swift: UIGlassEffect()), so v28
    // silently fell back to ultra-thin blur and the pill stayed
    // frosted. Use alloc/init via runtime lookup (no compile-time
    // dependency, so older SDKs still build), with an ultra-thin
    // blur fallback only when the class is absent. The effect view
    // sits behind the buttons, follows the pill's bounds, and never
    // intercepts touches (buttons and the drag pan keep working).
    UIVisualEffect *glassEffect = nil;
    Class liquidCls = NSClassFromString(@"UIGlassEffect");
    if (liquidCls) {
        glassEffect = [[liquidCls alloc] init];
    }
    if (!glassEffect) {
        glassEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
    }
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:glassEffect];
    glass.frame = pill.bounds;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glass.layer.cornerRadius = pillH / 2;
    glass.clipsToBounds = YES;
    glass.userInteractionEnabled = NO;
    [pill insertSubview:glass atIndex:0];
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

// Forward declaration: defined after ViewDidAppear, used by ApplyLayout.
static void MultitaskFloatFixTopSafeArea(DecoratedAppSceneViewController *vc);

// Shared layout pass: strip the bar, extend the scene, hide the dock.
// Called from updateVerticalConstraints (covers maximize/restore and bar
// toggles) and from viewDidAppear (covers first appearance, when the
// window and the dock are guaranteed to exist — the v6 lesson).
// Device display corner radius (the handset's own screen corners),
// for windowed-mode window corners. Read once via KVC; falls back
// to 28 when the key is unavailable.
static CGFloat MultitaskFloatDeviceCornerRadius(void) {
    static CGFloat cached = -1;
    if (cached >= 0) return cached;
    CGFloat radius = 28;
    @try {
        NSNumber *cr = [[UIScreen mainScreen] valueForKey:@"_displayCornerRadius"];
        if (cr && cr.doubleValue > 0) radius = cr.doubleValue;
    } @catch (NSException *e) {
    }
    cached = radius;
    return radius;
}

// Window chrome sync (corners + drag bar), called from ApplyLayout
// and from viewDidLayoutSubviews. Windowed only for corners/drag
// bar; maximized only clears clipping so the scene can paint past
// the top edge. The capsule is deliberately conspicuous (48x6,
// 0.65 alpha) so it cannot be missed.
static void MultitaskFloatSyncWindowChrome(DecoratedAppSceneViewController *vc) {
    if (!vc.view) return;
    // During the open animation (v29) the window's corners are part
    // of the pop (rounded while it scales in); layout passes during
    // the animation must not reset masks/cornerRadius, or the pop
    // would lose its rounded clip mid-flight (maximized clears
    // clipping outright). The drag bar and pill border below still
    // sync. The animation's completion re-syncs chrome itself.
    BOOL animatingOpen = [objc_getAssociatedObject(vc, &kMultitaskFloatAnimatingOpenKey) boolValue];
    if (!animatingOpen) {
        if (vc.isMaximized) {
            vc.view.layer.masksToBounds = NO;
        } else {
            vc.view.layer.cornerRadius = MultitaskFloatDeviceCornerRadius();
            vc.view.layer.masksToBounds = YES;
        }
    }
    UIView *dragBar = objc_getAssociatedObject(vc, &kMultitaskFloatDragBarKey);
    if (!dragBar) {
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 88, 30)];
        container.backgroundColor = [UIColor clearColor];
        UIView *capsule = [[UIView alloc] initWithFrame:CGRectMake(20, 12, 48, 6)];
        capsule.backgroundColor = [[UIColor systemGrayColor] colorWithAlphaComponent:0.65];
        capsule.layer.cornerRadius = 3;
        capsule.layer.masksToBounds = YES;
        [container addSubview:capsule];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:vc action:@selector(MultitaskFloatDragWindow:)];
        pan.minimumNumberOfTouches = 1;
        pan.maximumNumberOfTouches = 1;
        [container addGestureRecognizer:pan];
        [vc.view addSubview:container];
        objc_setAssociatedObject(vc, &kMultitaskFloatDragBarKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dragBar = container;
    }
    dragBar.hidden = vc.isMaximized;
    if (!vc.isMaximized) {
        CGRect b = vc.view.bounds;
        dragBar.center = CGPointMake(b.origin.x + b.size.width / 2, b.origin.y + 22);
        [vc.view bringSubviewToFront:dragBar];
        UIView *pillTop = objc_getAssociatedObject(vc, &kMultitaskFloatPillKey);
        if (pillTop) [vc.view bringSubviewToFront:pillTop];
    }
    // Pill border follows appearance (v27): re-applied on every
    // layout pass, so a system day/night switch recolors it without
    // waiting for a maximize/minimize.
    UIView *pillBorder = objc_getAssociatedObject(vc, &kMultitaskFloatPillKey);
    if (pillBorder) MultitaskFloatApplyPillBorder(pillBorder, vc.view);
}

static void MultitaskFloatApplyLayout(DecoratedAppSceneViewController *vc) {
    MultitaskFloatStripBar(vc);
    UIView *sceneView = vc.appSceneVC.view;
    if (sceneView && vc.view) {
        BOOL maximized = vc.isMaximized;
        CGFloat topOffset = 0;
        BOOL portrait = YES;
        // Bottom-bar mode: the scene's bottom constraint is inset by
        // the bar height, which means the decorated view already fills
        // the window from y = 0 (maxFrame is full), just like when
        // the top bar is hidden. Detect it from the constraints so
        // no new host API is needed.
        BOOL bottomBar = NO;
        for (NSLayoutConstraint *c in vc.activatedVerticalConstraints) {
            if (c.firstItem == sceneView && c.firstAttribute == NSLayoutAttributeBottom && c.constant < 0) bottomBar = YES;
        }
        if (maximized && vc.view.window) {
            UIWindowScene *ws = vc.view.window.windowScene;
            if (ws) portrait = UIInterfaceOrientationIsPortrait(ws.interfaceOrientation);
            // The extension must equal the decorated view's final
            // origin.y in the window. That origin is the window's top
            // safe-area inset ONLY when the top bar is visible: when
            // the bar is hidden (collapsed + maximized) or the bar is
            // at the bottom, maxFrame is the full window, so the view
            // already starts at y = 0 and the extension must be 0 —
            // extending by the safe area there pushed the scene 59pt
            // too far up and put the content under the status bar
            // even with a correct safe area (the v16 top bug).
            if (portrait) {
                topOffset = (vc.navigationBar.hidden || bottomBar) ? 0 : vc.view.window.safeAreaInsets.top;
            }
        }
        if (maximized) {
            // The decorated view clips subviews to its bounds
            // (cornerRadius 10, masksToBounds YES), and the scene is a
            // plain subview of it. Without this, the part of the scene
            // shifted above the decorated view's top edge is cut off
            // exactly there: the strip stays, and the cut reads as a
            // hard line at the top. Let the scene paint past the top
            // edge under the status bar. (Window chrome, including
            // this flag, is synced below via SyncWindowChrome.)
            vc.view.layer.masksToBounds = NO;
        }
        BOOL changed = NO;
        for (NSLayoutConstraint *c in vc.activatedVerticalConstraints) {
            if (c.firstItem == sceneView && c.firstAttribute == NSLayoutAttributeTop) {
                // Only in maximized + portrait do we shift the scene
                // up so the app paints under the status bar. In every
                // other case the host's value is left alone: forcing
                // it to 0 in windowed mode moved the scene over the
                // 44pt bar, covering the only drag handle, so the
                // small window could not be dragged (the v16 windowed
                // bug). The bottom constraint is never touched: the
                // host value is correct in both top-bar (0) and
                // bottom-bar (-barHeight) modes.
                if (maximized && portrait) {
                    CGFloat target = -topOffset;
                    if (c.constant != target) {
                        c.constant = target;
                        changed = YES;
                    }
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
    // Resize clamp: after a maximize/restore the view's bounds change
    // but a placed pill keeps its old center, which can end up
    // outside the smaller windowed view (clipped and untappable).
    // Pull it back inside on every layout pass. In maximized mode
    // also enforce a status-bar floor: the bounds clamp alone
    // allows the pill at the view's top edge, which is window y = 0
    // when the bar is hidden — inside the status bar. On first
    // open the pill is placed before the window safe area and view
    // origin are final, so it lands at the top edge and the bounds
    // clamp never moves it (it is already in bounds), leaving it
    // in the status bar until the user drags it down by hand (the
    // v18 first-open pill bug). The floor in view coords is
    // windowSafeAreaTop - viewOriginY; it is only trusted once
    // the window has a real safe area (before that it is 0 and
    // the bounds floor already applies). The delayed recompute
    // (0.5s) runs with final values, so the pill auto-drops below
    // the status bar without a manual drag. Windowed mode is left
    // alone: the floating window does not fill the screen, so its
    // top edge is not the status bar.
    if (pill && vc.view) {
        CGRect b = vc.view.bounds;
        if (b.size.width > pill.bounds.size.width && b.size.height > pill.bounds.size.height) {
            CGFloat pw = pill.bounds.size.width / 2, ph = pill.bounds.size.height / 2;
            CGFloat bottomY = b.origin.y + b.size.height - ph - 4;
            CGFloat minY = b.origin.y + ph + 4;
            if (vc.isMaximized && vc.view.window) {
                CGFloat floorY = vc.view.window.safeAreaInsets.top - vc.view.frame.origin.y;
                if (floorY > b.origin.y) minY = fmax(minY, floorY + ph + 4);
            }
            minY = fmin(minY, bottomY);
            CGPoint c = pill.center;
            c.x = fmax(b.origin.x + pw + 4, fmin(c.x, b.origin.x + b.size.width - pw - 4));
            c.y = fmax(minY, fmin(c.y, bottomY));
            pill.center = c;
        }
    }
    // Window chrome (corners + drag bar) is synced here and from
    // viewDidLayoutSubviews, so it survives host resets and restore
    // paths that never call ApplyLayout (the v20 windowed bug: both
    // features were absent even with v20 loaded, because ApplyLayout
    // never re-ran after a restore through an unhooked path).
    MultitaskFloatSyncWindowChrome(vc);
    // Keep the pill's maximize icon in step with the window state.
    MultitaskFloatSyncPill(vc);
    // Push the compensated safe area (covers appearance AND maximize:
    // ApplyLayout runs on both paths, and the fix re-checks state on
    // its async tick, so it is idempotent).
    MultitaskFloatFixTopSafeArea(vc);
}

static void MultitaskFloatUpdateVerticalConstraints(id self, SEL _cmd) {
    origUpdateVerticalConstraints(self, _cmd);
    MultitaskFloatApplyLayout((DecoratedAppSceneViewController *)self);
}

static VoidIMP origMaximizeWindow = NULL;
static VoidIMP origMinimizeWindow = NULL;

// Window-state toggles: updateVerticalConstraints is only called
// from the maximized branch (and setup/bar toggle), so restoring
// to windowed (or minimizing) never ran ApplyLayout — the pill
// clamp in v15 therefore never fired on shrink, and the pill stayed
// outside the smaller view. Run the layout pass after every
// maximize/minimize toggle so the clamp (and safe-area fix) apply
// on both directions.
static void MultitaskFloatMaximizeWindow(id self, SEL _cmd) {
    if (origMaximizeWindow) origMaximizeWindow(self, _cmd);
    MultitaskFloatApplyLayout((DecoratedAppSceneViewController *)self);
    // Delayed chrome sync: the immediate ApplyLayout can run with a
    // stale isMaximized or intermediate bounds (the toggle animates
    // over 0.3s), and restore paths may not fire another layout pass
    // until the user resizes (the v21 first-open bug: no effect until
    // the resize handle was dragged). Re-sync once settled.
    __weak DecoratedAppSceneViewController *weakVC = (DecoratedAppSceneViewController *)self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
}

static void MultitaskFloatMinimizeWindow(id self, SEL _cmd) {
    if (origMinimizeWindow) origMinimizeWindow(self, _cmd);
    MultitaskFloatApplyLayout((DecoratedAppSceneViewController *)self);
    // Same delayed chrome sync as maximize (see above).
    __weak DecoratedAppSceneViewController *weakVC = (DecoratedAppSceneViewController *)self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
}

// Last tap point, for the icon-origin open animation: the user taps
// an app icon to open its window, so the last touch-up location is
// (to within the icon) where the window should grow from. Captured
// globally via UIWindow sendEvent: (pure runtime swizzle; the
// replacement itself runs at touch time, never in the constructor).
// Only used if recent (< 3s) and inside the appearing view;
// otherwise the animation falls back to a center scale, so an open
// never shows no animation.
static CGPoint MultitaskFloatLastTapPoint = {0, 0};
static NSTimeInterval MultitaskFloatLastTapTime = 0;
typedef void (*SendEventIMP)(id, SEL, UIEvent *);
static SendEventIMP origSendEvent = NULL;
static void MultitaskFloatSendEvent(id self, SEL _cmd, UIEvent *event) {
    // Record BEFORE orig: a launch tap opens its guest synchronously
    // inside origSendEvent (button action -> viewDidAppear), so
    // recording after orig is too late — the first open always saw
    // the previous tap (or none) and fell back to a center fade
    // instead of growing from the tapped row (the v25 first-open bug).
    @try {
        if (event.type == UIEventTypeTouches) {
            for (UITouch *touch in event.allTouches) {
                if (touch.phase == UITouchPhaseEnded && touch.window) {
                    MultitaskFloatLastTapPoint = [touch locationInView:touch.window];
                    MultitaskFloatLastTapTime = [[NSDate date] timeIntervalSince1970];
                }
            }
        }
    } @catch (NSException *e) {}
    if (origSendEvent) origSendEvent(self, _cmd, event);
}

// Open animation, v25: grow from the tapped icon (like iOS opening
// an app), not from the center. Every appearance animates: the v23
// one-shot flag is why a second open showed no animation when the
// VC was reused. Transform + alpha are independent of the host's
// frame/constraint animation, so the two compose instead of fighting.
// v34: embedded LiveContainer mark (light AppIcon, 512px, from
// upstream Resources/Assets.xcassets/AppIcon.appiconset/
// AppIcon1024.png, downscaled). The repo dark variant renders
// glitched, so the light mark is used for both appearances.
// Decoded at pop time into a UIImage (no asset catalog needed).
static const char kMultitaskFloatLogoBase64[] =
    "iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAIAAAB7GkOtAAAACXBIWXMAAAABAAAAAQBPJcTWAAAA"
    "/WVYSWZJSSoACAAAAAgAGgEFAAEAAABuAAAAGwEFAAEAAAB2AAAAKAEDAAEAAAACAAAAMQECACEA"
    "AAB+AAAAMgECABQAAACfAAAAaYcNAAEAAACzAAAAAAEEAAEAAAAAAgAAAQEEAAEAAAAAAgAAAAAA"
    "AEgAAAABAAAASAAAAAEAAABBZG9iZSBQaG90b3Nob3AgMjYuMSAoTWFjaW50b3NoKQAyMDI1OjA2"
    "OjI2IDAwOjE1OjU4AAQABJACABQAAADpAAAAAaADAAEAAAABAAAAAqADAAEAAAAAAgAAA6ADAAEA"
    "AAAAAgAA/QAAADIwMjU6MDY6MjQgMTU6NTQ6NTgAphbEuQAAAAFzUkdCAdnJLH8AAAAgY0hSTQAA"
    "eiYAAICEAAD6AAAAgOgAAHUwAADqYAAAOpgAABdwnLpRPAAAAARnQU1BAACxjwv8YQUAABAASURB"
    "VHic7L1ZkyNLeiXmgX1P5J7Itfa69/Zyu9lkUyRHwxkbUrKZMc1IMv4k/Qe9yvQokx70IpnMJNOM"
    "SJrUnF7J7r5962ZV5b4DyAX7FjruJxGFyszKApCIgEfCj1WjkbhAhLuH+/kW//z7LPHf2cLAwMDA"
    "YPIQGncDDAwMDAzGAyMADAwMDCYURgAYGBgYTCiMADAwMDCYUBgBYGBgYDChMALAwMDAYEJhBICB"
    "gYHBhCIkzDEAAwMDg4mEsQAMDAwMJhRGABgYGBhMKIwAMDAwMJhQGAFgYGBgMKEwAsDAwMBgQmEE"
    "gIGBgcGEwggAAwMDgwmFEQAGBgYGEwojAAwMDAwmFEYAGBgYGEwojAAwMDAwmFAYAWBgYGAwoTAC"
    "wMDAwGBCYQSAgYGBwYTCCAADAwODCYWpB2BgYGAwoTAWgIGBgcGEwggAAwMDgwmFEQAGBgYGEwoj"
    "AAwMDAwmFEYAGBgYGEwojAAwMDAwmFAYAWBgYGAwoTACwMDAwGBCYQSAgYGBwYTCCAADAwODCYUR"
    "AAYGBgYTCiMADAwMDCYURgAYGBgYTCiMADAwMDCYUJh00AYGBgYTCmMBGBgYGEwojAAwMDAwmFAY"
    "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"
    "CaCCrsaSAAAAAElFTkSuQmCC";

static void MultitaskFloatAnimateOpen(DecoratedAppSceneViewController *vc) {
    if (!vc.view || !vc.view.window) return;
    UIView *view = vc.view;
    CGPoint anchor = CGPointMake(0.5, 0.5);
    CGFloat startScale = 0.94;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - MultitaskFloatLastTapTime < 3.0 && view.bounds.size.width > 0 && view.bounds.size.height > 0) {
        CGPoint ptInView = [view convertPoint:MultitaskFloatLastTapPoint fromView:view.window];
        if (ptInView.x >= 0 && ptInView.x <= view.bounds.size.width && ptInView.y >= 0 && ptInView.y <= view.bounds.size.height) {
            anchor = CGPointMake(ptInView.x / view.bounds.size.width, ptInView.y / view.bounds.size.height);
            startScale = 0.3;
        }
    }
    // Scale around the anchor: set the layer anchor (with position
    // compensation so the view does not jump), then spring to identity.
    CALayer *layer = view.layer;
    CGPoint oldAnchor = layer.anchorPoint;
    CGPoint oldPoint = CGPointMake(view.bounds.size.width * oldAnchor.x, view.bounds.size.height * oldAnchor.y);
    CGPoint newPoint = CGPointMake(view.bounds.size.width * anchor.x, view.bounds.size.height * anchor.y);
    CGPoint pos = layer.position;
    pos.x -= oldPoint.x; pos.x += newPoint.x;
    pos.y -= oldPoint.y; pos.y += newPoint.y;
    layer.position = pos;
    layer.anchorPoint = anchor;
    // v29: rounded pop with a spring (the user asked for both back).
    // The window morphs like an iOS app opening from its icon: it
    // starts round on screen (model radius = device radius divided
    // by the start scale, so the scaled-down view still reads as
    // device-round) and settles to the mode's final radius — device
    // radius when windowed, 0 when maximized (full-screen square).
    // masksToBounds stays YES through the pop so the corners clip;
    // SyncWindowChrome is guarded while this flag is set, and the
    // completion re-syncs chrome (maximized: radius already 0, so
    // clearing clipping at the end causes no snap).
    CGFloat deviceRadius = MultitaskFloatDeviceCornerRadius();
    CGFloat finalRadius = vc.isMaximized ? 0 : deviceRadius;
    layer.cornerRadius = deviceRadius / startScale;
    layer.masksToBounds = YES;
    view.alpha = 0;
    view.transform = CGAffineTransformMakeScale(startScale, startScale);
    objc_setAssociatedObject(vc, &kMultitaskFloatAnimatingOpenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // v31: bottom-strip cover (the user's suggestion). During the pop
    // the scaled view does not fill the window, so the LiveContainer
    // list underneath peeks through at the edges — most visible at
    // the bottom, where the list's colorful tab bar shows as a thin
    // strip (the video's black-loading frames). An
    // appearance-matched cover below the decorated view hides the
    // whole underneath during the pop. v32: white by day, black by
    // night — the user corrected v31 here, a black cover is wrong
    // in daytime.
    // Maximized only: in windowed mode the list around the small
    // window is supposed to be visible. At pop end (after the
    // recompute in the completion below) the view fills the
    // window, so the cover is already fully hidden behind it and
    // fading it out causes no visual change. No touches: the cover
    // never intercepts (the animations run under 0.5s and the buttons stay above).
    UIView *popCover = nil;
    if (vc.isMaximized && vc.view.superview) {
        popCover = [[UIView alloc] initWithFrame:vc.view.superview.bounds];
        // v32: cover color follows appearance (the user corrected
        // v31: a black cover is wrong in daytime). Day -> white,
        // night -> black, matching the host list / guest loading
        // background on each side of the pop.
        popCover.backgroundColor = (vc.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? [UIColor blackColor] : [UIColor whiteColor];
        popCover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        popCover.userInteractionEnabled = NO;
        [vc.view.superview insertSubview:popCover belowSubview:vc.view];
    }
    // v34: centered LiveContainer logo overlay (the user chose
    // the LiveContainer mark). It sits ABOVE the guest view (in
    // the superview, above vc.view) so it masks the guest content
    // popping in (black loading -> UI), which the under-view
    // cover cannot hide. Centered, squircle-clipped, starts at
    // 0.6x and expands to 2.5x while fading out over 0.45s
    // (ease-out), concurrent with the shortened pop — total
    // window animation stays under 0.5s. Removed in its own
    // completion, so it can never outlive the animation even if
    // the window closes mid-flight. If the image fails to
    // decode, the logo is skipped (pop + cover still work).
    UIImageView *logoView = nil;
    if (vc.isMaximized && vc.view.superview) {
        NSData *logoData = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:kMultitaskFloatLogoBase64] options:0];
        UIImage *logoImage = logoData ? [UIImage imageWithData:logoData] : nil;
        if (logoImage) {
            CGFloat logoSize = 120;
            logoView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, logoSize, logoSize)];
            logoView.image = logoImage;
            logoView.contentMode = UIViewContentModeScaleAspectFit;
            logoView.userInteractionEnabled = NO;
            logoView.layer.cornerRadius = logoSize * 0.2237;
            logoView.layer.cornerCurve = kCACornerCurveContinuous;
            logoView.layer.masksToBounds = YES;
            logoView.center = CGPointMake(CGRectGetMidX(vc.view.superview.bounds), CGRectGetMidY(vc.view.superview.bounds));
            logoView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            logoView.transform = CGAffineTransformMakeScale(0.6, 0.6);
            [vc.view.superview addSubview:logoView];
        }
    }
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
        view.alpha = 1;
        view.transform = CGAffineTransformIdentity;
        view.layer.cornerRadius = finalRadius;
    } completion:^(BOOL finished) {
        (void)finished;
        objc_setAssociatedObject(vc, &kMultitaskFloatAnimatingOpenKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Restore the default anchor (invisible: transform is identity).
        CALayer *l = view.layer;
        CGPoint curAnchor = l.anchorPoint;
        CGPoint curPoint = CGPointMake(view.bounds.size.width * curAnchor.x, view.bounds.size.height * curAnchor.y);
        CGPoint defPoint = CGPointMake(view.bounds.size.width * 0.5, view.bounds.size.height * 0.5);
        CGPoint p = l.position;
        p.x -= curPoint.x; p.x += defPoint.x;
        p.y -= curPoint.y; p.y += defPoint.y;
        l.position = p;
        l.anchorPoint = CGPointMake(0.5, 0.5);
        // Settle final chrome (guarded syncs during the pop skipped
        // the masks/radius part).
        if (vc.view.window) {
            MultitaskFloatSyncWindowChrome(vc);
        }
        // v30: full recompute once the pop ends and the transform is
        // identity. ApplyLayout at appear ran with intermediate bounds
        // and a scale transform, so the scene/safe-area geometry could
        // be wrong (top blocked, bottom cut) until the 0.5s timer
        // fixed it — the current symptom. Recomputing here (host
        // orig + ApplyLayout via the updateVerticalConstraints
        // swizzle) settles geometry at pop end instead of leaving a
        // visible snap for later. The 0.5s block stays as a safety net.
        if (vc.view.window) {
            [vc updateVerticalConstraints];
        }
        // v33: fade the pop cover out instead of dropping it
        // instantly (the user called the instant removal stiff).
        // Two changes vs v31/v32: (1) the cover now outlives the
        // recompute above, so the view fills the window BEFORE
        // the cover goes away — removing it first exposed the
        // list in any not-yet-settled gap as a snap; (2) it
        // fades (0.15s ease-out, shortened in v34) instead of
        // vanishing, so any still-visible part dissolves instead
        // of snapping. If the view already fills the window, the
        // cover is fully hidden behind it and the fade is
        // invisible. The fade's own completion removes it, so it
        // can never outlive the fade even if the window closes
        // mid-fade. No-op when there is no cover (e.g. windowed
        // mode).
        if (popCover) {
            [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                popCover.alpha = 0;
            } completion:^(BOOL fadeFinished) {
                (void)fadeFinished;
                [popCover removeFromSuperview];
            }];
        }
    }];
    // v34: logo expand + fade (concurrent with the pop, not
    // after it, so it adds no extra time).
    if (logoView) {
        [UIView animateWithDuration:0.45 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            logoView.transform = CGAffineTransformMakeScale(2.5, 2.5);
            logoView.alpha = 0;
        } completion:^(BOOL logoFinished) {
            (void)logoFinished;
            [logoView removeFromSuperview];
        }];
    }
}

static void MultitaskFloatViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (origViewDidAppear) origViewDidAppear(self, _cmd, animated);
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    MultitaskFloatAnimateOpen(vc);
    MultitaskFloatApplyLayout(vc);
    // Delayed full recompute: the user's diagnostics (v17) show that
    // only a dock interaction has ever fixed the top, and it works
    // by forcing a host recompute with fully settled layout (final
    // frame, final window safe area). The settings-only fix above
    // does not replicate that. Mimic the dock interaction
    // automatically once layout has settled (past the host's 0.3s
    // layout animation). This calls updateVerticalConstraints, not
    // viewDidAppear, so it cannot loop; it is idempotent.
    __weak DecoratedAppSceneViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window && strongVC.isMaximized) {
            [strongVC updateVerticalConstraints];
        }
        // Delayed chrome sync for the same settled-state reason as
        // the toggle swizzles (v21 first-open bug): initial layout
        // can run with stale state, and no further layout pass fires
        // until the user resizes.
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
}

// viewDidLayoutSubviews: re-sync window chrome after EVERY layout
// pass, after the host's layout code. This is the robust path for
// windowed corners + drag bar: ApplyLayout alone misses restore
// paths that never call it (and host layout can reset cornerRadius
// after ApplyLayout runs). This cannot loop: it sets layer flags
// and view positions only, never constraints or setNeedsLayout.
static void MultitaskFloatViewDidLayoutSubviews(id self, SEL _cmd) {
    if (origViewDidLayoutSubviews) origViewDidLayoutSubviews(self, _cmd);
    MultitaskFloatSyncWindowChrome((DecoratedAppSceneViewController *)self);
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
        // v30: during the open pop the view carries a scale transform,
        // so convertRect below would return a transformed origin and
        // commit a wrong top inset (top blocked / bottom cut until a
        // later recompute fixes it — the current symptom). Skip while
        // the pop is running; the pop-completion and 0.5s recomputes
        // set it with an identity transform.
        if (!CGAffineTransformIsIdentity(vc.view.transform)) return;
        UIWindow *w = vc.view.window;
        BOOL portrait = YES;
        if (w.windowScene) portrait = UIInterfaceOrientationIsPortrait(w.windowScene.interfaceOrientation);
        if (!portrait) return;
        // Timing-independent (see the swizzle): use the window's top
        // safe-area inset, not the view's current frame origin.
        // Take the max of both so a 0 from either source cannot
        // zero the compensation.
        CGFloat frameOff = [vc.view convertRect:vc.view.bounds toView:w].origin.y;
        CGFloat off = fmax(w.safeAreaInsets.top, frameOff);
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
        // Timing-independent: the decorated view's final origin.y in
        // the window equals the window's top safe-area inset (the host
        // sets maxFrame by insetting the window frame by it), but the
        // view's current frame may not be final yet when this runs
        // (setup/activation), which used to yield off = 0. The window
        // safe area is final from window creation. Take the max of
        // both so a 0 from either source cannot zero the value.
        // Use max (not +=): when the nav bar is hidden the original
        // already supplies the full top inset, and adding again
        // would double it.
        CGFloat frameOff = [vc.view convertRect:vc.view.bounds toView:w].origin.y;
        CGFloat off = fmax(w.safeAreaInsets.top, frameOff);
        if (portrait && off > 0) {
            CGFloat scale = 1.0;
            @try {
                NSNumber *n = [vc valueForKey:@"scaleRatio"];
                double v = [n doubleValue];
                if (v > 0) scale = (CGFloat)v;
            } @catch (id e) {}
            CGFloat add = off / scale;
            UIEdgeInsets p = settings.peripheryInsets;
            p.top = fmax(p.top, add);
            settings.peripheryInsets = p;
            UIEdgeInsets pa = settings.safeAreaInsetsPortrait;
            pa.top = fmax(pa.top, add);
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
    Method mMax = class_getInstanceMethod(cls, @selector(maximizeWindow));
    if (mMax) {
        origMaximizeWindow = (VoidIMP)method_getImplementation(mMax);
        method_setImplementation(mMax, (IMP)MultitaskFloatMaximizeWindow);
    }
    Method mMin = class_getInstanceMethod(cls, @selector(minimizeWindow));
    if (mMin) {
        origMinimizeWindow = (VoidIMP)method_getImplementation(mMin);
        method_setImplementation(mMin, (IMP)MultitaskFloatMinimizeWindow);
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
    // viewDidLayoutSubviews: same pattern; the class does not define
    // it, so adding an override is safe.
    Method mLayoutSubviews = class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews));
    if (mLayoutSubviews) {
        origViewDidLayoutSubviews = (VoidIMP)method_getImplementation(mLayoutSubviews);
        if (!class_addMethod(cls, @selector(viewDidLayoutSubviews), (IMP)MultitaskFloatViewDidLayoutSubviews, method_getTypeEncoding(mLayoutSubviews))) {
            method_setImplementation(mLayoutSubviews, (IMP)MultitaskFloatViewDidLayoutSubviews);
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
    // Last-tap capture for the icon-origin open animation: UIWindow
    // implements sendEvent:, so swap its implementation (orig first,
    // then record). Pure runtime, no UIKit work in the constructor.
    Class windowCls = objc_getClass("UIWindow");
    if (windowCls) {
        Method mSend = class_getInstanceMethod(windowCls, @selector(sendEvent:));
        if (mSend) {
            origSendEvent = (SendEventIMP)method_getImplementation(mSend);
            method_setImplementation(mSend, (IMP)MultitaskFloatSendEvent);
        }
    }
}
