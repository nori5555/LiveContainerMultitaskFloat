#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>  // v38: glyph paths for the handwriting animation
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
static const char kMultitaskFloatPinnedKey = 0;

// Pinned windows (v40): weak refs, so a closed window drops out on
// its own — no dangling pointers, no retain cycles. Created lazily
// on the first pin (never in the constructor).
static NSHashTable *MultitaskFloatPinnedWindows = nil;

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
// v40: pin support. The capsule color shows the pin state (gray =
// normal, blue = pinned), synced on every layout pass so it
// survives restores and appearance changes, not just the tap.
static void MultitaskFloatSyncPinCapsule(DecoratedAppSceneViewController *vc) {
    UIView *dragBar = objc_getAssociatedObject(vc, &kMultitaskFloatDragBarKey);
    if (!dragBar || dragBar.subviews.count == 0) return;
    UIView *capsule = dragBar.subviews[0];
    BOOL pinned = [objc_getAssociatedObject(vc, &kMultitaskFloatPinnedKey) boolValue];
    capsule.backgroundColor = pinned ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.9] : [[UIColor systemGrayColor] colorWithAlphaComponent:0.65];
}

// v40: re-assert every pinned window above all other windows.
// Idempotent and layout-safe: bringSubviewToFront triggers neither
// layout nor appear, so calling it from layout/appear/drag paths
// cannot loop.
static void MultitaskFloatBringPinnedToFront(void) {
    if (!MultitaskFloatPinnedWindows) return;
    for (DecoratedAppSceneViewController *pinnedVC in MultitaskFloatPinnedWindows) {
        if (pinnedVC.view && pinnedVC.view.superview) {
            [pinnedVC.view.superview bringSubviewToFront:pinnedVC.view];
        }
    }
}

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
        // v40: double-tap the drag bar to pin/unpin (window mode
        // only — the bar is hidden when maximized, so a hidden bar
        // never receives the tap). Added once, at creation, so no
        // duplicate recognizers on later layout passes. Pan and
        // double-tap coexist without require-to-fail: a tap has no
        // movement (pan never begins), a drag has movement (tap
        // never fires), and require-to-fail would have delayed
        // dragging.
        UITapGestureRecognizer *pinTap = [[UITapGestureRecognizer alloc] initWithTarget:vc action:@selector(MultitaskFloatTogglePin:)];
        pinTap.numberOfTapsRequired = 2;
        pinTap.numberOfTouchesRequired = 1;
        [container addGestureRecognizer:pinTap];
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
    // v40: capsule color follows the pin state on every layout.
    MultitaskFloatSyncPinCapsule(vc);
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
    // v40: pinned windows stay on top: any layout pass (maximize,
    // restore, resize) can reorder windows, so re-assert pinned
    // windows above all others here. Idempotent, no layout loop
    // (bringSubviewToFront triggers neither layout nor appear).
    MultitaskFloatBringPinnedToFront();
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
            // v40: re-assert pinned on top once the toggle animation
            // has settled (the host can reorder windows mid-animation).
            MultitaskFloatBringPinnedToFront();
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
            // v40: re-assert pinned on top once the toggle animation
            // has settled (the host can reorder windows mid-animation).
            MultitaskFloatBringPinnedToFront();
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
    // v39: filled-stroke reveal (the user corrected v38:
    // "only a thin white line follows the stroke, I want
    // the strokes themselves to present slowly"). v38 stroked
    // the glyph outline with a 2pt line, so you only saw a
    // thin trace, never the ink. v39 fills each glyph (the
    // actual calligraphic ink shape, from CoreText, same
    // Snell Roundhand / fallback chain) and reveals it
    // progressively left to right inside a clipping view,
    // glyph by glyph — so the stroke itself grows, not just
    // its outline. In the superview above vc.view, so it
    // masks the guest content pop-in like the earlier layers
    // did. Day -> black ink, night -> white ink (foreground
    // contrast, like the pill border). The container fades
    // out and is removed after the writing finishes, so it
    // can never outlive the animation even if the window
    // closes mid-flight.
    UIView *nameContainer = nil;
    NSMutableArray *nameClips = nil;
    NSMutableArray *nameClipWidths = nil;
    if (vc.isMaximized && vc.view.superview) {
        UIFont *nameFont = [UIFont fontWithName:@"Snell Roundhand" size:34];
        if (!nameFont) nameFont = [UIFont fontWithName:@"Bradley Hand" size:34];
        if (!nameFont) nameFont = [UIFont fontWithName:@"Marker Felt" size:34];
        if (!nameFont) nameFont = [UIFont italicSystemFontOfSize:34];
        NSString *pluginName = @"MultitaskFloat";
        UIColor *nameColor = (vc.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? [UIColor whiteColor] : [UIColor blackColor];
        CTFontRef ctFont = CTFontCreateWithName((CFStringRef)nameFont.fontName, 34, NULL);
        if (ctFont) {
            CGFloat ascent = CTFontGetAscent(ctFont);
            CGFloat descent = CTFontGetDescent(ctFont);
            CGFloat containerHeight = ascent + descent;
            CGFloat totalWidth = 0;
            for (NSUInteger i = 0; i < pluginName.length; i++) {
                UniChar ch = (UniChar)[pluginName characterAtIndex:i];
                CGGlyph glyph = 0;
                if (CTFontGetGlyphsForCharacters(ctFont, &ch, &glyph, 1)) {
                    CGSize advance = CGSizeZero;
                    CTFontGetAdvancesForGlyphs(ctFont, kCTFontOrientationHorizontal, &glyph, &advance, 1);
                    totalWidth += advance.width;
                }
            }
            nameContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, totalWidth, containerHeight)];
            nameContainer.backgroundColor = [UIColor clearColor];
            nameContainer.userInteractionEnabled = NO;
            nameContainer.center = CGPointMake(CGRectGetMidX(vc.view.superview.bounds), CGRectGetMidY(vc.view.superview.bounds));
            nameContainer.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            nameClips = [NSMutableArray array];
            nameClipWidths = [NSMutableArray array];
            CGFloat runningX = 0;
            for (NSUInteger i = 0; i < pluginName.length; i++) {
                UniChar ch = (UniChar)[pluginName characterAtIndex:i];
                CGGlyph glyph = 0;
                CGSize advance = CGSizeZero;
                if (CTFontGetGlyphsForCharacters(ctFont, &ch, &glyph, 1)) {
                    CTFontGetAdvancesForGlyphs(ctFont, kCTFontOrientationHorizontal, &glyph, &advance, 1);
                    CGPathRef glyphPath = CTFontCreatePathForGlyph(ctFont, glyph, NULL);
                    if (glyphPath) {
                        // Clip view starts at width 0 and widens to
                        // the full glyph width, revealing the filled
                        // ink left to right. A 2pt margin each side
                        // keeps script overhang from being cut off.
                        CGFloat clipX = runningX - 2;
                        CGFloat clipWidth = advance.width + 4;
                        UIView *clipView = [[UIView alloc] initWithFrame:CGRectMake(clipX, 0, 0, containerHeight)];
                        clipView.backgroundColor = [UIColor clearColor];
                        clipView.userInteractionEnabled = NO;
                        clipView.clipsToBounds = YES;
                        CGAffineTransform glyphTransform = CGAffineTransformMake(1, 0, 0, -1, 2, ascent);
                        CGPathRef transformedPath = CGPathCreateCopyByTransformingPath(glyphPath, &glyphTransform);
                        if (transformedPath) {
                            CAShapeLayer *inkLayer = [CAShapeLayer layer];
                            inkLayer.frame = CGRectMake(0, 0, clipWidth, containerHeight);
                            inkLayer.path = transformedPath;
                            inkLayer.fillColor = nameColor.CGColor;
                            inkLayer.strokeColor = [UIColor clearColor].CGColor;
                            [clipView.layer addSublayer:inkLayer];
                            CGPathRelease(transformedPath);
                        }
                        CGPathRelease(glyphPath);
                        [nameContainer addSubview:clipView];
                        [nameClips addObject:clipView];
                        [nameClipWidths addObject:@(clipWidth)];
                    }
                }
                runningX += advance.width;
            }
            CFRelease(ctFont);
            [vc.view.superview addSubview:nameContainer];
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
    // v39: filled-stroke reveal: each glyph's filled ink
    // widens left to right over 0.22s (the clip view's width
    // grows from 0 to the full glyph width), staggered
    // 0.12s apart, left to right (14 glyphs -> last one
    // finishes at ~1.78s), concurrent with the pop. Then
    // the whole container fades out over 0.15s and is
    // removed (~1.9s total), so the strokes present slowly
    // and linger a bit after the pop settles.
    if (nameContainer) {
        for (NSUInteger i = 0; i < nameClips.count; i++) {
            UIView *clipView = nameClips[i];
            CGFloat targetWidth = [nameClipWidths[i] floatValue];
            CGRect clipFrame = clipView.frame;
            [UIView animateWithDuration:0.22 delay:(i * 0.12) options:UIViewAnimationOptionCurveEaseOut animations:^{
                clipView.frame = CGRectMake(clipFrame.origin.x, clipFrame.origin.y, targetWidth, clipFrame.size.height);
            } completion:nil];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.78 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                nameContainer.alpha = 0;
            } completion:^(BOOL nameFinished) {
                (void)nameFinished;
                [nameContainer removeFromSuperview];
            }];
        });
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
        // v40: re-assert pinned on top once layout has settled
        // after appear (a new window's appear can bury pinned).
        MultitaskFloatBringPinnedToFront();
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
    // v40: dragging any window can reorder windows, so re-assert
    // pinned windows on top after the move (idempotent).
    MultitaskFloatBringPinnedToFront();
}

// v40: double-tap the drag bar to pin/unpin. Pinning registers the
// window in the weak pinned set and brings it to front at once;
// unpinning deregisters it and leaves the order as is. The pin
// persists across maximize/restore (the flag lives on the VC, and
// the drag bar — hence the tap target — reappears in window mode);
// closing the window drops it from the weak set automatically.
// Capsule color updates at once (and again on every layout via
// SyncWindowChrome).
static void MultitaskFloatTogglePin(id self, SEL _cmd, UITapGestureRecognizer *sender) {
    (void)sender;
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    if (vc.isMaximized) return;
    BOOL pinned = [objc_getAssociatedObject(vc, &kMultitaskFloatPinnedKey) boolValue];
    pinned = !pinned;
    objc_setAssociatedObject(vc, &kMultitaskFloatPinnedKey, @(pinned), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (pinned) {
        if (!MultitaskFloatPinnedWindows) MultitaskFloatPinnedWindows = [NSHashTable weakObjectsHashTable];
        [MultitaskFloatPinnedWindows addObject:vc];
        MultitaskFloatBringPinnedToFront();
    } else {
        [MultitaskFloatPinnedWindows removeObject:vc];
    }
    MultitaskFloatSyncPinCapsule(vc);
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
    // v40: pin toggle is a new selector too, so adding it is safe.
    class_addMethod(cls, @selector(MultitaskFloatTogglePin:), (IMP)MultitaskFloatTogglePin, "v@:@");
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
