# ASCII Saver

A macOS screensaver that renders your live camera feed as ASCII art. Choose from classic green-on-black, Matrix-style, amber terminal, raw camera feed, or iPod-style silhouette modes — each with optional effects like scanlines, phosphor persistence, glitch, and interference.

As of 2.0 it ships as a regular `.app` rather than a `.saver` bundle. See [Why an app, not a .saver](#why-an-app-not-a-saver), and [Upgrading from 1.x](#upgrading-from-1x) if you used an earlier version.

## Requirements

- macOS 14 (Sonoma) or later
- A built-in or external camera
- Universal binary (Apple silicon and Intel)

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/ASCIISaver/releases/latest/download/ASCIISaver.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places `ASCII Saver.app` in `/Applications/` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/ASCIISaver/releases/latest)** — unzip and drag `ASCII Saver.app` to your `/Applications/` folder.

Or install it with [Homebrew](https://brew.sh):

```sh
brew install --cask perpetualbeta/jorvik/asciisaver
```

## Getting Started

1. Launch **ASCII Saver** once from your Applications folder
2. Grant camera access when macOS prompts — nothing works without it
3. A small **camera viewfinder** icon appears in the menu bar. That's your only touchpoint with the app; everything else lives in its menu and its **Settings…** window
4. Choose **Activate Now** from that menu to see it immediately, or leave the Mac idle past your configured timeout. To stop it activating for a while, choose **Suspend** from the same menu; the icon changes to an empty viewfinder until you choose **Resume**

Move the mouse or press any key to dismiss.

The app does not add itself to your login items automatically — turn on **Launch at Login** in Settings → General if you want it running after a restart.

## Upgrading from 1.x

Version 2.0 is the same screensaver, delivered differently. Three things change for existing users:

- **You'll be asked for camera access again.** The bundle identifier moved from `com.jorviksoftware.ASCIISaver` to `cc.jorviksoftware.ASCIISaver`, and macOS keys permissions to the identifier. There is no way to transfer a TCC grant between identities, so the prompt is unavoidable.
- **It no longer appears in System Settings → Screen Saver.** It is not a `.saver` any more. Launch the app instead; it takes over the screen on idle exactly as before.
- **Your settings carry over.** Colour filter, character size, frame rate, rotation, mirroring and all four effects are migrated on first launch.

The old install is not removed for you. To clean it up:

```sh
sudo rm -rf "/Library/Screen Savers/ASCIISaver.saver" "$HOME/Library/Screen Savers/ASCIISaver.saver" \
            "/Applications/ASCIISaverCameraAgent.app"
sudo pkgutil --forget com.jorviksoftware.ASCIISaver.saver
sudo pkgutil --forget com.jorviksoftware.ASCIISaver.agent
```

## Why an app, not a .saver

ASCII Saver needs the camera, and a `.saver` bundle cannot have it.

Screen savers run inside `legacyScreenSaver`, Apple's host process. That host owns the TCC identity, so a saver can never hold a camera permission of its own. Version 1.x worked around this with a second process: `ASCIISaverCameraAgent.app` owned the capture session, converted frames to greyscale, and published them to the saver through a memory-mapped file with a seqlock. Start and stop were Darwin notifications. Settings had to be written out a second time, to a plist in `/tmp`, because `ScreenSaverDefaults` was not visible across the process boundary. The two halves were bound together by an app-group entitlement and shipped as a two-component installer.

All of that existed to work around one restriction. As a regular app there is no restriction: it opens the camera itself, renders in the same process, and the entire IPC layer is gone — along with the agent, the app group, the `/tmp` plist and the multi-component installer.

The trade-off is that it no longer appears in the System Settings screensaver list. You launch it once and it runs from then on. [Rainy Day](https://jorviksoftware.cc/screensavers/rainyday) made the same move first, for different reasons — WebKit is throttled to a standstill inside the screensaver host — and it is now the default shape for Jorvik screensavers.

## Colour Filters

| Filter | Description |
|--------|-------------|
| **Classic** | Warm parchment-style ASCII — the default look |
| **Matrix** | Matrix-style bright green with glow effect |
| **Amber** | Warm amber terminal aesthetic with glow |
| **Raw Feed** | Tinted greyscale camera image (not ASCII) |
| **Silhouette** | iPod-style person outline with cycling colours (uses ML person segmentation) |

## Effects

| Effect | Description |
|--------|-------------|
| **Scanlines** | Semi-transparent horizontal lines for a CRT look |
| **Phosphor Persistence** | Previous frame lingers as a fading afterimage |
| **Glitch** | Random pixel offsets for a corruption effect |
| **Interference** | Random static bands and tear lines |

## Configuration

Click the menu bar icon → **Settings…**:

- **Permissions** — camera status, with a button to grant it or to open System Settings if you've previously declined
- **Activation** — a **Suspended** toggle that mirrors the menu's Suspend/Resume, the idle timeout in minutes, and a global "Activate now" hotkey. If one of macOS's own timers ("Start Screen Saver when inactive", or "Turn display off when inactive") is set at or under the idle timeout, an orange note under the idle timeout says which one, because ASCII Saver would never get a turn.
- **On dismiss** — lock the screen automatically when the saver dismisses
- **Capture** — a global hotkey that saves the current frame as a PNG to `~/Pictures/ASCII Saver/`
- **Picture** — colour filter, invert, character size (4–32 pt), frame rate (5–60 fps)
- **Orientation** — rotation (none, 90° right, 90° left, 180°) and horizontal/vertical mirroring
- **Effects** — scanlines, phosphor persistence, glitch, interference
- **General** — Launch at Login

Settings apply immediately to a running saver — no Save button, and no need to restart.

## Auto-update

ASCII Saver 2.0 uses [Sparkle 2.x](https://sparkle-project.org/) for auto-update, checked daily against `https://jorviksoftware.cc/appcasts/asciisaver.xml`. Trigger a manual check from the menu's **Check for Updates…** item.

Version 1.x had no update mechanism at all — a `.saver` has no process of its own in which to run one. This is new.

Updates are EdDSA-signed; your copy will only install genuine Jorvik Software releases.

## Privacy

This app looks at your camera, so it is worth being precise about what it does with it.

- **The camera runs only while the saver is on screen.** It is opened when the saver activates and closed when it dismisses. Idle in the menu bar, the app holds no camera session at all.
- **It is also released the moment the screen locks**, however it was locked: by lock-on-dismiss, Lock Now, a hot corner or closing the lid. The same happens when the displays go to sleep. If the display layout changes while the Mac is locked, the saver is not rebuilt, so the camera does not come back on. There is no path by which frames are captured behind a lock screen.
- **It does not start into a video call.** A call holds the display awake, and while anything does, ASCII Saver does not activate, so it never reaches for the camera the call is using. Nor does it start into a display that has gone dark.
- **Nothing is recorded, written to disk, or transmitted.** Frames go from the capture callback to the renderer in memory and are overwritten by the next one. The single exception is the screenshot hotkey, which writes a PNG only when you press it.
- **No telemetry.** No usage reporting, no analytics, and no network traffic beyond Sparkle's appcast fetch. Diagnostic logging is off unless you turn it on with `defaults write cc.jorviksoftware.ASCIISaver debugLogging -bool YES`, and writes only to `~/Library/Logs/ASCII Saver/`.
- **Person segmentation runs on-device**, via Apple's Vision framework, and only when the Silhouette filter is selected.

## Multi-display

Each connected display gets its own fullscreen window, all fed from a single shared capture session — one camera, however many screens. Input on any of them dismisses all of them.

## Architecture

A regular `.app` with `LSUIElement=YES`, signed with the team Developer ID, which polls system idle time and shows an `NSWindow` at `.screenSaver` level on every `NSScreen` when you've been idle past the threshold.

- **App** (`App/`) — lifecycle and idle polling, the screensaver windows, status menu, settings, hotkeys, lock-screen and screenshot integration, and the 1.x settings migration.
- **Render** (`Render/ASCIIRenderView.swift`) — the ASCII renderer, driven by a `CVDisplayLink`. Unchanged in substance from 1.x; only its frame source moved.
- **Camera** (`Camera/`) — `CameraCaptureService` (AVFoundation), `PersonSegmentationService` (Vision), and `FrameSource`, the in-process replacement for the old shared-memory reader.
- **JorvikKit** (`App/JorvikKit/`) — vendored shared components from the Jorvik suite.
- **Sparkle** (`Sparkle.framework`) — vendored 2.9.1 binary, embedded under `Contents/Frameworks/`.

## Building from Source

ASCII Saver builds via the shared Jorvik `release.mk`. With the `jorvik-release` sibling repo cloned alongside it and [GNU Make](https://formulae.brew.sh/formula/make) 4 installed:

- Clone the repo: `git clone https://github.com/PerpetualBeta/ASCIISaver.git`
- Local install (signed with the Jorvik Developer ID): `gmake dev-build`
- Run the freshly-built copy: `gmake run`
- Rebuild the icon from `Resources/AppIcon.iconset`: `gmake icon`
- Signed, notarised, stapled `.zip` + `.pkg` ready to ship: `gmake release`

No Xcode project — the 1.x two-target `.xcodeproj` went with the agent.

---

ASCII Saver is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
