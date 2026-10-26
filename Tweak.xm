#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>  // v38: glyph paths for the handwriting animation
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <stdlib.h>

// v76: the open animation is pure ObjC UIKit again (classic
// animateWithDuration drivers, no Swift file). The v69–v75 Swift
// experiment is fully reverted: OpenAnimation.swift is deleted and
// the Makefile no longer lists SWIFT_FILES.

// v77: docked window runs to the right edge, untappable (user
// 2026-10-27 03:58 screenshot). Repro: double-tap the drag bar to
// pin, tap yellow minimize to dock to the left edge, then open
// another app — the docked window ends up as a sliver on the right
// edge with no left tab to restore it. Root cause, reviewed in
// code: the dock state was not owned by anyone once another app
// opened. The host re-parents / re-appears windows when a new app
// opens, and three of our own handlers then undid the dock: (1)
// viewDidAppear's v66 block dropped the dock state and reset the
// view to identity/visible, then AnimateOpen popped it at whatever
// frame the host had moved it to (its right-edge minimized slot);
// (2) viewDidDisappear dropped the tab + docked flag and reset the
// view to identity/visible; (3) a host minimize/maximize on the
// docked window moved it outright. Fix, defense in depth: the dock
// is now re-asserted (view hidden + slid left, tab window back at
// the left edge) whenever any window appears, lays out, or the
// watchdog ticks; appear/disappear never clear dock state while
// docked (disappear only drops the tab 10s later if the view is
// truly detached with no window and no superview); host
// minimize/maximize on a docked window is ignored; the frame the
// window had when it docked is saved and restored on restore, so
// a host-moved frame can never strand it; and SyncWindowChrome
// pulls any non-docked window whose frame is mostly off-screen
// back on-screen, so an already-stranded window recovers on the
// next layout/watchdog tick instead of staying stuck at the edge.

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
static ViewDidAppearIMP origViewDidDisappear = NULL;
static VoidIMP origViewDidLayoutSubviews = NULL;
static GestureShouldBeginIMP origGestureShouldBegin = NULL;
static BOOL dockSwizzled = NO;

// v42: App list banner hooks (see below, before the constructor).
typedef void (*BannerDoubleTappedIMP)(id, SEL, UITapGestureRecognizer *);
static VoidIMP origBannerViewDidLoad = NULL;
static BannerDoubleTappedIMP origBannerDoubleTapped = NULL;
static VoidIMP origBannerViewDidLayoutSubviews = NULL;

// Floating pill (v10): the three buttons detached from the nav bar so
// the user can drag them anywhere like AssistiveTouch instead of
// having them block the app's own controls. Stored on the VC.
static const char kMultitaskFloatPillKey = 0;
static const char kMultitaskFloatPillPlacedKey = 0;
static const char kMultitaskFloatDragBarKey = 0;
static const char kMultitaskFloatAnimatingOpenKey = 0;
static const char kMultitaskFloatAnimatingOpenStartKey = 0; // v71: pop start time, for stale-flag detection
static const char kMultitaskFloatPinnedKey = 0;
static const char kMultitaskFloatDotKey = 0;
static const char kMultitaskFloatDotTapTimeKey = 0;
static const char kMultitaskFloatDisplayLinkKey = 0;
static const char kMultitaskFloatDisplayLinkStartKey = 0;
static const char kMultitaskFloatMaskBoundsKey = 0;
static const char kMultitaskFloatMaskRadiusKey = 0;
static const char kMultitaskFloatPillBorderDarkKey = 0;
static const char kMultitaskFloatPinCapsulePinnedKey = 0;
static const char kMultitaskFloatToggleTimeKey = 0;
static const char kMultitaskFloatClosingKey = 0;
static const char kMultitaskFloatDockedKey = 0;
static const char kMultitaskFloatDockTabKey = 0;
static const char kMultitaskFloatDockWindowKey = 0; // v61: separate window so the tab stays above any app
static const char kMultitaskFloatDockAnimatingKey = 0; // v66: dock/restore animation in flight
static const char kMultitaskFloatDockAnimatingStartKey = 0; // v77: dock/restore animation start time, for stale-flag detection
static const char kMultitaskFloatDockSavedFrameKey = 0; // v77: the window frame at dock time, restored on restore
static const char kMultitaskFloatWatchdogKey = 0; // v71: permanent chrome watchdog running

// Pinned windows (v40): weak refs, so a closed window drops out on
// its own — no dangling pointers, no retain cycles. Created lazily
// on the first pin (never in the constructor).
static NSHashTable *MultitaskFloatPinnedWindows = nil;

// Docked window (v63): only ONE window may be docked at a time. A
// single weak ref (not a set) — it zeroes out on its own if the
// window goes away without cleanup, and it is cleared explicitly on
// restore/close. v77: disappear does NOT clear it while docked (the
// dock must survive the host re-parenting windows when another app
// opens); a truly detached docked window loses its tab 10s later
// via the delayed check in viewDidDisappear. Set on dock, checked
// before docking another window (prompt + refuse if one is already
// docked).
static __weak DecoratedAppSceneViewController *MultitaskFloatDockedVC = nil;

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

// v62: setter swizzle — force isCollapsed to YES so the dock can
// never come back, no matter which path asks to show it (showDock,
// toggle, or a direct setIsCollapsed:NO from the host when a window
// is hidden/docked). The dock is meant to stay gone (v14 spec), so
// blocking show is correct, not just hiding at startup.
typedef void (*MultitaskFloatSetCollapsedIMP)(id, SEL, BOOL);
static MultitaskFloatSetCollapsedIMP origSetIsCollapsed = NULL;
static void MultitaskFloatSetIsCollapsed(id self, SEL _cmd, BOOL collapsed) {
    (void)collapsed; // ignore the request; dock stays collapsed (hidden)
    if (origSetIsCollapsed) origSetIsCollapsed(self, _cmd, YES);
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
    // v62: also force the collapsed setter to YES, so a direct
    // setIsCollapsed:NO (e.g. host showing the dock when a window
    // is hidden/docked) cannot bring the dock back. The show-method
    // redirects above do not catch a direct setter call.
    Method mSetCollapsed = class_getInstanceMethod(cls, @selector(setIsCollapsed:));
    if (mSetCollapsed) {
        origSetIsCollapsed = (MultitaskFloatSetCollapsedIMP)method_getImplementation(mSetCollapsed);
        method_setImplementation(mSetCollapsed, (IMP)MultitaskFloatSetIsCollapsed);
    }
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
    // v52 power: border color is a pure function of dark, so skip
    // rebuilding it every frame/layout when appearance is unchanged
    // (the NULL check covers an externally cleared border).
    NSNumber *cachedDark = objc_getAssociatedObject(pill, &kMultitaskFloatPillBorderDarkKey);
    if (cachedDark && [cachedDark boolValue] == dark && pill.layer.borderColor != NULL) return;
    UIColor *c = dark ? [[UIColor whiteColor] colorWithAlphaComponent:0.6] : [[UIColor blackColor] colorWithAlphaComponent:0.6];
    pill.layer.borderColor = c.CGColor;
    objc_setAssociatedObject(pill, &kMultitaskFloatPillBorderDarkKey, @(dark), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// v60: edge-dock helpers, defined after TogglePin (they call Sync
// and StartDisplayLink, which are defined later); PillButton (here)
// calls DockToEdge, so declare them first (v53 lesson: use before
// declare fails the build).
static void MultitaskFloatDockToEdge(DecoratedAppSceneViewController *vc);
static void MultitaskFloatRestoreFromEdge(DecoratedAppSceneViewController *vc);
// v77: re-assert a docked window (view hidden + slid left, tab back
// at the left edge). Defined with the dock helpers below; called
// from BringPinnedToFront, viewDidAppear and the watchdog, so it is
// declared here too.
static void MultitaskFloatReassertDock(DecoratedAppSceneViewController *vc);

static void MultitaskFloatPillButton(id self, SEL _cmd, UIButton *sender) {
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    // v66: ignore pill taps while a dock/restore animation is in
    // flight (0.25s) — a second tap in that window used to call
    // minimizeWindow against a sliding, fading window, and the
    // host move + our transform fought to a side position.
    if ([objc_getAssociatedObject(vc, &kMultitaskFloatDockAnimatingKey) boolValue]) return;
    if (sender.tag == 0) {
        // v60: pinned + yellow minimize docks to the edge instead of
        // minimizing normally — a blue drag bar means pinned; tapping
        // yellow then leaves only a small blue bar at the screen edge,
        // and tapping that bar restores the window. Unpinned, closing,
        // or already docked keeps the old minimize path.
        BOOL pinned = [objc_getAssociatedObject(vc, &kMultitaskFloatPinnedKey) boolValue];
        BOOL closing = [objc_getAssociatedObject(vc, &kMultitaskFloatClosingKey) boolValue];
        BOOL docked = [objc_getAssociatedObject(vc, &kMultitaskFloatDockedKey) boolValue];
        if (pinned && !closing && !docked) {
            MultitaskFloatDockToEdge(vc);
        } else {
            [vc minimizeWindow];
        }
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
// v45: drag bar moved to just outside the window top (superview,
// capsule 3–9pt above the edge) for reliable grabbing; scene view
// gets its own corner clip so small windows stay rounded even if
// the host resets the decorated view's masks.
// v40: pin support. The capsule color shows the pin state (gray =
// normal, blue = pinned), synced on every layout pass so it
// survives restores and appearance changes, not just the tap.
static void MultitaskFloatSyncPinCapsule(DecoratedAppSceneViewController *vc) {
    UIView *dragBar = objc_getAssociatedObject(vc, &kMultitaskFloatDragBarKey);
    if (!dragBar || dragBar.subviews.count == 0) return;
    UIView *capsule = dragBar.subviews[0];
    BOOL pinned = [objc_getAssociatedObject(vc, &kMultitaskFloatPinnedKey) boolValue];
    // v52 power: capsule color is a pure function of pinned, so skip
    // rebuilding it every frame/layout when pin state is unchanged
    // (the nil check covers an externally cleared color).
    NSNumber *cachedPinned = objc_getAssociatedObject(capsule, &kMultitaskFloatPinCapsulePinnedKey);
    if (cachedPinned && [cachedPinned boolValue] == pinned && capsule.backgroundColor != nil) return;
    capsule.backgroundColor = pinned ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.9] : [[UIColor systemGrayColor] colorWithAlphaComponent:0.65];
    objc_setAssociatedObject(capsule, &kMultitaskFloatPinCapsulePinnedKey, @(pinned), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// v40: re-assert every pinned window above all other windows.
// Idempotent and layout-safe: bringSubviewToFront triggers neither
// layout nor appear, so calling it from layout/appear/drag paths
// cannot loop.
static void MultitaskFloatBringPinnedToFront(void) {
    if (!MultitaskFloatPinnedWindows) return;
    for (DecoratedAppSceneViewController *pinnedVC in MultitaskFloatPinnedWindows) {
        // v60: skip edge-docked windows — the window is hidden and
        // its edge tab is the visible UI; bringing a hidden window
        // forward is pointless and could reorder its tab.
        // v77: instead, re-assert the dock — any layout pass (a new
        // app opening re-parents windows) is exactly when the host
        // may have moved the docked window or its tab, so this is
        // the moment to put both back at the left edge.
        if ([objc_getAssociatedObject(pinnedVC, &kMultitaskFloatDockedKey) boolValue]) {
            MultitaskFloatReassertDock(pinnedVC);
            continue;
        }
        if (pinnedVC.view && pinnedVC.view.superview) {
            [pinnedVC.view.superview bringSubviewToFront:pinnedVC.view];
            // v45: bringing the window forward puts it above its
            // superview drag bar; put the bar back immediately above
            // its window so the full hit area (not just the part
            // protruding past the top edge) stays grabbable.
            UIView *dragBar = objc_getAssociatedObject(pinnedVC, &kMultitaskFloatDragBarKey);
            if (dragBar && dragBar.superview == pinnedVC.view.superview && !pinnedVC.isMaximized) {
                [pinnedVC.view.superview insertSubview:dragBar aboveSubview:pinnedVC.view];
            }
        }
    }
}

// v46: rounded-rect layer mask, independent of cornerRadius/
// masksToBounds. Instagram and Xiaohongshu still show square
// corners on v45 (confirmed installed): the host must be resetting
// the decorated view's AND the scene view's clipping without a
// layout pass (media-heavy apps reconfigure their scene on
// activation/video/rotation), so a layout-triggered re-sync never
// runs. layer.mask is a separate property the host never touches
// in setup/maximize/minimize, so it keeps clipping to the rounded
// rect between syncs. Guarded to non-empty bounds: a mask built
// from a zero rect would clip the view to nothing (invisible).
static void MultitaskFloatApplyCornerMask(UIView *view, CGFloat radius) {
    if (!view) return;
    // v52 power: the mask is a pure function of (bounds, radius),
    // and the host never touches layer.mask (v46 comment), so when
    // both are unchanged the existing mask is already correct —
    // skip rebuilding a new layer + path + render commit every
    // frame/layout. The mask-presence check covers an externally
    // cleared mask (rebuild next call, same as before).
    BOOL wantMask = (radius > 0 && CGRectGetWidth(view.bounds) > 0 && CGRectGetHeight(view.bounds) > 0);
    NSValue *cachedBounds = objc_getAssociatedObject(view, &kMultitaskFloatMaskBoundsKey);
    NSNumber *cachedRadius = objc_getAssociatedObject(view, &kMultitaskFloatMaskRadiusKey);
    // v71: also require the existing mask to be OUR shape layer — the
    // old check only verified a mask exists, so a mask the host put
    // there (e.g. its own square clip) defeated the rebuild forever.
    if (cachedBounds && cachedRadius && CGRectEqualToRect([cachedBounds CGRectValue], view.bounds) && [cachedRadius doubleValue] == radius && ((wantMask && [view.layer.mask isKindOfClass:[CAShapeLayer class]]) || (!wantMask && view.layer.mask == nil))) return;
    if (!wantMask) {
        view.layer.mask = nil;
    } else {
        // v57 perf: reuse the existing mask layer (update frame/path
        // in place) instead of allocating a new layer every frame
        // during animations — a new layer each frame churns the
        // render tree and costs CPU (heat) for no visual difference.
        CAShapeLayer *mask = (CAShapeLayer *)view.layer.mask;
        if (![mask isKindOfClass:[CAShapeLayer class]]) {
            mask = [CAShapeLayer layer];
            view.layer.mask = mask;
        }
        mask.frame = view.bounds;
        mask.path = [UIBezierPath bezierPathWithRoundedRect:view.bounds cornerRadius:radius].CGPath;
    }
    objc_setAssociatedObject(view, &kMultitaskFloatMaskBoundsKey, [NSValue valueWithCGRect:view.bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kMultitaskFloatMaskRadiusKey, @(radius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void MultitaskFloatSyncWindowChrome(DecoratedAppSceneViewController *vc) {
    if (!vc.view) return;
    // v57: skip all chrome sync during the close animation — the
    // window is fading out, and any repositioning (drag bar) or mask
    // rebuild would fight the fade.
    if ([objc_getAssociatedObject(vc, &kMultitaskFloatClosingKey) boolValue]) return;
    // v60: skip all chrome sync while edge-docked — the window is
    // hidden and the edge tab is the visible UI; syncing a hidden
    // window's chrome is wasted and could reposition its hidden
    // drag bar.
    if ([objc_getAssociatedObject(vc, &kMultitaskFloatDockedKey) boolValue]) return;
    // During the open animation (v29) the window's corners are part
    // of the pop (rounded while it scales in); layout passes during
    // the animation must not reset masks/cornerRadius, or the pop
    // would lose its rounded clip mid-flight (maximized clears
    // clipping outright). The drag bar and pill border below still
    // sync. The animation's completion re-syncs chrome itself.
    // v71: stale-flag guard. The pop is ~0.6s; if the flag is still
    // set 2s after the pop started, its completion never ran (the
    // v69 animator bug, or any future lost completion) — clear it
    // here, or the window stays square and barless forever: the
    // mask section below is skipped while the flag is set, and the
    // drag bar stays hidden.
    BOOL animatingOpen = [objc_getAssociatedObject(vc, &kMultitaskFloatAnimatingOpenKey) boolValue];
    if (animatingOpen) {
        NSNumber *animStart = objc_getAssociatedObject(vc, &kMultitaskFloatAnimatingOpenStartKey);
        if (animStart && ([[NSDate date] timeIntervalSince1970] - [animStart doubleValue] > 2.0)) {
            objc_setAssociatedObject(vc, &kMultitaskFloatAnimatingOpenKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(vc, &kMultitaskFloatAnimatingOpenStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            animatingOpen = NO;
        }
    }
    // v77: stranded-window safety net. A non-docked window whose
    // model frame is mostly off-screen (less than 100pt visible on
    // either side — e.g. the host moved a docked window to its
    // right-edge slot and the dock state was lost) can never be
    // grabbed or tapped. Pull it back on-screen, centered. Docked
    // windows never reach here (early return above), and docking
    // moves the window with a transform, not the frame, so this
    // cannot fight a dock. Skipped while animating / toggling /
    // closing or with a non-identity transform, so no animation is
    // ever interrupted mid-flight.
    if (vc.view.window && CGAffineTransformIsIdentity(vc.view.transform) && !animatingOpen && ![objc_getAssociatedObject(vc, &kMultitaskFloatClosingKey) boolValue]) {
        NSNumber *toggleTimeForClamp = objc_getAssociatedObject(vc, &kMultitaskFloatToggleTimeKey);
        BOOL inToggleForClamp = toggleTimeForClamp && ([[NSDate date] timeIntervalSince1970] - [toggleTimeForClamp doubleValue] < 0.4);
        if (!inToggleForClamp) {
            CGSize screenSizeForClamp = vc.view.window.bounds.size;
            CGRect frameForClamp = vc.view.frame;
            if (frameForClamp.size.width > 0 && frameForClamp.size.height > 0 && (frameForClamp.origin.x > screenSizeForClamp.width - 100 || frameForClamp.origin.x + frameForClamp.size.width < 100)) {
                CGFloat clampedW = fmin(frameForClamp.size.width, screenSizeForClamp.width);
                CGFloat clampedH = fmin(frameForClamp.size.height, screenSizeForClamp.height);
                CGFloat clampedY = frameForClamp.origin.y;
                if (clampedY < 0) clampedY = 0;
                if (clampedY + clampedH > screenSizeForClamp.height) clampedY = fmax(0, screenSizeForClamp.height - clampedH);
                vc.view.frame = CGRectMake((screenSizeForClamp.width - clampedW) / 2, clampedY, clampedW, clampedH);
            }
        }
    }
    // v58: force rounded chrome during ANY toggle animation
    // (maximize and minimize/restore). The toggle animates over
    // ~0.3s and isMaximized can stay stale through it, so a plain
    // isMaximized check snaps corners at toggle start (maximize:
    // small window snaps square before growing) or at landing
    // (minimize: square until landing — the v56 flash). During
    // 0.4s after any toggle, treat the window as not-maximized
    // (rounded) regardless of the flag; after the window, trust
    // the host flag (which has caught up by then). The timestamp
    // expires on its own — no flag to clear, no lingering state
    // (supersedes v56's forceSmall flag, which would have kept a
    // maximized window rounded if it lingered).
    NSNumber *toggleTime = objc_getAssociatedObject(vc, &kMultitaskFloatToggleTimeKey);
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL inToggle = toggleTime && (now - [toggleTime doubleValue] < 0.4);
    BOOL effectiveMaximized = inToggle ? NO : vc.isMaximized;
    if (!animatingOpen) {
        // v57 perf: only write layer properties when they actually
        // change — setting the same cornerRadius/masksToBounds every
        // frame still costs a render commit each time.
        if (effectiveMaximized) {
            if (vc.view.layer.masksToBounds) vc.view.layer.masksToBounds = NO;
        } else {
            CGFloat deviceRadius = MultitaskFloatDeviceCornerRadius();
            if (vc.view.layer.cornerRadius != deviceRadius) vc.view.layer.cornerRadius = deviceRadius;
            if (!vc.view.layer.masksToBounds) vc.view.layer.masksToBounds = YES;
        }
        // v45: also clip the scene view itself (defense-in-depth for
        // rounded corners). Some apps end up square in small-window
        // mode because the host resets the decorated view's masks
        // after our sync; the host never touches the scene view, so
        // its own rounding still clips the app content to the window
        // shape. Maximized clears both (full-screen, square).
        UIView *sceneView = vc.appSceneVC.view;
        if (sceneView) {
            if (effectiveMaximized) {
                if (sceneView.layer.cornerRadius != 0) sceneView.layer.cornerRadius = 0;
                if (sceneView.layer.masksToBounds) sceneView.layer.masksToBounds = NO;
            } else {
                CGFloat sceneRadius = MultitaskFloatDeviceCornerRadius();
                if (sceneView.layer.cornerRadius != sceneRadius) sceneView.layer.cornerRadius = sceneRadius;
                if (!sceneView.layer.masksToBounds) sceneView.layer.masksToBounds = YES;
            }
        }
        // v46: layer mask on both views (see helper). Maximized
        // clears it (square full-screen); small-window sets it to
        // the device radius. Left untouched while animatingOpen
        // (the pop animates cornerRadius itself; a rounded mask
        // would freeze it rounded and snap square at completion).
        // v59: during a toggle animation, clear the mask outright —
        // the mask is built from MODEL bounds (already final), while
        // the window's PRESENTATION is still animating, so a
        // model-sized mask clips the animating window to the wrong
        // size (large→small looks smeared/cut, list bleeds through
        // the window interior). cornerRadius+masksToBounds (above)
        // track the presentation, so they alone clip correctly
        // during the animation; the mask is rebuilt from final
        // bounds once settled (its presence check forces a rebuild
        // after a clear).
        if (inToggle) {
            vc.view.layer.mask = nil;
            if (sceneView) sceneView.layer.mask = nil;
        } else if (effectiveMaximized) {
            MultitaskFloatApplyCornerMask(vc.view, 0);
            MultitaskFloatApplyCornerMask(sceneView, 0);
        } else {
            CGFloat deviceRadius = MultitaskFloatDeviceCornerRadius();
            MultitaskFloatApplyCornerMask(vc.view, deviceRadius);
            MultitaskFloatApplyCornerMask(sceneView, deviceRadius);
        }
    }
    UIView *dragBar = objc_getAssociatedObject(vc, &kMultitaskFloatDragBarKey);
    if (!dragBar) {
        // v41: enlarged hit area (160x44, meets the 44pt minimum tap
        // target height; was 88x30, too hard to hit). The visible
        // capsule stays 48x6, recentered in the bigger container, so
        // the look is unchanged — only the invisible tap area grows.
        // Both the drag pan and the double-tap pin live on this
        // container, so one change eases both. Width stays moderate
        // (not full-width) and centered, so the app's top-left/right
        // buttons stay tappable; top-center is usually just a title.
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 160, 44)];
        container.backgroundColor = [UIColor clearColor];
        UIView *capsule = [[UIView alloc] initWithFrame:CGRectMake(56, 19, 48, 6)];
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
        // v45: the drag bar lives in the window's superview, not in
        // the window itself (see positioning below) — it must be
        // able to sit above the window's top edge, which the
        // window's own masksToBounds would clip.
        UIView *parent = vc.view.superview ? vc.view.superview : vc.view;
        [parent addSubview:container];
        objc_setAssociatedObject(vc, &kMultitaskFloatDragBarKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dragBar = container;
    }
    // v45: hide the bar during the open pop as well — it no longer
    // scales with the window (it lives in the superview), so showing
    // it mid-pop would leave it floating at the final position while
    // the window is still small; the pop completion re-syncs and it
    // appears in place.
    // v47: also hide when the window is gone or hidden (closed /
    // minimized) so a superview bar never floats over the list.
    dragBar.hidden = effectiveMaximized || animatingOpen || !vc.view.window || vc.view.hidden;
    if (!effectiveMaximized) {
        // v45: drag bar sits just outside the window's top edge
        // (capsule 3–9pt above it) so it is always grabbable and the
        // app's own top controls can never intercept the drag — the
        // old inside position sometimes failed to drag when the app's
        // header covered it. It lives in the superview (the window's
        // own masksToBounds would clip a protruding subview), placed
        // immediately above the window so higher windows still win
        // touches over it, and clamped so it never leaves the top of
        // the screen when the window itself is near the top. The
        // container straddles the edge (28pt above, 16pt inside), so
        // the handle reads as attached, not floating away. It sits
        // above the whole window subtree, so on the rare overlap with
        // the floating pill the handle wins — acceptable, the pill is
        // almost never parked exactly at top-center.
        UIView *parent = vc.view.superview;
        if (parent) {
            // v58: during a toggle animation, the model frame is
            // already final while the presentation is still
            // animating — position the bar from the presentation
            // frame so it stays glued to the moving window top
            // instead of jumping to the final top at toggle start.
            CGRect viewFrame = vc.view.frame;
            if (inToggle) {
                CALayer *presentation = vc.view.layer.presentationLayer;
                if (presentation) viewFrame = presentation.frame;
            }
            CGFloat windowTop = viewFrame.origin.y;
            CGFloat windowMidX = viewFrame.origin.x + viewFrame.size.width / 2;
            CGFloat centerY = windowTop - 6;
            if (centerY < 22) centerY = 22;
            CGPoint wantCenter = CGPointMake(windowMidX, centerY);
            // v52 power: skip the hierarchy mutation + position set
            // when the bar is already in the right parent, at the
            // right center, and already above the window — the end
            // state is identical, only the redundant work is gone.
            BOOL barAbove = ([parent.subviews indexOfObject:dragBar] > [parent.subviews indexOfObject:vc.view]);
            if (dragBar.superview != parent || !CGPointEqualToPoint(dragBar.center, wantCenter) || !barAbove) {
                if (dragBar.superview != parent) [parent addSubview:dragBar];
                dragBar.center = wantCenter;
                [parent insertSubview:dragBar aboveSubview:vc.view];
            }
        } else {
            CGRect b = vc.view.bounds;
            dragBar.center = CGPointMake(b.origin.x + b.size.width / 2, b.origin.y + 22);
            [vc.view bringSubviewToFront:dragBar];
        }
        UIView *pillTop = objc_getAssociatedObject(vc, &kMultitaskFloatPillKey);
        if (pillTop && vc.view.subviews.lastObject != pillTop) [vc.view bringSubviewToFront:pillTop];
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
static VoidIMP origCloseWindow = NULL;

// Window-state toggles: updateVerticalConstraints is only called
// from the maximized branch (and setup/bar toggle), so restoring
// to windowed (or minimizing) never ran ApplyLayout — the pill
// clamp in v15 therefore never fired on shrink, and the pill stayed
// outside the smaller view. Run the layout pass after every
// maximize/minimize toggle so the clamp (and safe-area fix) apply
// on both directions.
// v57 note: small windows now animate out first (see function below);
// the v48 immediate path is kept for maximized/re-entrant closes.
// v48: immediate drag-bar removal on close. v47's viewDidDisappear
// cleanup works, but the host only tears the window down seconds
// after the close tap, so the bar lingered on the list for a few
// seconds. closeWindow runs synchronously at tap (the pill's red
// button calls it directly), so removing the bar here makes it
// vanish immediately; viewDidDisappear stays as the fallback for
// any close path that bypasses closeWindow. Clearing the
// association lets a later sync recreate the bar if the close is
// somehow undone, and the delayed syncs guard on window so a
// closed bar is never recreated. Idempotent with viewDidDisappear
// (whichever runs second sees nil and does nothing).
static void MultitaskFloatCloseWindow(id self, SEL _cmd) {
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    // v57: small-window close animation. The host's closeWindow
    // removes the window immediately (no animation), so a small
    // window just vanishes. Animate it out (scale 0.92 + fade,
    // 0.25s ease-out, drag bar fades with it), then call orig in
    // the completion. Maximized closes keep the old immediate path
    // (unchanged). Re-entrant taps during the animation are ignored
    // (the first completion will close it). Closing during a toggle
    // animation (forced rounded) counts as small here.
    NSNumber *toggleTime = objc_getAssociatedObject(vc, &kMultitaskFloatToggleTimeKey);
    BOOL inToggle = toggleTime && ([[NSDate date] timeIntervalSince1970] - [toggleTime doubleValue] < 0.4);
    BOOL isSmall = !vc.isMaximized || inToggle;
    BOOL alreadyClosing = [objc_getAssociatedObject(vc, &kMultitaskFloatClosingKey) boolValue];
    // v70: a re-entrant tap during the fade is ignored — the first
    // completion closes the window. Previously it fell through to
    // the immediate path below and cut the fade short.
    if (alreadyClosing) return;
    if (isSmall && vc.view.window && !alreadyClosing) {
        objc_setAssociatedObject(vc, &kMultitaskFloatClosingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Stop the per-frame link now (window is going away; ticks
        // must not fight the fade by repositioning the bar).
        id link = objc_getAssociatedObject(vc, &kMultitaskFloatDisplayLinkKey);
        if (link) {
            @try { ((void (*)(id, SEL))objc_msgSend)(link, @selector(invalidate)); } @catch (NSException *e) {}
            objc_setAssociatedObject(vc, &kMultitaskFloatDisplayLinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(vc, &kMultitaskFloatDisplayLinkStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UIView *dragBar = objc_getAssociatedObject(vc, &kMultitaskFloatDragBarKey);
        __weak DecoratedAppSceneViewController *weakVC = vc;
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            vc.view.alpha = 0;
            vc.view.transform = CGAffineTransformMakeScale(0.92, 0.92);
            if (dragBar) dragBar.alpha = 0;
        } completion:^(BOOL finished) {
            // The bar faded with the window; remove it now. Call
            // orig only if the window is still there (a host-side
            // close in the meantime already removed it — don't
            // double-close). Clearing the flags first lets any later
            // sync see clean state.
            if (dragBar) [dragBar removeFromSuperview];
            DecoratedAppSceneViewController *strongVC = weakVC;
            if (strongVC) {
                objc_setAssociatedObject(strongVC, &kMultitaskFloatDragBarKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                // v60: also drop the edge-dock tab + docked flag, so a
                // docked window that gets closed leaves no lingering tab.
                // v61: also hide + drop the dock window (the tab lives in it now).
                UIWindow *dockWindow = objc_getAssociatedObject(strongVC, &kMultitaskFloatDockWindowKey);
                if (dockWindow) dockWindow.hidden = YES;
                objc_setAssociatedObject(strongVC, &kMultitaskFloatDockWindowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                UIView *dockTab = objc_getAssociatedObject(strongVC, &kMultitaskFloatDockTabKey);
                if (dockTab) [dockTab removeFromSuperview];
                objc_setAssociatedObject(strongVC, &kMultitaskFloatDockTabKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(strongVC, &kMultitaskFloatDockedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (MultitaskFloatDockedVC == strongVC) MultitaskFloatDockedVC = nil; // v63: dock slot frees on close
                objc_setAssociatedObject(strongVC, &kMultitaskFloatClosingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (strongVC.view.window && origCloseWindow) origCloseWindow(strongVC, _cmd);
            }
        }];
        return;
    }
    // Maximized close or no window: v48 immediate path (orig first, bar removed at once; viewDidDisappear stays
    // as the fallback for close paths that bypass closeWindow).
    if (origCloseWindow) origCloseWindow(self, _cmd);
    UIView *dragBar = objc_getAssociatedObject(self, &kMultitaskFloatDragBarKey);
    if (dragBar) {
        [dragBar removeFromSuperview];
        objc_setAssociatedObject(self, &kMultitaskFloatDragBarKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // v60: also drop the edge-dock tab + docked flag (see above).
    // v61: also hide + drop the dock window (the tab lives in it now).
    UIWindow *dockWindow = objc_getAssociatedObject(self, &kMultitaskFloatDockWindowKey);
    if (dockWindow) dockWindow.hidden = YES;
    objc_setAssociatedObject(self, &kMultitaskFloatDockWindowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *dockTab = objc_getAssociatedObject(self, &kMultitaskFloatDockTabKey);
    if (dockTab) [dockTab removeFromSuperview];
    objc_setAssociatedObject(self, &kMultitaskFloatDockTabKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kMultitaskFloatDockedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (MultitaskFloatDockedVC == self) MultitaskFloatDockedVC = nil; // v63: dock slot frees on close
}

// v55: forward declaration — maximize/minimize call StartDisplayLink,
// which is defined later in the file; ObjC++ requires declaration
// before use (v53/v54 failed to compile without it).
static void MultitaskFloatStartDisplayLink(DecoratedAppSceneViewController *vc);

static void MultitaskFloatMaximizeWindow(id self, SEL _cmd) {
    // v77: ignore a maximize on a docked window — the window is
    // hidden at the left edge and its tab is the only UI; letting
    // the host maximize it (e.g. when another app opens) would move
    // it out of the dock and strand it. Restore via the tab instead.
    if ([objc_getAssociatedObject(self, &kMultitaskFloatDockedKey) boolValue]) return;
    // v58: stamp the toggle time (see SyncWindowChrome) — rounded
    // chrome is forced for 0.4s after any toggle, both directions.
    objc_setAssociatedObject(self, &kMultitaskFloatToggleTimeKey, @([[NSDate date] timeIntervalSince1970]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
            // v59: nudge the guest to re-layout for its new size —
            // after a shrink, the guest can keep its maximized
            // layout (clipped on the right) until something forces
            // a layout pass; one explicit pass at settle time
            // reflows it to the small width instead of leaving it
            // clipped.
            UIView *sceneView = strongVC.appSceneVC.view;
            if (sceneView) { [sceneView setNeedsLayout]; [sceneView layoutIfNeeded]; }
            // v40: re-assert pinned on top once the toggle animation
            // has settled (the host can reorder windows mid-animation).
            MultitaskFloatBringPinnedToFront();
        }
    });
    // v53: restart the per-frame link on every toggle, so a
    // maximize/restore after the appear link stopped (5s) is still
    // covered continuously (a single 0.35s sync can miss a late host
    // reset, which is why restore-then-click was probabilistically
    // square). StartDisplayLink is idempotent: a running link is a
    // no-op, a stopped link restarts.
    MultitaskFloatStartDisplayLink((DecoratedAppSceneViewController *)self);
}

static void MultitaskFloatMinimizeWindow(id self, SEL _cmd) {
    // v77: ignore a minimize on a docked window — it is already
    // hidden at the left edge; the host's minimize would move it to
    // its own (right-edge) minimized slot and fight the dock.
    if ([objc_getAssociatedObject(self, &kMultitaskFloatDockedKey) boolValue]) return;
    // v58: stamp the toggle time (see SyncWindowChrome).
    objc_setAssociatedObject(self, &kMultitaskFloatToggleTimeKey, @([[NSDate date] timeIntervalSince1970]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (origMinimizeWindow) origMinimizeWindow(self, _cmd);
    MultitaskFloatApplyLayout((DecoratedAppSceneViewController *)self);
    // Same delayed chrome sync as maximize (see above).
    __weak DecoratedAppSceneViewController *weakVC = (DecoratedAppSceneViewController *)self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
            // v59: nudge the guest to re-layout for its new size —
            // after a shrink, the guest can keep its maximized
            // layout (clipped on the right) until something forces
            // a layout pass; one explicit pass at settle time
            // reflows it to the small width instead of leaving it
            // clipped.
            UIView *sceneView = strongVC.appSceneVC.view;
            if (sceneView) { [sceneView setNeedsLayout]; [sceneView layoutIfNeeded]; }
            // v40: re-assert pinned on top once the toggle animation
            // has settled (the host can reorder windows mid-animation).
            MultitaskFloatBringPinnedToFront();
        }
    });
    // v53: same per-frame link restart as maximize (see above).
    MultitaskFloatStartDisplayLink((DecoratedAppSceneViewController *)self);
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
    // v49: touch-ended re-sync. v48's 2.5s timer was too early:
    // Xiaohongshu's load-completion reset lands after 2.5s, so the
    // timer's mask is wiped and no layout fires afterward. The
    // user's discovery (tapping the window during its loading
    // animation rounds the corners) shows a post-reset layout is
    // what sticks — a tap forces one. Mirror that automatically:
    // after every tap ends, re-sync the touched window's chrome,
    // deferred to the next runloop so the tap's own layout has
    // settled. The responder walk finds the Decorated VC through
    // its scene child; taps on the list find none and no-op.
    // Guarded by window (a closed window never re-syncs).
    // Idempotent; only fires on touch-ended, never on moves.
    @try {
        if (event.type == UIEventTypeTouches) {
            Class decoratedCls = objc_getClass("DecoratedAppSceneViewController");
            if (decoratedCls) {
                for (UITouch *touch in event.allTouches) {
                    if (touch.phase != UITouchPhaseEnded) continue;
                    UIResponder *r = touch.view;
                    while (r && ![r isKindOfClass:decoratedCls]) r = r.nextResponder;
                    if (r) {
                        __weak DecoratedAppSceneViewController *weakVC = (DecoratedAppSceneViewController *)r;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            DecoratedAppSceneViewController *strongVC = weakVC;
                            if (strongVC && strongVC.view.window) {
                                MultitaskFloatSyncWindowChrome(strongVC);
                            }
                        });
                    }
                }
            }
        }
    } @catch (NSException *e) {}
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
    objc_setAssociatedObject(vc, &kMultitaskFloatAnimatingOpenStartKey, @([[NSDate date] timeIntervalSince1970]), OBJC_ASSOCIATION_RETAIN_NONATOMIC); // v71: stale-flag detection
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
    // v76: the whole open animation is pure ObjC UIKit again — the
    // pop is a classic spring (damping 0.77, 0.6s, matching the
    // v69 Swift spring), the cover fades 0.15s ease-out, and the
    // handwriting reveal runs below. The completion below is
    // unchanged: restore the anchor, settle chrome, recompute,
    // fade the cover.
    void (^popCompletion)(void) = ^{
        objc_setAssociatedObject(vc, &kMultitaskFloatAnimatingOpenKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, &kMultitaskFloatAnimatingOpenStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    };
    [UIView animateWithDuration:0.6 delay:0 usingSpringWithDamping:0.77 initialSpringVelocity:0 options:0 animations:^{
        view.alpha = 1;
        view.transform = CGAffineTransformIdentity;
        view.layer.cornerRadius = finalRadius;
    } completion:^(BOOL finished) {
        (void)finished;
        popCompletion();
    }];
    // v39: filled-stroke reveal (timing unchanged, driver UIKit
    // again since v76): each glyph's filled ink widens left to
    // right over 0.22s, staggered 0.12s apart (14 glyphs -> last one
    // finishes at ~1.78s), concurrent with the pop. Then the whole
    // container fades out over 0.15s and is removed (~1.9s total),
    // so the strokes present slowly and linger a bit after the pop
    // settles.
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

// v47: clean up the drag bar when the window goes away. v45
// moved the drag bar to the window's superview (so it can sit
// above the top edge), but a superview child is NOT removed when
// the window itself is removed — closing a small window left its
// drag bar orphaned on the App list (blue = a pinned window's bar,
// gray = an unpinned one). viewDidDisappear fires when the window
// closes (and on minimize-if-removed); removing the bar here and
// clearing the association lets the next SyncWindowChrome recreate
// it fresh if the window reappears (restore, or a modal cover
// dismissed), so no bar is lost and none is left behind. The pill
// needs no cleanup (it lives inside vc.view and goes away with it).
// Runs after orig, mirroring viewDidAppear's orig-first order.
static void MultitaskFloatViewDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (origViewDidDisappear) origViewDidDisappear(self, _cmd, animated);
    UIView *dragBar = objc_getAssociatedObject(self, &kMultitaskFloatDragBarKey);
    if (dragBar) {
        [dragBar removeFromSuperview];
        objc_setAssociatedObject(self, &kMultitaskFloatDragBarKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // v77: a docked window disappearing must NOT lose its dock.
    // viewDidDisappear also fires when the host re-parents windows
    // (e.g. another app opens) — the old code dropped the tab +
    // docked flag here and reset the view to identity/visible, so
    // the window came back at whatever frame the host had moved it
    // to (its right-edge minimized slot) with no tab to restore it:
    // the reported right-edge sliver. While docked, keep the tab,
    // the dock window, the docked flag and the dock slot, and leave
    // the view hidden/off-screen-left exactly as DockToEdge left
    // it. The v66 terminate case (a docked window killed via a host
    // path, never to return) is handled by a delayed check below:
    // if the view is still detached — no window and no superview —
    // 10s later, the app is really gone and the tab is dropped then.
    // A re-parented window is back in a window long before that,
    // so its tab survives.
    BOOL wasDocked = [objc_getAssociatedObject(self, &kMultitaskFloatDockedKey) boolValue];
    if (wasDocked) {
        __weak DecoratedAppSceneViewController *weakGoneVC = (DecoratedAppSceneViewController *)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DecoratedAppSceneViewController *strongGoneVC = weakGoneVC;
            if (!strongGoneVC) return;
            if (![objc_getAssociatedObject(strongGoneVC, &kMultitaskFloatDockedKey) boolValue]) return;
            UIView *goneView = strongGoneVC.view;
            if (goneView && !goneView.window && !goneView.superview) {
                UIWindow *goneDockWindow = objc_getAssociatedObject(strongGoneVC, &kMultitaskFloatDockWindowKey);
                if (goneDockWindow) goneDockWindow.hidden = YES;
                objc_setAssociatedObject(strongGoneVC, &kMultitaskFloatDockWindowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                UIView *goneDockTab = objc_getAssociatedObject(strongGoneVC, &kMultitaskFloatDockTabKey);
                if (goneDockTab) [goneDockTab removeFromSuperview];
                objc_setAssociatedObject(strongGoneVC, &kMultitaskFloatDockTabKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(strongGoneVC, &kMultitaskFloatDockedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(strongGoneVC, &kMultitaskFloatDockAnimatingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (MultitaskFloatDockedVC == strongGoneVC) MultitaskFloatDockedVC = nil;
            }
        });
    } else {
        // v60: drop the edge-dock tab + docked flag, so a docked
        // window that goes away leaves no lingering tab.
        // v61: also hide + drop the dock window (the tab lives in it now).
        UIWindow *dockWindow = objc_getAssociatedObject(self, &kMultitaskFloatDockWindowKey);
        if (dockWindow) dockWindow.hidden = YES;
        objc_setAssociatedObject(self, &kMultitaskFloatDockWindowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView *dockTab = objc_getAssociatedObject(self, &kMultitaskFloatDockTabKey);
        if (dockTab) [dockTab removeFromSuperview];
        objc_setAssociatedObject(self, &kMultitaskFloatDockTabKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kMultitaskFloatDockedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kMultitaskFloatDockAnimatingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (MultitaskFloatDockedVC == self) MultitaskFloatDockedVC = nil; // v63: dock slot frees on disappear
    }
    // v51: stop the per-frame link when the window goes away, so a
    // closed window never keeps ticking (the tick also stops itself
    // on nil window, this is the prompt path).
    id link = objc_getAssociatedObject(self, &kMultitaskFloatDisplayLinkKey);
    if (link) {
        @try { ((void (*)(id, SEL))objc_msgSend)(link, @selector(invalidate)); } @catch (NSException *e) {}
        objc_setAssociatedObject(self, &kMultitaskFloatDisplayLinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kMultitaskFloatDisplayLinkStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// v51: per-frame chrome re-sync via CADisplayLink (runtime lookup,
// no QuartzCore link). v50 rounds, but too slowly: timers (even
// every 2s) leave up to 2s of square after every host reset, and
// the host resets repeatedly during load, so the window only
// looks round once the host stops resetting. A display link
// re-applies chrome every frame, so the window reads as round
// from the start (at most one frame of square after a reset),
// instead of waiting for the next timer. Runs 5s (polls to 30s
// remain as fallback), stops early on close (viewDidDisappear)
// or nil window, skips when maximized (no corners to fix there,
// link stays alive for restore). Idempotent; guard prevents
// duplicates on re-appear (a stopped link clears its association,
// so a fresh appear starts a fresh link).
static void MultitaskFloatStartDisplayLink(DecoratedAppSceneViewController *vc) {
    if (!vc.view.window) return;
    if (objc_getAssociatedObject(vc, &kMultitaskFloatDisplayLinkKey)) return;
    @try {
        Class dlCls = objc_getClass("CADisplayLink");
        if (!dlCls) return;
        id link = ((id (*)(id, SEL, id, SEL))objc_msgSend)(dlCls, @selector(displayLinkWithTarget:selector:), vc, @selector(MultitaskFloatDisplayLinkTick:));
        if (!link) return;
        ((void (*)(id, SEL, id, id))objc_msgSend)(link, @selector(addToRunLoop:forMode:), [NSRunLoop mainRunLoop], NSDefaultRunLoopMode);
        objc_setAssociatedObject(vc, &kMultitaskFloatDisplayLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, &kMultitaskFloatDisplayLinkStartKey, @([[NSDate date] timeIntervalSince1970]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) {}
}

static void MultitaskFloatDisplayLinkTick(id self, SEL _cmd, id link) {
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    @try {
        NSTimeInterval start = [objc_getAssociatedObject(vc, &kMultitaskFloatDisplayLinkStartKey) doubleValue];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (!vc.view.window || (start > 0 && now - start > 5.0)) {
            ((void (*)(id, SEL))objc_msgSend)(link, @selector(invalidate));
            objc_setAssociatedObject(vc, &kMultitaskFloatDisplayLinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(vc, &kMultitaskFloatDisplayLinkStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        // v58: don't stop ticks during a toggle animation — the flag
        // can still be maximized then, but the forced-rounded chrome
        // must track the animating bounds every frame (supersedes
        // v56's forceSmall flag, now a 0.4s timestamp window).
        // v57 perf: when maximized, stop the link outright instead of
        // waking 60x/sec for 5s just to return early — restore
        // restarts it via MaximizeWindow (v53), so nothing is lost.
        NSNumber *toggleTime = objc_getAssociatedObject(vc, &kMultitaskFloatToggleTimeKey);
        BOOL inToggle = toggleTime && (now - [toggleTime doubleValue] < 0.4);
        if (vc.isMaximized && !inToggle) {
            ((void (*)(id, SEL))objc_msgSend)(link, @selector(invalidate));
            objc_setAssociatedObject(vc, &kMultitaskFloatDisplayLinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(vc, &kMultitaskFloatDisplayLinkStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        MultitaskFloatSyncWindowChrome(vc);
    } @catch (NSException *e) {}
}

// v71: permanent chrome watchdog. The display link stops after 5s
// and the fixed timers end at 30s, but the host can reset the
// window's clipping later (activation, video, rotation) with no
// layout pass afterward — the window then stays square until the
// user resizes it. Re-sync every 5s while the window exists;
// SyncWindowChrome is idempotent and mostly no-op when nothing
// changed, so one pass per window every 5s costs nothing. The
// chain stops itself when the window goes away, and the flag
// prevents duplicate chains across re-appears. v72 made it windowed
// only, but v74 reverts that: the user hit square corners right
// after shrinking from maximized, so the watchdog syncs in both
// modes (maximized syncs clear the masks, windowed syncs round them).
static void MultitaskFloatChromeWatchdog(DecoratedAppSceneViewController *vc) {
    if (!vc.view.window) {
        objc_setAssociatedObject(vc, &kMultitaskFloatWatchdogKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    MultitaskFloatSyncWindowChrome(vc);
    // v77: re-assert the docked window (if any) on every tick —
    // opening another app is when the host re-parents windows, so
    // the dock must be re-checked continuously, not only on the
    // docked window's own layout passes.
    if (MultitaskFloatDockedVC) MultitaskFloatReassertDock(MultitaskFloatDockedVC);
    __weak DecoratedAppSceneViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC) MultitaskFloatChromeWatchdog(strongVC);
    });
}

static void MultitaskFloatViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (origViewDidAppear) origViewDidAppear(self, _cmd, animated);
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    // v77: a docked window re-appearing must STAY docked. The v66
    // block dropped the dock state here and reset the view to
    // identity/visible, then AnimateOpen popped it at whatever frame
    // the host had moved it to — that is the reported bug: opening
    // another app re-fires appear on the docked window, the host
    // has moved it to its right-edge minimized slot, and it comes
    // back there with no tab. Re-assert the dock instead and return
    // early: no open pop (it would undo the dock transform), no
    // layout, no timers — the tab is the window's UI until tapped.
    // A window reappearing after its app was terminated (the v66
    // case) now stays docked with a visible, tappable tab instead
    // of reappearing invisible, which is the recoverable outcome.
    if ([objc_getAssociatedObject(vc, &kMultitaskFloatDockedKey) boolValue] || [objc_getAssociatedObject(vc, &kMultitaskFloatDockAnimatingKey) boolValue]) {
        MultitaskFloatReassertDock(vc);
        // Keep the watchdog chain alive for this window, so the
        // dock keeps being re-asserted every 5s even if no other
        // window is open to trigger it.
        if (![objc_getAssociatedObject(vc, &kMultitaskFloatWatchdogKey) boolValue]) {
            objc_setAssociatedObject(vc, &kMultitaskFloatWatchdogKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            MultitaskFloatChromeWatchdog(vc);
        }
        return;
    }
    // v77: this window is not docked, but another one may be — a
    // new app opening is exactly when the host re-parents windows,
    // so re-assert that dock here too, before this window's pop.
    if (MultitaskFloatDockedVC && MultitaskFloatDockedVC != vc) MultitaskFloatReassertDock(MultitaskFloatDockedVC);
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
    // v48: late chrome re-sync. Instagram/Xiaohongshu small windows
    // are still square on first open (v47): the host resets clipping
    // after the pop and the 0.5s sync, while the heavy app is still
    // launching, and no layout fires afterward to re-sync — the
    // corners only round after the user toggles maximize/restore
    // (which forces a layout). Re-syncing once more at 2.5s, after
    // launch has usually settled, rounds the corners automatically
    // with no toggle. Guarded by window (a closed window never
    // re-syncs, so a closed bar is never recreated). Idempotent.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
    // v49: later shots. v48's 2.5s was too early for Xiaohongshu:
    // its load-completion reset lands after 2.5s, wiping the
    // timer's mask, and the user's tap-during-animation discovery
    // shows only a post-reset layout sticks. 5s and 8s cover a
    // slower load without needing a tap (the touch-ended sync
    // above covers the tap case). Same window guard, idempotent.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
    // v50: poll to 30s. v49's timers (to 8s) and tap sync both
    // failed on ins/Xiaohongshu — user 11:31: only a bottom-right
    // resize rounds the corners. A resize changes bounds and
    // forces a layout that rebuilds the mask from final bounds;
    // timers and taps do not change bounds, so they rebuild from
    // whatever bounds are current, which are stale if the host's
    // final geometry settles later than 8s. Polling every 2s to
    // 20s, then 25s and 30s, covers a late settle: whenever the
    // host's final geometry lands, a sync follows within 2-5s
    // and rebuilds from final bounds. Same window guard (a
    // closed window never re-syncs, so a closed bar is never
    // recreated). Idempotent; no new lifecycle, just timers.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(14 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DecoratedAppSceneViewController *strongVC = weakVC;
        if (strongVC && strongVC.view.window) {
            MultitaskFloatSyncWindowChrome(strongVC);
        }
    });
    // v51: start the per-frame link (no-op if one is already running).
    MultitaskFloatStartDisplayLink(vc);
    // v71: start the permanent chrome watchdog (no-op if already running).
    if (![objc_getAssociatedObject(vc, &kMultitaskFloatWatchdogKey) boolValue]) {
        objc_setAssociatedObject(vc, &kMultitaskFloatWatchdogKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        MultitaskFloatChromeWatchdog(vc);
    }
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
    // v45: the drag bar is in the superview, so it no longer rides
    // along with the window automatically — re-glue it to the new
    // top edge on every pan update (layout does not run mid-drag).
    if (!vc.isMaximized) {
        UIView *dragBar = objc_getAssociatedObject(vc, &kMultitaskFloatDragBarKey);
        UIView *parent = vc.view.superview;
        if (dragBar && parent && dragBar.superview == parent) {
            CGFloat windowTop = vc.view.frame.origin.y;
            CGFloat windowMidX = vc.view.frame.origin.x + vc.view.frame.size.width / 2;
            CGFloat centerY = windowTop - 6;
            if (centerY < 22) centerY = 22;
            dragBar.center = CGPointMake(windowMidX, centerY);
        }
    }
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

// v60: edge-dock for pinned windows. Tapping yellow minimize on a
// pinned window (blue drag bar) hides the window and leaves only a
// small blue bar at the left screen edge only; tapping that bar restores
// the window. The window itself is never resized or moved in model
// terms — docking slides it off-screen with a transform + fade (so
// its frame/center stay original), and restoring slides it back with
// transform identity + fade. isMaximized is untouched, so a docked
// maximized window restores maximized and a docked small window
// restores small. Pinned stays pinned across dock/restore (docking is
// not unpinning).
// v77: the tab's Y in window (screen) coordinates, from a frame
// given in superview coordinates. vc.view.center is in superview
// coords, so convert — never assume superview == window. Clamped
// so the tab never sits under the status bar or off the bottom.
static CGFloat MultitaskFloatDockTabY(DecoratedAppSceneViewController *vc, CGRect frameInSuperview, UIWindow *window, CGSize screenSize) {
    CGFloat centerY;
    if (window && vc.view.superview) {
        CGRect frameInWindow = [vc.view.superview convertRect:frameInSuperview toView:window];
        centerY = frameInWindow.origin.y + frameInWindow.size.height / 2;
    } else {
        centerY = frameInSuperview.origin.y + frameInSuperview.size.height / 2;
    }
    if (centerY < 70) centerY = 70;
    if (centerY > screenSize.height - 70) centerY = screenSize.height - 70;
    return centerY;
}

// v77: create the edge tab + its window if missing, and (re)place
// the window at the left edge. Shared by DockToEdge and
// ReassertDock, so a tab dropped by an old handler (or a window
// the host moved) is rebuilt at the left edge instead of staying
// lost. Leaves the dock window hidden; the caller shows it when
// the window has slid away (DockToEdge) or at once (ReassertDock).
static void MultitaskFloatEnsureDockTabWindow(DecoratedAppSceneViewController *vc, CGFloat tabYInWindow, UIWindow *window) {
    // v65: bigger edge tab: 64x120 hit area (tappable despite the small visual),
    // 10x80 blue vertical capsule centered in it (the drag bar capsule
    // rotated 90 degrees: same blue = pinned language, same small-bar
    // reading). Created once per dock; removed on restore/close.
    // v61: the tab lives in its own UIWindow (alert level, frame =
    // the tab rect), not in the window's superview — so it stays
    // visible + tappable above ANY app (a maximized guest, another
    // small window, the list), not just above its own window. The
    // window frame is only 64x120, so touches outside the tab still
    // reach the app below; the tab's transparent margins are the
    // tap area, same as before.
    UIView *tab = objc_getAssociatedObject(vc, &kMultitaskFloatDockTabKey);
    if (!tab) {
        tab = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 64, 120)];
        tab.backgroundColor = [UIColor clearColor];
        UIView *capsule = [[UIView alloc] initWithFrame:CGRectMake(27, 20, 10, 80)];
        capsule.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.9];
        capsule.layer.cornerRadius = 5;
        capsule.layer.masksToBounds = YES;
        [tab addSubview:capsule];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:vc action:@selector(MultitaskFloatDockTabTapped:)];
        [tab addGestureRecognizer:tap];
        objc_setAssociatedObject(vc, &kMultitaskFloatDockTabKey, tab, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Position the dock window at the edge (screen coords: the
    // window is full-screen at origin, so screen == window coords;
    // no superview conversion needed). v61: left edge only — the tab
    // is always at the left edge.
    CGFloat tabXInWindow = 10; // v61: left edge only
    UIWindow *dockWindow = objc_getAssociatedObject(vc, &kMultitaskFloatDockWindowKey);
    if (!dockWindow) {
        dockWindow = [[UIWindow alloc] initWithFrame:CGRectMake(tabXInWindow - 32, tabYInWindow - 60, 64, 120)];
        // v62: a UIWindow without a scene never renders (iOS 13+) —
        // that is why the v61 tab never appeared. Attach the host
        // window's scene so the tab actually shows above any app.
        if (window) dockWindow.windowScene = window.windowScene;
        dockWindow.windowLevel = UIWindowLevelAlert;
        dockWindow.backgroundColor = [UIColor clearColor];
        dockWindow.hidden = YES;
        [dockWindow addSubview:tab];
        objc_setAssociatedObject(vc, &kMultitaskFloatDockWindowKey, dockWindow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        dockWindow.frame = CGRectMake(tabXInWindow - 32, tabYInWindow - 60, 64, 120);
        if (window) dockWindow.windowScene = window.windowScene;
        dockWindow.hidden = YES;
        if (tab.superview != dockWindow) [dockWindow addSubview:tab];
    }
}

// v77: re-assert a docked window. The host re-parents / re-appears
// windows when another app opens, and can move the docked window
// (to its right-edge minimized slot), unhide it, or reset its
// transform — any of which strands it on the right with no tab.
// This puts it back: view hidden + slid a full screen width left +
// faded, at the frame it had when it docked, and the tab window
// back at the left edge, visible. Idempotent and cheap when
// nothing moved, so it is safe to call from every layout pass,
// appear, and watchdog tick. Skipped mid-slide (the animation's
// own completion lands the dock); a slide flag older than 2s is
// stale (its completion never ran) and is cleared first, so a lost
// completion can never wedge the dock forever.
static void MultitaskFloatReassertDock(DecoratedAppSceneViewController *vc) {
    if (!vc || !vc.view) return;
    if (![objc_getAssociatedObject(vc, &kMultitaskFloatDockedKey) boolValue]) return;
    if ([objc_getAssociatedObject(vc, &kMultitaskFloatDockAnimatingKey) boolValue]) {
        NSNumber *dockAnimStart = objc_getAssociatedObject(vc, &kMultitaskFloatDockAnimatingStartKey);
        if (dockAnimStart && ([[NSDate date] timeIntervalSince1970] - [dockAnimStart doubleValue] > 2.0)) {
            objc_setAssociatedObject(vc, &kMultitaskFloatDockAnimatingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(vc, &kMultitaskFloatDockAnimatingStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            return;
        }
    }
    UIWindow *window = vc.view.window;
    CGSize screenSize = window ? window.bounds.size : [UIScreen mainScreen].bounds.size;
    // The frame the window had when it docked (superview coords);
    // fall back to the current frame if none was saved.
    NSValue *savedValue = objc_getAssociatedObject(vc, &kMultitaskFloatDockSavedFrameKey);
    CGRect savedFrame = savedValue ? [savedValue CGRectValue] : vc.view.frame;
    if (savedFrame.size.width <= 0 || savedFrame.size.height <= 0) savedFrame = vc.view.frame;
    CGAffineTransform dockTransform = CGAffineTransformMakeTranslation(-screenSize.width, 0);
    // center/bounds are transform-independent, so they tell whether
    // the host moved the model geometry even while the dock slide
    // transform is still applied (frame alone cannot — it is the
    // transformed bounding box).
    CGPoint savedCenter = CGPointMake(savedFrame.origin.x + savedFrame.size.width / 2, savedFrame.origin.y + savedFrame.size.height / 2);
    BOOL viewOK = vc.view.hidden && vc.view.alpha == 0 && CGAffineTransformEqualToTransform(vc.view.transform, dockTransform) && CGSizeEqualToSize(vc.view.bounds.size, savedFrame.size) && (vc.view.center.x - savedCenter.x < 1 && savedCenter.x - vc.view.center.x < 1) && (vc.view.center.y - savedCenter.y < 1 && savedCenter.y - vc.view.center.y < 1);
    if (!viewOK) {
        vc.view.transform = CGAffineTransformIdentity;
        CGRect restoredFrame = savedFrame;
        if (restoredFrame.origin.x > screenSize.width - 100 || restoredFrame.origin.x + restoredFrame.size.width < 100) {
            CGFloat restoredW = fmin(restoredFrame.size.width > 0 ? restoredFrame.size.width : screenSize.width * 0.85, screenSize.width);
            CGFloat restoredH = fmin(restoredFrame.size.height > 0 ? restoredFrame.size.height : screenSize.height * 0.7, screenSize.height);
            restoredFrame = CGRectMake((screenSize.width - restoredW) / 2, (screenSize.height - restoredH) / 2, restoredW, restoredH);
        }
        vc.view.frame = restoredFrame;
        vc.view.transform = dockTransform;
        vc.view.alpha = 0;
        vc.view.hidden = YES;
    }
    // Tab window: must exist and sit at the left edge, at the saved
    // frame's height. Rebuilt here if it was dropped.
    CGFloat tabY = MultitaskFloatDockTabY(vc, savedFrame, window, screenSize);
    MultitaskFloatEnsureDockTabWindow(vc, tabY, window);
    UIWindow *dockWindow = objc_getAssociatedObject(vc, &kMultitaskFloatDockWindowKey);
    if (dockWindow) dockWindow.hidden = NO;
    UIView *dragBar = objc_getAssociatedObject(vc, &kMultitaskFloatDragBarKey);
    if (dragBar) dragBar.hidden = YES;
}

static void MultitaskFloatDockToEdge(DecoratedAppSceneViewController *vc) {
    if (!vc.view || !vc.view.window || !vc.view.superview) return;
    // v66: a dock already sliding must not be re-entered — repeated
    // taps in the slide window stacked a second dock/minimize on
    // top of the first and left the window at a side position.
    if ([objc_getAssociatedObject(vc, &kMultitaskFloatDockAnimatingKey) boolValue]) return;
    if ([objc_getAssociatedObject(vc, &kMultitaskFloatDockedKey) boolValue]) return;
    // v63: only one docked window — if a DIFFERENT window is already
    // docked, prompt and refuse this dock (leave this window as it
    // was, keep the docked one). Same-window re-dock is already
    // blocked above (docked flag), and its pill is hidden anyway.
    if (MultitaskFloatDockedVC && MultitaskFloatDockedVC != vc) {
        if (!vc.presentedViewController) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"只能吸附一个窗口" message:@"已经有一个窗口吸附在左边了，先恢复它再吸附这个。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:alert animated:YES completion:nil];
        }
        return;
    }
    UIWindow *window = vc.view.window;
    CGSize screenSize = window.bounds.size;
    // v77: save the frame the window has now, so restore (and the
    // re-assert) can put it back even if the host moves it while
    // docked. Only a mostly-on-screen frame is worth saving — if
    // the host already moved it to a side slot, keep the last good
    // frame (or a centered default) instead of saving the stranded
    // one.
    CGRect frameNow = vc.view.frame;
    BOOL frameNowOnScreen = frameNow.size.width > 0 && frameNow.size.height > 0 && frameNow.origin.x <= screenSize.width - 100 && frameNow.origin.x + frameNow.size.width >= 100;
    NSValue *prevSavedFrame = objc_getAssociatedObject(vc, &kMultitaskFloatDockSavedFrameKey);
    CGRect savedFrame = frameNow;
    if (!frameNowOnScreen) {
        if (prevSavedFrame) {
            savedFrame = [prevSavedFrame CGRectValue];
        } else {
            CGFloat defaultW = screenSize.width * 0.85, defaultH = screenSize.height * 0.7;
            savedFrame = CGRectMake((screenSize.width - defaultW) / 2, (screenSize.height - defaultH) / 2, defaultW, defaultH);
        }
    }
    objc_setAssociatedObject(vc, &kMultitaskFloatDockSavedFrameKey, [NSValue valueWithCGRect:savedFrame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // v77: tab + dock window (created / re-placed at the left edge).
    // Kept hidden until the window has slid away, so the window
    // appears to become the tab.
    CGFloat tabYInWindow = MultitaskFloatDockTabY(vc, savedFrame, window, screenSize);
    MultitaskFloatEnsureDockTabWindow(vc, tabYInWindow, window);
    UIWindow *dockWindow = objc_getAssociatedObject(vc, &kMultitaskFloatDockWindowKey);
    objc_setAssociatedObject(vc, &kMultitaskFloatDockedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MultitaskFloatDockedVC = vc; // v63: single dock — record the docked window
    objc_setAssociatedObject(vc, &kMultitaskFloatDockAnimatingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // v66
    objc_setAssociatedObject(vc, &kMultitaskFloatDockAnimatingStartKey, @([[NSDate date] timeIntervalSince1970]), OBJC_ASSOCIATION_RETAIN_NONATOMIC); // v77: stale-flag detection
    UIView *dragBar = objc_getAssociatedObject(vc, &kMultitaskFloatDragBarKey);
    // Slide the window off-screen toward the dock edge + fade out;
    // the drag bar fades where it was (it does not slide with the
    // window — it lives in the superview, not in vc.view). Transform
    // only: center/bounds stay original, so restoring transform to
    // identity returns the window exactly. Slide by a full screen
    // width (not the window width) so every position — centered
    // included — ends fully off-screen, not with a strip left.
    CGFloat dx = -screenSize.width; // v61: left edge only
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        vc.view.transform = CGAffineTransformMakeTranslation(dx, 0);
        vc.view.alpha = 0;
        if (dragBar) dragBar.alpha = 0;
    } completion:^(BOOL finished) {
        (void)finished;
        vc.view.hidden = YES;
        if (dragBar) dragBar.hidden = YES;
        dockWindow.hidden = NO;
        objc_setAssociatedObject(vc, &kMultitaskFloatDockAnimatingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // v66
        objc_setAssociatedObject(vc, &kMultitaskFloatDockAnimatingStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // v77
    }];
}

static void MultitaskFloatRestoreFromEdge(DecoratedAppSceneViewController *vc) {
    if (!vc.view) return;
    // v66: same in-flight guard as DockToEdge — a second restore
    // tap mid-slide must not re-run the slide-back.
    if ([objc_getAssociatedObject(vc, &kMultitaskFloatDockAnimatingKey) boolValue]) return;
    if (![objc_getAssociatedObject(vc, &kMultitaskFloatDockedKey) boolValue]) return;
    objc_setAssociatedObject(vc, &kMultitaskFloatDockAnimatingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // v66
    objc_setAssociatedObject(vc, &kMultitaskFloatDockAnimatingStartKey, @([[NSDate date] timeIntervalSince1970]), OBJC_ASSOCIATION_RETAIN_NONATOMIC); // v77: stale-flag detection
    // Hide the dock window first: the window slides back from the
    // edge as the tab vanishes, so the tab reads as becoming the
    // window. Hiding + clearing the window also releases the tab
    // (it was the window's subview); clear its association too so
    // no dangling tab remains.
    UIWindow *dockWindow = objc_getAssociatedObject(vc, &kMultitaskFloatDockWindowKey);
    if (dockWindow) dockWindow.hidden = YES;
    objc_setAssociatedObject(vc, &kMultitaskFloatDockWindowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *tab = objc_getAssociatedObject(vc, &kMultitaskFloatDockTabKey);
    if (tab) [tab removeFromSuperview];
    objc_setAssociatedObject(vc, &kMultitaskFloatDockTabKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &kMultitaskFloatDockedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (MultitaskFloatDockedVC == vc) MultitaskFloatDockedVC = nil; // v63: dock slot frees on restore
    // v77: restore the frame the window had when it docked — the
    // host may have moved it while docked, and restoring transform
    // alone would land it at the host's (right-edge) frame. Do it
    // with transform identity, then re-apply the dock slide before
    // unhiding, so nothing flashes on-screen at the wrong place. A
    // saved frame that is itself mostly off-screen is ignored in
    // favour of centering the current frame.
    CGSize restoreScreenSize = vc.view.window ? vc.view.window.bounds.size : [UIScreen mainScreen].bounds.size;
    vc.view.transform = CGAffineTransformIdentity;
    NSValue *savedRestoreFrame = objc_getAssociatedObject(vc, &kMultitaskFloatDockSavedFrameKey);
    BOOL frameRestored = NO;
    if (savedRestoreFrame) {
        CGRect savedRestoreRect = [savedRestoreFrame CGRectValue];
        if (savedRestoreRect.size.width > 0 && savedRestoreRect.size.height > 0 && savedRestoreRect.origin.x <= restoreScreenSize.width - 100 && savedRestoreRect.origin.x + savedRestoreRect.size.width >= 100) {
            vc.view.frame = savedRestoreRect;
            frameRestored = YES;
        }
    }
    if (!frameRestored) {
        // No usable saved frame (e.g. docked by a pre-v77 build):
        // at least never restore to a mostly-off-screen frame.
        CGRect curRestoreFrame = vc.view.frame;
        if (curRestoreFrame.size.width > 0 && curRestoreFrame.size.height > 0 && (curRestoreFrame.origin.x > restoreScreenSize.width - 100 || curRestoreFrame.origin.x + curRestoreFrame.size.width < 100)) {
            CGFloat restoreW = fmin(curRestoreFrame.size.width, restoreScreenSize.width);
            CGFloat restoreH = fmin(curRestoreFrame.size.height, restoreScreenSize.height);
            vc.view.frame = CGRectMake((restoreScreenSize.width - restoreW) / 2, (restoreScreenSize.height - restoreH) / 2, restoreW, restoreH);
        }
    }
    vc.view.transform = CGAffineTransformMakeTranslation(-restoreScreenSize.width, 0);
    vc.view.alpha = 0;
    // Unhide at the docked transform (off-screen, alpha 0), so
    // unhiding flashes nothing; then slide back to identity + fade
    // in. The drag bar (small windows only — maximized hides it)
    // fades back in where it was (it never moved during dock).
    vc.view.hidden = NO;
    UIView *dragBar = objc_getAssociatedObject(vc, &kMultitaskFloatDragBarKey);
    BOOL showBar = !vc.isMaximized;
    if (dragBar && showBar) dragBar.hidden = NO;
    // v64: bring the restored window to the very front (above any
    // fullscreen window) BEFORE sliding back, so the slide is visible
    // and the window does not land behind a fullscreen app. Pinned
    // windows must stay on top (v40) — restore must not break that.
    UIView *restoreParent = vc.view.superview;
    if (restoreParent) {
        [restoreParent bringSubviewToFront:vc.view];
        if (dragBar) [restoreParent insertSubview:dragBar aboveSubview:vc.view];
    }
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        vc.view.transform = CGAffineTransformIdentity;
        vc.view.alpha = 1;
        if (dragBar && showBar) dragBar.alpha = 1;
    } completion:^(BOOL finished) {
        (void)finished;
        objc_setAssociatedObject(vc, &kMultitaskFloatDockAnimatingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // v66
        objc_setAssociatedObject(vc, &kMultitaskFloatDockAnimatingStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // v77
        MultitaskFloatSyncWindowChrome(vc);
        MultitaskFloatStartDisplayLink(vc);
    }];
}

static void MultitaskFloatDockTabTapped(id self, SEL _cmd, UITapGestureRecognizer *sender) {
    (void)sender;
    DecoratedAppSceneViewController *vc = (DecoratedAppSceneViewController *)self;
    MultitaskFloatRestoreFromEdge(vc);
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

// v42: per-app multitask dot on the App list.
// Each app row is LCAppBannerViewController (UIKit; its view is
// LCAppBannerRootView, bannerHeight 88, with a 70x32 Launch control
// trailing -14, centerY). The host already has the multitask action
// in its long-press menu (runApp with the opposite mode), but reaching
// it costs a long-press plus a menu tap. The dot surfaces a multitask
// launch as one tap, per app: each row's VC gets its own dot, so it
// scrolls with its row and always launches its own row's app — it
// taps the row's own Launch control, so a reused VC still launches
// the app it currently shows (no per-app state on the dot itself).
//
// v43: the dot NO LONGER calls LCUtils directly (that was v42, and it
// crashed: skipping runApp's setup let a nil container reach the
// window init, and AppScene init crashed building a dictionary).
// The dot now goes through the official path (see DotTapped): flip
// the global multitask-launch default, tap the row's own Launch, and
// restore the default. That also fixes the v42 JIT limitation — JIT
// apps now get runApp's full JIT step via the dot, like via Launch.
// v44: the dot's color now matches the Launch button's color (see
// SyncDotColor): the Launch capsule is per-app (icon hue) when the
// host's dynamic-colors setting is on, otherwise FontColor/systemBlue;
// the dot copies that accent on every layout, and its icon stays
// white like the Launch title.

// v42: LCAppBannerViewController is a Swift class; its ObjC runtime
// name is module-prefixed (e.g. "LiveContainer.LCAppBannerViewController").
// Same lookup discipline as the dock class: exact name first, then
// module-prefixed suffix — never a loose substring. Accept only a
// UIViewController descendant.
static Class MultitaskFloatBannerClass(void) {
    Class cls = objc_getClass("LCAppBannerViewController");
    if (!cls) {
        int count = objc_getClassList(NULL, 0);
        if (count <= 0) return Nil;
        Class *list = (Class *)malloc(sizeof(Class) * (size_t)count);
        if (!list) return Nil;
        count = objc_getClassList(list, count);
        const char *suffix = ".LCAppBannerViewController";
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
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        if (strcmp(class_getName(c), "UIViewController") == 0) return cls;
    }
    return Nil;
}

// v43: the display-name helper was removed — the dot no longer
// launches directly, so it no longer needs the row's display name
// (see DotTapped).

// v42: the Launch control is the banner view's only original UIControl
// direct subview. This search runs in viewDidLoad before the dot is
// added, so the only UIControl present is the Launch control.
static UIControl *MultitaskFloatBannerRunControl(UIView *bannerView) {
    if (!bannerView) return nil;
    for (UIView *sub in bannerView.subviews) {
        if ([sub isKindOfClass:[UIControl class]]) return (UIControl *)sub;
    }
    return nil;
}

// v43: dot tap — launch this row's app in multitask mode via the
// OFFICIAL path, not a direct launch call. v42 called LCUtils
// directly and skipped runApp's setup (container creation, JIT,
// locked check), so for an app without a ready container LCUtils
// passed nil into the window init and AppScene init crashed building
// a dictionary (attempt to insert nil). The fix: temporarily turn on
// the global multitask-launch default, tap the row's own Launch
// control (which runs the full runApp path), then restore the
// setting. The flag is read synchronously at runApp's start, so
// restoring after 1.5s is far beyond the race window; the only side
// effect is that another app launched within those 1.5s would also
// open in multitask. Per-app explicit never-multitask still overrides
// the global flag (rare; those apps keep launching normally via the
// dot). Debounced (a double-tap would otherwise launch twice).
static void MultitaskFloatDotTapped(id self, SEL _cmd, UIButton *sender) {
    (void)_cmd;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSNumber *last = objc_getAssociatedObject(sender, &kMultitaskFloatDotTapTimeKey);
    if (last && now - [last doubleValue] < 1.5) return;
    objc_setAssociatedObject(sender, &kMultitaskFloatDotTapTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIViewController *vc = (UIViewController *)self;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL wasOn = [defaults boolForKey:@"LCLaunchInMultitaskMode"];
    if (!wasOn) [defaults setBool:YES forKey:@"LCLaunchInMultitaskMode"];
    // Trigger the row's own Launch (official path). runButtonTapped
    // is @objc, so it is callable from ObjC even though it is private
    // in Swift. If the app is already open in multitask, Launch brings
    // its window forward and returns early — same as tapping Launch.
    if ([vc respondsToSelector:@selector(runButtonTapped)]) {
        ((void (*)(id, SEL))objc_msgSend)(vc, @selector(runButtonTapped));
    }
    if (!wasOn) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [defaults setBool:NO forKey:@"LCLaunchInMultitaskMode"];
        });
    }
}

// v42: add the per-app multitask dot after the host sets the row up.
// 32x32 circle (same height as the 70x32 Launch pill, so it reads as
// the same size), 8pt left of Launch, vertically centered, with the
// multitask SF Symbol (same icon the long-press menu uses). Added
// once per VC (guarded by the associated object); Auto Layout keeps
// it glued to Launch across rotations and row resizes, and because
// the dot lives inside the row's own view it scrolls with its row.
static void MultitaskFloatBannerViewDidLoad(id self, SEL _cmd) {
    if (origBannerViewDidLoad) origBannerViewDidLoad(self, _cmd);
    UIViewController *vc = (UIViewController *)self;
    UIView *bannerView = vc.view;
    if (!bannerView) return;
    if (objc_getAssociatedObject(vc, &kMultitaskFloatDotKey)) return;
    UIControl *runControl = MultitaskFloatBannerRunControl(bannerView);
    if (!runControl) return;
    UIButton *dot = [UIButton buttonWithType:UIButtonTypeCustom];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = [UIColor systemBlueColor];
    dot.layer.cornerRadius = 16;
    dot.layer.masksToBounds = YES;
    UIImageSymbolConfiguration *symConfig = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    UIImage *icon = [UIImage systemImageNamed:@"macwindow.badge.plus" withConfiguration:symConfig];
    [dot setImage:icon forState:UIControlStateNormal];
    dot.tintColor = [UIColor whiteColor];
    [dot addTarget:vc action:@selector(MultitaskFloatDotTapped:) forControlEvents:UIControlEventTouchUpInside];
    [bannerView addSubview:dot];
    [NSLayoutConstraint activateConstraints:@[
        [dot.widthAnchor constraintEqualToConstant:32],
        [dot.heightAnchor constraintEqualToConstant:32],
        [dot.centerYAnchor constraintEqualToAnchor:bannerView.centerYAnchor],
        [dot.trailingAnchor constraintEqualToAnchor:runControl.leadingAnchor constant:-8],
    ]];
    objc_setAssociatedObject(vc, &kMultitaskFloatDotKey, dot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// v42: keep double-tap-on-dot from opening Settings. The host's
// double-tap handler only excludes the Launch control's bounds, so a
// double-tap on the dot would otherwise open Settings (and the dot
// itself would fire twice, which the tap debounce already guards).
// If the tap lands on the dot, swallow it; otherwise chain to orig.
static void MultitaskFloatBannerDoubleTapped(id self, SEL _cmd, UITapGestureRecognizer *gr) {
    UIViewController *vc = (UIViewController *)self;
    UIView *bannerView = vc.view;
    UIButton *dot = objc_getAssociatedObject(vc, &kMultitaskFloatDotKey);
    if (bannerView && dot) {
        CGPoint loc = [gr locationInView:bannerView];
        if (CGRectContainsPoint(dot.frame, loc)) return;
    }
    if (origBannerDoubleTapped) origBannerDoubleTapped(self, _cmd, gr);
}

// v42: hook the App list rows. Pure runtime only (safe for the
// constructor): class lookup, method swaps, one new selector. If the
// banner class is not found, do nothing — the window hooks are
// unaffected.
// v44: keep the dot's color identical to the Launch button's color.
// The Launch button (LCAppBannerRunControl) does not paint via its
// backgroundColor — its visible capsule is a CALayer sublayer
// (baseLayer, added first in its setupView, frame == bounds) whose
// backgroundColor is the row's accent color: the app icon's dominant
// hue when the host's dynamic-colors setting is on, otherwise the
// FontColor asset (falling back to systemBlue). That accent is set in
// the Swift update() (after viewDidLoad, and again on every row reuse),
// which ObjC cannot hook (not @objc). So instead of copying once,
// sync on every layout of the banner VC: by first layout the row's
// update has already set the Launch color, and on reuse update()
// triggers layout again, so the dot always matches the Launch button
// it sits next to — including per-app hues and light/dark changes.
// The Launch title is white, so the dot's white icon already matches
// and stays white. Uses only public APIs (layer.sublayers); if no
// base layer color is found yet (update has not run), the dot keeps
// its systemBlue fallback from viewDidLoad.
static void MultitaskFloatSyncDotColor(UIViewController *vc) {
    if (!vc) return;
    UIView *bannerView = vc.view;
    if (!bannerView) return;
    UIButton *dot = objc_getAssociatedObject(vc, &kMultitaskFloatDotKey);
    if (!dot) return;
    UIControl *runControl = nil;
    for (UIView *sub in bannerView.subviews) {
        if ([sub isKindOfClass:[UIControl class]] && sub != dot) { runControl = (UIControl *)sub; break; }
    }
    if (!runControl) return;
    CALayer *baseLayer = nil;
    for (CALayer *layer in runControl.layer.sublayers) {
        if (layer.backgroundColor && CGRectEqualToRect(layer.frame, runControl.bounds)) { baseLayer = layer; break; }
    }
    if (!baseLayer) {
        for (CALayer *layer in runControl.layer.sublayers) {
            if (layer.backgroundColor) { baseLayer = layer; break; }
        }
    }
    if (!baseLayer || !baseLayer.backgroundColor) return;
    if (!CGColorEqualToColor(dot.backgroundColor.CGColor, baseLayer.backgroundColor)) {
        dot.backgroundColor = [UIColor colorWithCGColor:baseLayer.backgroundColor];
    }
}

// v44: layout hook for the dot color sync (see above).
static void MultitaskFloatBannerViewDidLayoutSubviews(id self, SEL _cmd) {
    if (origBannerViewDidLayoutSubviews) origBannerViewDidLayoutSubviews(self, _cmd);
    MultitaskFloatSyncDotColor((UIViewController *)self);
}

static void MultitaskFloatHookBanner(void) {
    Class cls = MultitaskFloatBannerClass();
    if (!cls) return;
    Method mLoad = class_getInstanceMethod(cls, @selector(viewDidLoad));
    if (mLoad) {
        origBannerViewDidLoad = (VoidIMP)method_getImplementation(mLoad);
        if (!class_addMethod(cls, @selector(viewDidLoad), (IMP)MultitaskFloatBannerViewDidLoad, method_getTypeEncoding(mLoad))) {
            method_setImplementation(mLoad, (IMP)MultitaskFloatBannerViewDidLoad);
        }
    }
    // The dot handler is a new selector, so adding it is safe.
    class_addMethod(cls, @selector(MultitaskFloatDotTapped:), (IMP)MultitaskFloatDotTapped, "v@:@");
    // Exclude dot taps from the host's double-tap-to-Settings.
    Method mDouble = class_getInstanceMethod(cls, @selector(bannerDoubleTapped:));
    if (mDouble) {
        origBannerDoubleTapped = (BannerDoubleTappedIMP)method_getImplementation(mDouble);
        if (!class_addMethod(cls, @selector(bannerDoubleTapped:), (IMP)MultitaskFloatBannerDoubleTapped, method_getTypeEncoding(mDouble))) {
            method_setImplementation(mDouble, (IMP)MultitaskFloatBannerDoubleTapped);
        }
    }
    // v44: sync the dot's color from the Launch button on every layout.
    Method mLayout = class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews));
    if (mLayout) {
        origBannerViewDidLayoutSubviews = (VoidIMP)method_getImplementation(mLayout);
        if (!class_addMethod(cls, @selector(viewDidLayoutSubviews), (IMP)MultitaskFloatBannerViewDidLayoutSubviews, method_getTypeEncoding(mLayout))) {
            method_setImplementation(mLayout, (IMP)MultitaskFloatBannerViewDidLayoutSubviews);
        }
    }
}

__attribute__((constructor))
static void MultitaskFloatConstructor(void) {
    // Dyld-init time: ONLY pure runtime calls. No UIKit, no defaults, no
    // Security. Everything else happens when windows are created/laid out.
    // v42: banner hook is independent of the window class (it must run
    // even if DecoratedAppSceneViewController is absent, unlike the
    // window hooks below which return early without it).
    MultitaskFloatHookBanner();
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
    // v48: closeWindow — same direct swap (the class defines it).
    // Removes the drag bar immediately at tap (see function).
    Method mClose = class_getInstanceMethod(cls, @selector(closeWindow));
    if (mClose) {
        origCloseWindow = (VoidIMP)method_getImplementation(mClose);
        method_setImplementation(mClose, (IMP)MultitaskFloatCloseWindow);
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
    // viewDidDisappear: same pattern; the class does not define
    // it, so adding an override is safe. (v47: drag-bar cleanup
    // when the window goes away — see MultitaskFloatViewDidDisappear.)
    Method mDisappear = class_getInstanceMethod(cls, @selector(viewDidDisappear:));
    if (mDisappear) {
        origViewDidDisappear = (ViewDidAppearIMP)method_getImplementation(mDisappear);
        if (!class_addMethod(cls, @selector(viewDidDisappear:), (IMP)MultitaskFloatViewDidDisappear, method_getTypeEncoding(mDisappear))) {
            method_setImplementation(mDisappear, (IMP)MultitaskFloatViewDidDisappear);
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
    // v60: edge-dock tab tap is a new selector too, so adding it is safe.
    class_addMethod(cls, @selector(MultitaskFloatDockTabTapped:), (IMP)MultitaskFloatDockTabTapped, "v@:@");
    // v51: per-frame tick is a new selector too, so adding it is safe.
    class_addMethod(cls, @selector(MultitaskFloatDisplayLinkTick:), (IMP)MultitaskFloatDisplayLinkTick, "v@:@");
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
