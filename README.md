# ASCII Saver

A macOS screensaver that renders your live camera feed as ASCII art. Choose from classic green-on-black, Matrix-style, amber terminal, raw camera feed, or iPod-style silhouette modes — each with optional effects like scanlines, phosphor persistence, glitch, and interference.

## Requirements

- macOS 14 (Sonoma) or later
- A built-in or external camera

## Installation

### Using the installer

1. Download `ASCIISaver-Installer.pkg` from the [latest release](https://github.com/PerpetualBeta/ASCIISaver/releases/latest)
2. Double-click to run the installer
3. Follow the prompts — it installs both the screensaver and the camera agent

### Manual installation

1. Copy `ASCIISaver.saver` to `~/Library/Screen Savers/`
2. Copy `ASCIISaverCameraAgent.app` to `/Applications/`

## Getting Started

1. Open **System Settings → Screen Saver** and select **ASCII Saver**
2. Launch **ASCII Saver Camera Agent** from Applications
3. Grant camera permission when macOS prompts
4. Lock your screen or wait for the screensaver to activate

The camera agent appears as a small icon in the menu bar. It only captures when the screensaver is active.

**Tip:** Add the camera agent to **System Settings → General → Login Items** so it starts automatically.

## Colour Filters

| Filter | Description |
|--------|-------------|
| **Classic** | Warm parchment-style ASCII — the default look |
| **Matrix** | Matrix-style bright green with glow effect |
| **Amber** | Warm amber terminal aesthetic with glow |
| **Raw Feed** | Tinted grayscale camera image (not ASCII) |
| **Silhouette** | iPod-style person outline with cycling colours (uses ML person segmentation) |

## Effects

| Effect | Description |
|--------|-------------|
| **Scanlines** | Semi-transparent horizontal lines for a CRT look |
| **Phosphor Persistence** | Previous frame lingers as a fading afterimage |
| **Glitch** | Random pixel offsets for a corruption effect |
| **Interference** | Random static bands and tear lines |

## Configuration

Right-click the screensaver preview in System Settings to open the configuration panel. Options include:

- Colour filter selection
- Font size (8–14pt)
- Target FPS (15–60)
- Rotation (none, 90° CW, 90° CCW, 180°)
- Mirror (horizontal, vertical)
- Colour inversion
- All effects toggles (scanlines, persistence, glitch, interference)

Settings are saved and persist across restarts.

## How It Works

ASCII Saver uses a two-process architecture:

1. **Screensaver** (`.saver` bundle) — renders frames as ASCII art using a CVDisplayLink-driven NSView
2. **Camera Agent** (`.app`) — background process that captures camera frames, converts to grayscale, and writes to shared memory

The two processes communicate via:
- **Darwin notifications** — the screensaver signals start/stop/heartbeat to the agent
- **Memory-mapped file** — the agent writes frames to `/tmp/ASCIISaver/framebuffer.bin` using a seqlock for lock-free synchronisation

The agent optionally runs Vision framework's person segmentation ML model for silhouette mode.

## Uninstalling

Run the uninstall script:

```bash
./Installer/uninstall.sh
```

Or manually remove:
- `~/Library/Screen Savers/ASCIISaver.saver`
- `/Applications/ASCIISaverCameraAgent.app`
- `/tmp/ASCIISaver/`

## Building from Source

Requires Xcode 16+ and an Apple Developer certificate.

```bash
git clone https://github.com/PerpetualBeta/ASCIISaver.git
cd ASCIISaver
./build.sh
```

This builds both targets and outputs:
- `_BuildOutput/ASCIISaver.saver`
- `_BuildOutput/ASCIISaverCameraAgent.app`

To build the installer package:

```bash
./Installer/build_pkg.sh
```

---

ASCII Saver is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
