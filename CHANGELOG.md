# Changelog

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
