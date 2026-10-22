<p align="center"><img src="docs/assets/app-icon.png" width="96" height="96" alt="HuiSheng icon"></p>
<h1 align="center">HuiSheng · 会声</h1>
<p align="center">A local meeting audio recorder for macOS.</p>
<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

Record meeting audio and your microphone together, then save a playable M4A file on your Mac. HuiSheng uses native macOS audio capture and runs without an account, cloud service, API key, or virtual audio driver.

**Early preview:** the current app interface is in Simplified Chinese. Both English and Chinese documentation are available. The app records audio only; transcription, summaries, and screen recording are not included.

## Features

- Capture all system audio or select a running application.
- Include your default microphone, with separate input level indicators.
- Pause and resume without leaving a pause-length gap in the saved recording.
- Save a mixed M4A file and keep original audio tracks for recovery.
- Browse, search, play, and reveal recordings in Finder.
- Control an active recording from the menu bar while the main window is closed.
- Choose a local storage folder; no audio is uploaded by the app.

## Requirements

| Item | Requirement |
| --- | --- |
| Operating system | macOS 15 or later |
| Downloadable build | Apple Silicon / arm64 |
| Permissions | Screen & System Audio Recording; Microphone if enabled |
| Building from source | Apple Command Line Tools or Xcode with Swift 6+ |

The initial build was tested on macOS 26.5.2 with Swift 6.3.3. Earlier supported macOS versions and Intel Macs have not been tested.

## Install

Download `HuiSheng-v0.1.0-macOS-arm64.zip` from the [v0.1.0 preview release](https://github.com/chenxiachan/HuiSheng/releases/tag/v0.1.0), unzip it, and move `会声.app` to Applications.

This preview is ad-hoc signed and **not notarized by Apple**. macOS may block a downloaded build; building from source is the alternative for this release.

## Record a meeting

1. Open your meeting client and join the meeting.
2. In HuiSheng, choose **全部系统声音** (all system audio), or select the meeting application.
3. Turn **录入我的声音** (include my microphone) on or off before recording.
4. Click **开始录音** (start). Allow the requested permissions in **System Settings → Privacy & Security**. If capture still fails after permission is granted, quit and reopen HuiSheng.
5. Check the meeting and microphone level indicators. Pause or resume as needed, then click **结束并保存** (stop and save).

Recordings are saved to `~/Movies/会声` by default. Change the destination in the recording panel or settings. Each meeting has its own folder with a final `.m4a` file, original tracks, and `session.json` metadata. The library shows recordings in the selected storage folder.

| Shortcut | Action |
| --- | --- |
| `⌘ ⇧ R` | Start / stop and save |
| `⌘ ⇧ P` | Pause / resume |
| `⌘ ⇧ O` | Open the recording folder |

## Tencent Meeting, Teams, Zoom, and browser meetings

HuiSheng captures audio through Apple's **ScreenCaptureKit**. It does not require a meeting plugin or use the conferencing service's cloud recording API. The intended capture path for Tencent Meeting, VooV Meeting, Microsoft Teams, Zoom, and browser meetings is the audio they play on the Mac.

- **All system audio** also includes music, notifications, and other applications.
- **Application mode** filters the selected app and helper processes with matching bundle-ID prefixes. Some clients route audio through other processes; if the meter stays silent, try all system audio.
- For a web meeting, select the **browser**. Individual browser tabs cannot be isolated.

Real calls in Tencent Meeting, Teams, and Zoom have **not yet been individually verified**. Check both audio meters and make a short test recording before relying on the app for a meeting.

## Recording behavior and privacy

- Tell participants before recording. HuiSheng does not send an in-meeting recording notification.
- Use headphones to avoid capturing speaker audio again through the microphone. Acoustic echo cancellation is not included.
- **The meeting client's mute button does not mute HuiSheng's microphone.** Disable microphone capture in HuiSheng before starting if you only want the meeting audio.
- Keep the Mac awake with its lid open. Sleep, permission changes, and audio-device changes may interrupt capture; check the meters after switching devices.
- Audio processing and file export happen locally. If you choose a folder synchronized by iCloud, Dropbox, or another service, that service may sync the files independently.
- Starting requires about 512 MiB of free space. The app attempts to stop and save if available space drops below about 100 MiB. Export also requires additional space.
- Original tracks remain after export, so storage use exceeds the final M4A size. Manage files in Finder.
- After an interruption, **恢复导出** (recover export) can attempt to rebuild a recording from readable original tracks. Recovery after a crash or power loss is not guaranteed.

## Build from source

```bash
git clone https://github.com/chenxiachan/HuiSheng.git
cd HuiSheng
bash scripts/build-app.sh "$PWD/dist/会声.app"
open "dist/会声.app"
```

The script builds the Swift package in release mode, generates the app icon, creates the app bundle, and applies an ad-hoc signature. There are no third-party package dependencies. `HUISHENG_BUILD_DIR` can override the default `.build` directory.

## Run verification

```bash
bash scripts/test.sh
```

The standalone runner works with Command Line Tools; a full Xcode installation is not required. It uses synthetic audio and does not access the microphone or screen. Five checks cover:

1. Pause removal and rejection of stale samples.
2. A pause before the first audio sample.
3. Safe recording filenames and duration formatting.
4. Encoding, mixing, export, and decoding of 48 kHz stereo and delayed 44.1 kHz mono inputs, with frequency checks before and after a pause.
5. Empty-input export failure without a final output file.

Test artifacts are written to `.test-output/`, or the directory set by `HUISHENG_TEST_OUTPUT_DIR`. Long meetings, audio-device hot-swapping, sleep, and crash recovery still need broader real-world testing.

## How it works

`ScreenCaptureKit → separate AAC tracks → shared timeline → local M4A mix`

SwiftUI and AppKit provide the interface and menu-bar controls. A serial media queue handles capture, pause, and stop operations. AVAssetWriter encodes separate system and microphone tracks; AVMutableComposition and AVAudioMix export the final recording. With two audio tracks, each uses a gain of 0.5 to leave mixing headroom.

Original tracks use fragmented MOV containers. Final exports are written to a temporary file before being moved into place; session metadata is written atomically. In audio-only mode, screen samples are discarded and never passed to a file writer.

See Apple's [ScreenCaptureKit documentation](https://developer.apple.com/documentation/screencapturekit) and [microphone capture walkthrough](https://developer.apple.com/videos/play/wwdc2024/10088/) for the underlying APIs.
