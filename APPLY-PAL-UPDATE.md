# Apply the StreamCapture PAL update

This ZIP contains updated source files, not a prebuilt app. It is based on upstream commit a09f5cd5d026ffbb23838122f100b2215e2e7e81.

1. Back up your existing StreamCapture checkout, especially any local edits.
2. Extract this ZIP into the repository root (the folder containing Package.swift), replacing the matching files. Keep the existing Resources and scripts folders.
3. From that folder run `swift test` and then `./scripts/build-app.sh`.
4. Open `build/StreamCapture.app`. Under What to record > Options, choose the frame-rate standard. PAL is the default: Standard quality targets 25 fps, High targets 50 fps. The previous 30/60 fps option remains available.

Alternatively apply the separately supplied patch to the original commit with `git apply --check /path/to/StreamCapture-PAL-fixes.patch` and `git apply /path/to/StreamCapture-PAL-fixes.patch` instead of extracting this ZIP.

Fixes: reject unavailable selections in Only one app mode; exclude StreamCapture windows during whole-screen recording; report media-writer failures and stop capture; drain FFmpeg pipes continuously with a bounded log; explicitly preserve both audio tracks in FFmpeg video exports.

PAL uses progressive MP4 and targets 25/50 fps. ScreenCaptureKit can deliver frames only as content changes; these are not guaranteed constant-frame-rate broadcast masters. Video conversions retain separate system/microphone tracks rather than mixing them. Audio-only FFmpeg exports still extract the system-audio track.

Validation: six regression tests pass. No screen, microphone, image, video or audio was captured or generated for testing. Live recording and playback still need an on-device check. One pre-existing Swift Sendable warning remains in CaptureEngine. GitHub publishing was blocked by integration permissions and an invalid local GitHub token; upstream has not been changed.
