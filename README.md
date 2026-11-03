# StreamCapture

A small Mac app that does the job of QuickTime + BlackHole + Loopback in one place:

- **Records a window or the whole screen with its sound.** Uses Apple's ScreenCaptureKit, so system audio is captured directly. No BlackHole needed.
- **You keep hearing the audio while it records.** Your speakers or headphones play as normal. If your Mac's output is still set to BlackHole, the app warns you and has a one-click button to switch back.
- **Loopback-style monitor.** Optionally send a copy of the recorded sound to any output device (e.g. headphones), with its own volume.
- **Record just one app.** Pick a browser window and only that window's picture and sound get recorded. Notifications and other apps stay out.
- **Live level meters** for system audio and (on macOS 15+) your microphone.
- **PAL frame rates by default:** Standard quality targets 25 fps (up to 1080p); High targets 50 fps (up to 4K). Under Options, switch to 30/60 fps when needed. The frame-rate standard is remembered.
- **Converts recordings** to MP4 (smaller / 720p / HEVC), MOV, WebM, MKV, GIF, M4A, MP3 or WAV.

Only record content you have the rights to record.

## Requirements

- macOS 13 Ventura or newer (microphone mixing needs macOS 15).
- Xcode 16 or newer, or just its Command Line Tools: `xcode-select --install`.
- Optional, for WebM/MKV/GIF/MP3/WAV: `brew install ffmpeg`. Without it you still get MP4, MOV and M4A.

## Build and run

```bash
./scripts/build-app.sh
open build/StreamCapture.app
```

Drag `build/StreamCapture.app` into Applications if you want to keep it.

The first time you press Record, macOS asks for **Screen & System Audio Recording** permission. Allow it in System Settings > Privacy & Security, then quit and reopen the app.

`build-app.sh` signs the app with a stable identity so macOS keeps that permission across rebuilds. It uses `$SIGN_IDENTITY` if set, otherwise your first "Apple Development" certificate, otherwise one named "StreamCapture Local Signing". With none of those it falls back to an ad-hoc signature and warns you; macOS then treats every rebuild as a new app and asks again.

If macOS keeps asking even though the switch is on, the stored permission is from an older build. Reset it, then allow it once more:

```bash
tccutil reset ScreenCapture local.streamcapture.app
```

## Using it

1. Choose **A window** (best for a YouTube tab) or **Whole screen**.
2. Pick the window. Click the refresh button if a window you just opened isn't listed.
3. Press **Record** (or ⇧⌘R). Play the video. Press **Stop**.
4. Recordings appear at the bottom (saved in `~/Movies/StreamCapture` by default). Use **Convert** to make another format; the new file is saved next to the original.

Tips:
- You can switch your Mac's output back to your speakers. The app doesn't use BlackHole.
- Put the video in full screen inside the browser window, or use Whole screen, for the biggest picture.
- If you add your microphone, it's saved as a second audio track.
- Video conversions using ffmpeg retain both audio tracks, including MOV and MKV copies. Players may require you to select the microphone track separately. Audio-only ffmpeg conversions extract the system-audio track.
- PAL here means the 25/50 fps workflow; recordings remain progressive H.264 MP4 files. ScreenCaptureKit delivers frames as content changes, so capture is variable-rate rather than a guaranteed constant-frame-rate broadcast master. Conversion presets keep the source timing (except the 12 fps GIF preset).
- With **Only one app** enabled, an unavailable app must be selected again before recording can start. Whole-screen recording excludes StreamCapture's own windows.
- If saving fails, recording stops and reports the error immediately.

## Project layout

| File | What it does |
| --- | --- |
| `CaptureEngine.swift` | ScreenCaptureKit stream → AVAssetWriter (H.264 + AAC) |
| `AudioSupport.swift` | Output device list, level meter maths, monitor playback |
| `Converter.swift` | Conversion presets (ffmpeg, with AVFoundation fallback) |
| `FFmpegRunner.swift` | Drains conversion output and reports bounded error logs |
| `RecorderModel.swift` | App state, picking sources, starting/stopping |
| `ContentView.swift` | The window |


## Capture diagnostics (updated)

- The recorder checks a small sample of video pixels approximately once per second.
- If sampled frames remain almost entirely black for at least three seconds, a warning appears below the recording status. This is a heuristic: dark scenes and black backgrounds can trigger it.
- Frame counts and dropped-frame counts are periodically written to the macOS unified log using `NSLog` (filter for `StreamCapture`).
- ScreenCaptureKit may intentionally omit DRM-protected content. The diagnostic does not bypass content protection.
- Test using an ordinary, unprotected desktop window before comparing protected playback.

Build on a Mac with Xcode command-line tools: `swift build` or `./scripts/build-app.sh`.

Run regression checks with `swift test`. These exercise PAL/30/60 frame-rate selection, missing-app rejection, video audio-track mappings, and process output/error handling without capturing or generating media.
