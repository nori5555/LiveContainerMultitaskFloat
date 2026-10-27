# LiveContainerMultitaskFloat

A LiveContainer tweak that strips multitask windows down to just the three
traffic-light buttons floating over the app, and removes the side multitask
dock outright — not just hidden.

## What it does

- **Maximized windows:** no app name, no bar background, no translucency.
  The top of the window is fully the app. The three buttons
  (minimize / maximize / close) live in a floating pill over the app
  instead of in a bar, so they never block the app's own top controls.
- **The pill is draggable:** move it anywhere, AssistiveTouch-style. It
  docks to the nearest left/right edge when you let go. Tapping a button
  still works — the drag only takes over once your finger moves.
- **Pin a window on top:** double-tap the drag bar at the top of a small
  window to pin it (blue capsule). A pinned window stays above the others.
- **Edge dock for pinned windows:** minimize a pinned window and it docks
  to the left screen edge as a small blue tab. Tap the tab to slide it
  back. Only one window is docked at a time.
- **Multitask dot:** every app row in the app list gets a one-tap dot that
  opens that app straight into multitask, no long-press menu.
- **Custom open animation:** LiveContainer multitasking has no native open
  animation, so this one adds its own — a scale pop with an overlay and a
  handwritten "MultitaskFloat". Only the parameters are ever tuned; the
  animation itself is never removed.
- **Haptics, one tap per action:** open, close, maximize/restore, dock,
  drag grab/release, and pin/unpin each get a single impact, tuned per
  action (medium for open, maximize, dock landing and pin; light for
  close, restore, minimize and drags). Follows the system haptics switch.
- **Top controls stay put:** the app's top content does not slide up
  under the status bar when the bar goes away. The guest's top safe area
  is compensated for the scene extension, and the layout is re-synced
  once it settles.
- **Side dock, gone and kept gone:** the dock's hosting controller is
  removed outright, so there is no dock view, no edge swipe to wake it,
  and no sliver on screen. The dock's collapsed state is also pinned, so
  the window bar stays hidden when maximized and the app's content never
  shifts up or leaves a white band at the bottom.
- **Windowed windows:** corners match the device's own display corner
  radius, and an iPad-style drag capsule sits at the top center for
  dragging the window. The pill stays inside the window and remains
  tappable after resizing, and small windows stay draggable from the
  top strip.

## Installation

1. Download `MultitaskFloat.dylib` from the nightly release.
2. Put it in LiveContainer's global Tweaks folder.
3. Sign it.
4. In LiveContainer Settings, tap the version number 5 times and enable
   **Load Tweaks to LiveContainer Itself**.
5. Restart LiveContainer.

On every update: delete the old dylib, put the new one in, sign it, and
restart LiveContainer.

## How it works

Pure runtime, no CydiaSubstrate, so it loads on jailed devices. The
constructor only installs method swizzles; everything else is deferred
to appearance and layout time. It hooks `DecoratedAppSceneViewController`
(window chrome, safe area, window-state toggles) and
`MultitaskDockManager` (the dock's hosting controller is removed via
direct ivar access, and `isCollapsed` is pinned so the window bar stays
hidden when maximized). A watchdog re-syncs window chrome and re-asserts
the dock state every 5 seconds, so host resets never leave a window
square or bring the dock back.

## Building

Pushes to `main` trigger the nightly workflow (Theos), which publishes
`MultitaskFloat.dylib` to the nightly release.

## Recent changes

- v83: pin the dock's collapsed state (v81/v82 dropped it, which let the
  nav bar back in when maximized and shifted app content up with a white
  band at the bottom).
- v82: remove the dock by direct ivar access instead of hiding it.
- v81: first attempt at removing the dock (regressed — the dock came
  back visible; fixed by v82).
- v80: per-action haptics, tuned individually.
- v79: stop the watchdog from making the docked blue tab flicker.
- v77: keep a docked window docked when another app opens (it used to
  strand as a sliver on the right edge).

## Tested on

LiveContainer 3.8.11, iOS 27.0.1, iPhone17,2.

## Troubleshooting

If LiveContainer will not open after an update, rename the dylib to
`.disabled` (or delete it) and reopen LiveContainer.
