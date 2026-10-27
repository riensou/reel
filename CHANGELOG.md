# Changelog

## Unreleased

- Bigger toolbar
- The region selection is remembered as soon as you draw, move or resize it — even if you close the toolbar or press Esc without capturing — for screenshots and recordings alike
- Outside the selection the cursor is a normal arrow; the crosshair only appears when there's nothing selected yet
- Resize from anywhere along an edge (sideways or up/down) and from a generous zone around each corner, like ⌘⇧5; the box follows the drag instead of jumping to the pointer. A stray click outside the box no longer disturbs it
- Esc closes the toolbar from anywhere, even when another app has focus
- Fixed: after a three-finger swipe to another Space, the cursor stayed an arrow over the selection until you clicked
- Dev: `--self-test` and `--soak` run headless (no overlays on screen, no focus or hotkey stolen); `--watch` shows them. `scripts/make-dev-cert.sh` stops the per-build codesign password prompt

## 0.1.2

- Fixed: the region selection couldn't be moved with the mouse (clicks inside it went to the window underneath). Press inside the box, or on an edge away from the dots, and drag
- Region mode no longer draws a default box when there's no previous selection; draw your own

## 0.1.1

- Region mode works like ⌘⇧5: your last selection appears with the toolbar. Drag inside it to move, drag the handles to resize, then Capture/Record
- Clearer cursors when selecting (hand to move, resize arrows on handles)
- Fixed: Trim did nothing if trimming took longer than the thumbnail's 5-second countdown
- Fixed: if macOS stops a recording (e.g. Stop in the menu bar indicator), what was recorded is now saved instead of lost
- Removed double-click to capture a region (it could capture when you meant to move the selection)

## 0.1.0

First release.

- Screenshots and recordings of a screen, window, or region from a menu bar toolbar (⌘⇧6)
- Floating thumbnail: click to open, drag into apps, swipe to dismiss; trim, export GIF, convert MP4/MOV
- System audio and microphone with live level meters; mixed into one track
- MP4 (H.264, HEVC above 4K) or MOV; pause, resume, cancel
- Remembers your last region; resize with handles, edge snapping
- Optional: countdown, recording border, keystroke display, webcam bubble, auto-zoom on clicks, smooth cursor
- Plain-text config at `~/.config/reel/config` with live reload, plus a Settings window
- Welcome window on first launch; daily update check (can be turned off)
