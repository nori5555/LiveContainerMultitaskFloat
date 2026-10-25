# LiveContainerMultitaskFloat

A LiveContainer tweak that strips multitask windows down to just the three
traffic-light buttons floating over the app, and removes the side multitask
dock — for good.

## What it does

- **Maximized windows:** no app name, no bar background, no translucency.
  The top of the window is fully the app. The three buttons
  (minimize / maximize / close) live in a floating pill over the app
  instead of in a bar, so they never block the app's own top controls.
- **The pill is draggable:** move it anywhere, AssistiveTouch-style. It
  docks to the nearest left/right edge when you let go. Tapping a button
  still works — the drag only takes over once your finger moves.
- **Top controls stay put:** the app's top content does not slide up
  under the status bar when the bar goes away. The guest's top safe area
  is compensated for the scene extension, and the layout is re-synced
  once it settles.
- **Side dock, gone and kept gone:** the multitask dock is collapsed and
  hidden, and that state is persisted, so it stays gone across window
  opens and LiveContainer relaunches.
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
`MultitaskDockManager` (dock hide plus persistence via
`LCHideCollapsedDock` in the app-group defaults).

## Building

Pushes to `main` trigger the nightly workflow (Theos), which publishes
`MultitaskFloat.dylib` to the nightly release.

## Tested on

LiveContainer 3.8.11, iOS 27.0.1, iPhone17,2.

## Troubleshooting

If LiveContainer will not open after an update, rename the dylib to
`.disabled` (or delete it) and reopen LiveContainer.
