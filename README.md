# ASCII Saver

A macOS screensaver that renders your live camera feed as ASCII art. Choose from classic green-on-black, Matrix-style, amber terminal, raw camera feed, or iPod-style silhouette modes — each with optional effects like scanlines, phosphor persistence, glitch, and interference.

As of 2.0 it ships as a regular `.app` rather than a `.saver` bundle. See [Upgrading from 1.x](#upgrading-from-1x) if you used an earlier version, and [ARCHITECTURE.md](ARCHITECTURE.md#why-an-app-not-a-saver) for why.

## Features

- **Your camera, as ASCII art**, live. See [Colour filters](#colour-filters).
- **Five looks**: Classic, Matrix, Amber, Raw Feed and an iPod-style Silhouette.
- **Four effects**: scanlines, phosphor persistence, glitch and interference. See [Effects](#effects).
- **Every display at once**, all from one camera. See [Multiple displays](#multiple-displays).
- **The camera runs only while the saver is on screen**, and is released the moment the screen locks. See [Privacy](#privacy).
- **Stays out of the way.** It won't start during a video call or into a dark display, it can be suspended from the menu bar, and Settings warns you when one of macOS's own timers would beat it.
- **Screenshots** of the current frame from a hotkey. See [Capture](#capture).

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

### First launch

1. Launch **ASCII Saver** once from your Applications folder
2. Grant camera access when macOS prompts — nothing works without it
3. A small **camera viewfinder** icon appears in the menu bar. That's your only touchpoint with the app; everything else lives in its menu and its **Settings…** window

ASCII Saver registers itself for launch at user login on first run; toggle that off in Settings → General if you'd rather start it manually.

### Uninstalling

Quit ASCII Saver from its menu bar icon, then drag `ASCII Saver.app` to the Trash. If you installed it with Homebrew, run this instead:

```sh
brew uninstall --cask perpetualbeta/jorvik/asciisaver
```

### Upgrading from 1.x

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

## Using ASCII Saver

### Starting and stopping

Choose **Activate Now** from the menu bar icon to see it immediately, or leave the Mac idle past your configured timeout. Move the mouse or press any key to dismiss.

To stop it activating for a while, choose **Suspend** from the same menu; the icon changes to an empty viewfinder until you choose **Resume**.

### Multiple displays

Each connected display gets its own fullscreen window, all fed from a single shared capture session — one camera, however many screens. Input on any of them dismisses all of them.

### Colour filters

| Filter | Description |
|--------|-------------|
| **Classic** | Warm parchment-style ASCII — the default look |
| **Matrix** | Matrix-style bright green with glow effect |
| **Amber** | Warm amber terminal aesthetic with glow |
| **Raw Feed** | Tinted greyscale camera image (not ASCII) |
| **Silhouette** | iPod-style person outline with cycling colours (uses ML person segmentation) |

### Effects

| Effect | Description |
|--------|-------------|
| **Scanlines** | Semi-transparent horizontal lines for a CRT look |
| **Phosphor Persistence** | Previous frame lingers as a fading afterimage |
| **Glitch** | Random pixel offsets for a corruption effect |
| **Interference** | Random static bands and tear lines |

## Settings

Click the menu bar icon → **Settings…**. The sections below are in the same order as the window. Settings apply immediately to a running saver — no Save button, and no need to restart.

### Permissions

Camera status, with a button to grant it or to open System Settings if you've previously declined.

### Menu Bar

**Show icon in menu bar** hides the viewfinder status icon while ASCII Saver keeps running. Re-open ASCII Saver from your Applications folder to bring the icon back. *Shown only on macOS 14–15 — on macOS 26 (Tahoe) and later, use System Settings → Menu Bar, which provides this natively.*

### Activation

A **Suspended** toggle that mirrors the menu's Suspend/Resume, the idle timeout in minutes (5 by default), and a global "Activate now" hotkey. If one of macOS's own timers ("Start Screen Saver when inactive", or "Turn display off when inactive") is set at or under the idle timeout, an orange note under the idle timeout says which one, because ASCII Saver would never get a turn.

### On dismiss

Lock the screen automatically when the saver dismisses.

### Capture

A global hotkey that saves the current frame as a PNG to `~/Pictures/ASCII Saver/`.

### Picture

Colour filter, invert, character size (4–32 pt), frame rate (5–60 fps).

### Orientation

Rotation (none, 90° right, 90° left, 180°) and horizontal/vertical mirroring.

### Effects

Scanlines, phosphor persistence, glitch, interference.

### General

**Launch at Login.**

## Privacy

This app looks at your camera, so it is worth being precise about what it does with it.

- **The camera runs only while the saver is on screen.** It is opened when the saver activates and closed when it dismisses. Idle in the menu bar, the app holds no camera session at all.
- **It is also released the moment the screen locks**, however it was locked: by lock-on-dismiss, Lock Now, a hot corner or closing the lid. The same happens when the displays go to sleep. If the display layout changes while the Mac is locked, the saver is not rebuilt, so the camera does not come back on. There is no path by which frames are captured behind a lock screen.
- **It does not start into a video call.** A call holds the display awake, and while anything does, ASCII Saver does not activate, so it never reaches for the camera the call is using. Nor does it start into a display that has gone dark.
- **Nothing is recorded, written to disk, or transmitted.** Frames go from the capture callback to the renderer in memory and are overwritten by the next one. The single exception is the screenshot hotkey, which writes a PNG only when you press it.
- **No telemetry.** No usage reporting, no analytics, and no network traffic beyond Sparkle's appcast fetch. Diagnostic logging is off unless you turn it on with `defaults write cc.jorviksoftware.ASCIISaver debugLogging -bool YES`, and writes only to `~/Library/Logs/ASCII Saver/`.
- **Person segmentation runs on-device**, via Apple's Vision framework, and only when the Silhouette filter is selected.

## Auto-update

ASCII Saver 2.0 uses [Sparkle 2.x](https://sparkle-project.org/) for auto-update, checked daily against `https://jorviksoftware.cc/appcasts/asciisaver.xml`. Trigger a manual check from the menu's **Check for Updates…** item.

Version 1.x had no update mechanism at all — a `.saver` has no process of its own in which to run one. This is new.

Updates are EdDSA-signed; your copy will only install genuine Jorvik Software releases.

## How it works

Why ASCII Saver is an app rather than a `.saver`, and how the camera, renderer and windows fit together, are in [ARCHITECTURE.md](ARCHITECTURE.md).

## Building from Source

The build is driven by the shared [`release.mk`](https://github.com/PerpetualBeta/jorvik-release) Make include, so `jorvik-release` has to be checked out **beside this repo** — the Makefile looks for it at `../jorvik-release/`. macOS ships GNU Make 3.81 as `make`, which is too old, so `gmake` comes from [Homebrew](https://brew.sh).

```bash
brew install make   # GNU Make 4+, if you do not already have gmake
git clone https://github.com/PerpetualBeta/jorvik-release.git
git clone https://github.com/PerpetualBeta/ASCIISaver.git
cd ASCIISaver
gmake build
open ".build/ASCII Saver.app"
```

Other targets:

- `gmake dev-build` — local build signed with the Jorvik Developer ID
- `gmake run` — run the freshly-built copy
- `gmake icon` — rebuild the icon from `Resources/AppIcon.iconset`
- `gmake release` — signed, notarised, stapled `.zip` and `.pkg` ready to ship

No Xcode project — the 1.x two-target `.xcodeproj` went with the agent.

## The other Jorvik screensavers

- **[Rainy Day](https://jorviksoftware.cc/screensavers/rainyday)** — raindrops gather on a pane of glass and slip down it, refracting the photograph behind them. The app that established this shape.
- **[Save Cannes](https://jorviksoftware.cc/screensavers/savecannes)** — plays your own films, photographs and live streams, on every display or on just one.
- **[Reverie](https://jorviksoftware.cc/screensavers/reverie)** — roulette curves drawn progressively in dark ink over an animated wavescape. Still a `.saver` bundle, and rightly so: it needs no permission for anything, so it has no reason to be an app.

---

ASCII Saver is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
