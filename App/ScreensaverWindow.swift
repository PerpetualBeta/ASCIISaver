import AppKit

/// Container view that hides the cursor while the mouse is anywhere inside
/// its bounds.
///
/// Three complementary mechanisms — none of them bulletproof on their own
/// under macOS Tahoe (26.x), so all three are layered:
///
/// 1. **Cursor rects** (`resetCursorRects` + `addCursorRect`). The
///    window-server-level mechanism. Works regardless of key-window status,
///    which is critical on a multi-display saver where only one window is
///    ever key.
/// 2. **`.activeAlways` tracking area** with `NSCursor.set()` on
///    enter/move/cursorUpdate. Belt-and-braces for the cursor-rect path.
/// 3. **CG-level hide** via `CGDisplayHideCursor`, fired in
///    `ScreensaverWindow.activate()` after `NSApp.activate(...)` so the
///    LSUIElement app counts as frontmost long enough for the call to stick.
///    Ref-counted; matched by `Show` in `deactivate()`.
///
/// The 16×16 transparent NSCursor needs a genuinely-drawn representation.
/// `NSImage(size:)` alone has zero representations, and NSCursor then
/// materialises a fallback that may not be transparent. `lockFocus` plus an
/// explicit clear fill guarantees a transparent bitmap rep exists.
private final class CursorHidingView: NSView {
    static let invisible: NSCursor = {
        let img = NSImage(size: NSSize(width: 16, height: 16))
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: img.size).fill()
        img.unlockFocus()
        return NSCursor(image: img, hotSpot: .zero)
    }()

    private var trackingArea: NSTrackingArea?

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: Self.invisible)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect,
                      .mouseEnteredAndExited, .mouseMoved,
                      .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        window?.invalidateCursorRects(for: self)
    }

    override func cursorUpdate(with event: NSEvent) { Self.invisible.set() }
    override func mouseEntered(with event: NSEvent) { Self.invisible.set() }
    override func mouseMoved(with event: NSEvent)   { Self.invisible.set() }
}

/// A fullscreen, top-level window covering one display, hosting an
/// `ASCIIRenderView`. Dismisses on any mouse or key event.
///
/// One instance per `NSScreen`. When activated, every `ScreensaverWindow`
/// covers its respective display; together they form a system-wide
/// screensaver effect.
///
/// Composition rather than NSWindow subclassing — NSWindow's required
/// designated initializer signature makes subclassing fiddly, and no window
/// methods need overriding.
final class ScreensaverWindow {

    private let window: NSWindow
    private(set) var renderView: ASCIIRenderView!
    private var eventMonitor: Any?
    private let onDismiss: () -> Void
    let screen: NSScreen

    init(screen: NSScreen, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        self.screen = screen
        // NSWindow's screen: parameter interprets contentRect as RELATIVE to
        // that screen's origin — so passing screen.frame (already in global
        // coords) together with screen: secondaryScreen double-applies the
        // offset and parks the window off-screen. Omit the hint and let the
        // global contentRect place the window itself.
        self.window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Screensaver level — above all normal windows including floating
        // panels. Black and opaque so any letterboxing around the character
        // grid is invisible.
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        configureRenderView()
    }

    private func configureRenderView() {
        let container = CursorHidingView(frame: NSRect(origin: .zero, size: window.frame.size))
        container.wantsLayer = true
        window.contentView = container

        renderView = ASCIIRenderView(frame: container.bounds)
        renderView.autoresizingMask = [.width, .height]
        // The .saver set this false so the sandboxed view never tried to open
        // the camera itself — the agent owned it. This app owns the camera, but
        // the frames still arrive through FrameSource from a single shared
        // capture session rather than one session per display, so the fallback
        // stays off and AppDelegate drives capture.
        renderView.allowCameraFallback = false
        renderView.placeholderEnabled = true
        renderView.placeholderStaleDelaySeconds = 0.75
        renderView.placeholderFadeInSeconds = 0.8

        applySettings()
        container.addSubview(renderView)
        asLog("ScreensaverWindow built for \(screen.localizedName)")
    }

    /// Push the current UserDefaults values onto the render view.
    ///
    /// Replaces `ASCIISaverHostView.applyDefaults()`, which read
    /// ScreenSaverDefaults and then wrote the same values out to
    /// /tmp/ASCIISaver/config.plist so the camera agent could see them. One
    /// process, one source of truth, no plist.
    ///
    /// Reads are safe against unset keys because AppDelegate calls
    /// `register(defaults:)` at launch — otherwise `double(forKey:)` would
    /// return 0 and the grid would try to build with a zero-point font.
    func applySettings() {
        let defs = UserDefaults.standard

        renderView.colourFilter = ASCIIRenderView.ColourFilter(
            rawValue: defs.integer(forKey: "colourFilter")) ?? .classic
        renderView.invertColours = defs.bool(forKey: "invertColours")
        renderView.fontSize = CGFloat(defs.double(forKey: "fontSize"))
        renderView.targetFPS = defs.double(forKey: "targetFPS")
        renderView.rotation = ASCIIRenderView.Rotation(
            rawValue: defs.integer(forKey: "rotation")) ?? .none
        renderView.mirrorX = defs.bool(forKey: "mirrorX")
        renderView.mirrorY = defs.bool(forKey: "mirrorY")
        renderView.scanlinesEnabled = defs.bool(forKey: "scanlinesEnabled")
        renderView.persistenceEnabled = defs.bool(forKey: "persistenceEnabled")
        renderView.glitchEnabled = defs.bool(forKey: "glitchEnabled")
        renderView.interferenceEnabled = defs.bool(forKey: "interferenceEnabled")
    }

    /// The frame sink for this window, handed to AppDelegate so one capture
    /// session can fan out to every display.
    var frameSource: FrameSource { renderView.frameSource }

    func activate() {
        window.makeKeyAndOrderFront(nil)

        // Tahoe tightened cursor-visibility policy — no single mechanism is
        // reliable for an LSUIElement app at .screenSaver level. Activate the
        // app so the CG-level hide counts as frontmost, then hide system-wide.
        // The hide is ref-counted; deactivate() pairs it with a Show.
        NSApp.activate(ignoringOtherApps: true)
        CGDisplayHideCursor(CGMainDisplayID())

        renderView.resumeRendering()

        // Grace period before installing the dismiss monitor. When the user
        // activates via a global hotkey they release the modifiers an instant
        // after the press, and that release would otherwise dismiss the saver
        // we just opened. 600ms is longer than any reasonable key-release and
        // short enough that an intentional dismiss still feels instant.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            // .flagsChanged is intentionally OMITTED. Carbon consumes the
            // keyDown of a global hotkey, but the modifier-up still flows
            // through NSEvent — listening for it would dismiss the saver every
            // time a hotkey is used while it runs.
            self.eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown,
                           .otherMouseDown, .scrollWheel, .keyDown]
            ) { [weak self] event in
                guard let self = self else { return nil }
                // Remove the monitor BEFORE invoking dismiss. One cursor flick
                // generates a burst of mouseMoved events; without this guard
                // each fires onDismiss again, which in the lock-on-dismiss
                // path means N parallel lock attempts. Observed on Rainy Day:
                // 13 locks from a single movement.
                if let m = self.eventMonitor {
                    NSEvent.removeMonitor(m)
                    self.eventMonitor = nil
                }
                self.onDismiss()
                return nil   // swallow — we're dismissing
            }
        }
    }

    func deactivate() {
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
        // Match the CGDisplayHideCursor from activate(). The hide is
        // ref-counted — an unpaired hide leaves the cursor invisible for
        // everything else the user does afterwards.
        CGDisplayShowCursor(CGMainDisplayID())
        renderView.stopRendering()
        window.orderOut(nil)
    }

    /// Halt the render loop without tearing the window down. Used while the
    /// system lock screen covers us — the saver is invisible under
    /// loginwindow, so there is no point running the camera for it.
    func pauseAnimation() {
        renderView.pauseRendering()
    }
}
