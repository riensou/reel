# reel

**An open-source screen recorder for macOS.**

reel is a free menu-bar app for screenshots and screen recordings, built on ScreenCaptureKit. It keeps the system tool's flow (a floating thumbnail that drops the file into your screenshots folder) and adds audio/mic controls with live level meters, MP4 output, trimming, and optional demo effects: keystrokes, webcam bubble, auto-zoom and a smoothed cursor.

## Install

```sh
scripts/make-dev-cert.sh   # once: a local signing identity so permissions survive rebuilds
scripts/install.sh         # builds a release build into /Applications and launches it
```

During development, `scripts/run.sh` builds and relaunches from `build.noindex/`.

The first time it runs, macOS asks for **Screen & System Audio Recording** permission. Features you turn on may also need Microphone, Camera, or Accessibility (for keystrokes). **Settings → Permissions** shows the status of each one.

## Use

- **⌘⇧6** opens the toolbar. While recording, it stops the recording. You can change the shortcut in Settings.
- **Toolbar:** Screen / Window / Region · Screenshot / Record · system audio, mic and webcam (Record mode only) · cursor · Options · **Capture**. The audio buttons light up with the live level before you record.
- **Region:** your last region is preselected. Drag inside it to move it, drag the handles to resize, Enter to confirm, Esc to cancel.
- **While recording:** click the menu bar timer to stop. Right-click it for Pause/Resume, Stop and Cancel.
- **Thumbnail:** click to open, drag into any app, swipe to dismiss. Right-click for Trim…, Export GIF, Export as MOV/MP4, Copy, Show in Finder and Delete. If you leave it, the file saves after 5 seconds.

## Settings and config file

Settings (menu bar → **Settings…**) and a plain-text config file are two views of the same preferences. Like ghostty, the file is `~/.config/reel/config` (or `$XDG_CONFIG_HOME/reel/config`). reel reloads it whenever you save it, and the Settings window edits it in place, so your comments survive. Mistakes show up as a toast with the line number.

```ini
save-directory = system          # system | ~/path
video-format = mp4               # mp4 | mov
video-codec = auto               # auto (H.264 ≤ 4096 px, else HEVC) | h264 | hevc
fps = 60
merge-audio-tracks = true        # one audio track that plays everywhere
thumbnail = true
thumbnail-duration = 5
hotkey = cmd+shift+6
launch-at-login = false
countdown = 0                    # 3-2-1 before recording; 0 = off
recording-border = false         # outline the recorded area (never in the video)
show-keystrokes = off            # off | shortcuts | all
webcam = false                   # adds a camera toggle to the toolbar
webcam-size = medium             # small | medium | large
webcam-shape = circle            # circle | rounded
auto-zoom = false                # zoom in on clicks after recording
auto-zoom-scale = 1.8
smooth-cursor = false            # redraw the cursor along a smoothed path
```

Which mode you last used, the toolbar toggles and your last regions are session state, not preferences. They're remembered separately.

Auto-zoom and smooth cursor are applied after you stop, which means re-encoding the video. The thumbnail shows progress while that runs; on Apple silicon it takes a fraction of the recording's length.

## Headless

```sh
reel --shot out.png
reel --record 10 out.mp4 --system-audio --mic --no-cursor
```

(`reel` here is `build.noindex/reel.app/Contents/MacOS/reel`; it captures the main display.)

## Layout

- `Sources/ReelCore`: the engine, with no UI.
  - `Recorder`: ScreenCaptureKit, plus pause/resume as separate segments.
  - `Finisher`: joins the segments, mixes the audio, applies effects.
  - `Config`, `ConfigFile`: parsing, in-place edits, file watching.
  - `CursorTrack`, `ZoomTimeline`, `DemoEffects`: auto-zoom and the smoothed cursor.
  - `VideoExport`: trim, remux and GIF.
- `Sources/reel`: the menu-bar app.
  - Toolbar.
  - Overlays: region picker, border, countdown, keystrokes, webcam.
  - Thumbnail.
  - Settings.
  - Toasts.
- `Tests/ReelCoreTests`: run with `swift test`.

## Roadmap

1. ~~Recorder~~
2. ~~Polish: settings, config, MP4, trim/GIF, demo effects~~
3. A `reel` CLI and MCP server so agents can drive the recorder.
4. **Demo mode:** describe a demo; Claude operates the Mac with computer use while reel records and polishes it.
