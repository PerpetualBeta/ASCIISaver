import AppKit

// ASCII Saver — a camera-to-ASCII screensaver delivered as a regular .app
// rather than a .saver bundle.
//
// Why an app, not a saver: this product needs the camera, and a .saver runs
// inside legacyScreenSaver, which cannot hold its own TCC grant. The old
// shape worked around that with a second process — ASCIISaverCameraAgent —
// that owned the camera and shipped frames to the saver through a shared
// memory buffer, with settings round-tripped via a plist in /tmp because
// ScreenSaverDefaults was not visible across the process boundary. A regular
// .app simply asks for the camera and renders in the same process.
//
// The trade-off is that ASCII Saver no longer appears in System Settings'
// screensaver list — launch the app once and it auto-runs at login from then
// on. See kb/conventions/screensaver-as-app.md.

let app = NSApplication.shared
// .accessory == LSUIElement: no Dock icon, no menu bar, no app switcher
// entry. The user never sees the app itself; only the screensaver window
// when idle, and the status item.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
