# ASCII Saver architecture

How ASCII Saver is built, and why. For what it does and how to use it, see the [README](README.md).

## Why an app, not a .saver

ASCII Saver needs the camera, and a `.saver` bundle cannot have it.

Screen savers run inside `legacyScreenSaver`, Apple's host process. That host owns the TCC identity, so a saver can never hold a camera permission of its own. Version 1.x worked around this with a second process: `ASCIISaverCameraAgent.app` owned the capture session, converted frames to greyscale, and published them to the saver through a memory-mapped file with a seqlock. Start and stop were Darwin notifications. Settings had to be written out a second time, to a plist in `/tmp`, because `ScreenSaverDefaults` was not visible across the process boundary. The two halves were bound together by an app-group entitlement and shipped as a two-component installer.

All of that existed to work around one restriction. As a regular app there is no restriction: it opens the camera itself, renders in the same process, and the entire IPC layer is gone — along with the agent, the app group, the `/tmp` plist and the multi-component installer.

The trade-off is that it no longer appears in the System Settings screensaver list. You launch it once and it runs from then on. [Rainy Day](https://jorviksoftware.cc/screensavers/rainyday) made the same move first, for different reasons — WebKit is throttled to a standstill inside the screensaver host — and it is now the default shape for Jorvik screensavers.

## Layout

A regular `.app` with `LSUIElement=YES`, signed with the team Developer ID, which polls system idle time and shows an `NSWindow` at `.screenSaver` level on every `NSScreen` when you've been idle past the threshold.

- **App** (`App/`) — lifecycle and idle polling, the screensaver windows, status menu, settings, hotkeys, lock-screen and screenshot integration, the check for another app holding the display awake (`DisplayWake`), the reading of macOS's own screen-saver and display-off timers (`SystemScreenLockSettings`), the Sparkle delegate, and the 1.x settings migration (`Migration`).
- **Render** (`Render/ASCIIRenderView.swift`) — the ASCII renderer, driven by a `CVDisplayLink`. Unchanged in substance from 1.x; only its frame source moved.
- **Camera** (`Camera/`) — `CameraCaptureService` (AVFoundation), `PersonSegmentationService` (Vision), and `FrameSource`, the in-process replacement for the old shared-memory reader.
- **JorvikKit** (`App/JorvikKit/`) — vendored shared components from the Jorvik suite: About modal, Settings frame, hotkey manager and recorders, menu-bar icon visibility, camera permission watcher, localisation shim and window helper.
- **Sparkle** (`Sparkle.framework`) — vendored 2.9.1 binary, embedded under `Contents/Frameworks/`.
