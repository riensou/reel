# reel

A sleeker, open-source ⌘⇧5 for macOS, built on ScreenCaptureKit. It keeps what works in the system tool (the floating bottom-right thumbnail that then drops the file into your screenshots folder) and puts audio, mic and cursor controls directly on the toolbar.

## Run

```sh
scripts/run.sh          # build reel.app, then launch it (menu-bar app, no Dock icon)
scripts/bundle.sh       # build only: build/reel.app
```

The first time it runs, macOS asks for **Screen Recording** permission, plus **Microphone** permission if mic capture is on. The app is ad-hoc signed, so macOS may ask again after a rebuild.

## Use

- **⌘⇧6** opens the capture toolbar. While a recording is running, it stops the recording.
  To use ⌘⇧5 instead: turn off the system shortcut in System Settings → Keyboard → Keyboard Shortcuts → Screenshots, then change the key code in `AppDelegate.swift`.
- Toolbar: **Screen / Window / Region** · **Screenshot / Record** · system audio · mic · show cursor · Options (mic device, fps, save folder, thumbnail) · **Capture**.
- While recording, the menu bar shows ● and a timer. Click it to stop.
- Thumbnail: click to open the file, drag it into any app, swipe it away, or right-click for Show in Finder / Copy / Delete. If you leave it, the file is saved after 5 seconds.
- Save folder: by default, the same place macOS screenshots go (`defaults read com.apple.screencapture location`). You can change it under Options.

Headless (for scripts and testing; captures the main display):

```sh
build/reel.app/Contents/MacOS/reel --shot out.png
build/reel.app/Contents/MacOS/reel --record 10 out.mov --system-audio --mic --no-cursor
```

Recordings are HEVC `.mov` files, with system audio and mic on separate audio tracks.

## Layout

- `Sources/ReelCore`: capture engine with no UI (`Recorder`, `Screenshotter`, `SaveLocation`, `Preferences`)
- `Sources/reel`: the menu-bar app (toolbar, region and window picker, thumbnail)

## Roadmap

1. ~~Recorder~~ (this)
2. `reel` CLI and an MCP server: `start_recording`, `stop_recording`, `screenshot`, `marker`, so any agent can control the recorder
3. **Demo mode**: describe a demo, Claude operates the Mac with computer use while reel records, then post-processing cuts the agent's thinking pauses, smooths the cursor and zooms in on clicks
