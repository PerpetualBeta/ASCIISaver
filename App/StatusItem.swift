import AppKit

/// Single user-visible touchpoint for the app — a small SF Symbol in the menu
/// bar. Click it for a menu of actions: activate the screensaver immediately,
/// open settings, check for updates, quit.
///
/// This replaces two things at once. The .saver had no UI of its own beyond
/// the System Settings options sheet, and the camera agent had its own,
/// separate status item that existed only to hold the camera permission and
/// be launched at login. One app, one icon.
final class StatusItem {

    private var item: NSStatusItem?
    private weak var appDelegate: AppDelegate?
    /// The Suspend/Resume row, kept so its title can flip in place.
    private var suspendResumeItem: NSMenuItem!

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        configure()
    }

    /// Remove the status item from the menu bar. Called when the user hides
    /// the icon via Settings. Leaves the display-change observer in place
    /// (its `applyIcon` is a no-op once `item` is nil), so a later re-show via
    /// a fresh `StatusItem` rebuilds cleanly.
    func remove() {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func configure() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Persist the item's menu-bar slot across launches (and let a user
        // ⌘-drag stick).
        item.autosaveName = "ASCIISaverStatusItem"
        applyIcon(to: item)

        // Redraw the status icon when the display configuration changes — the
        // menu bar's effective thickness can shrink (e.g. moving from a
        // notched display to an external one) and leave the pre-rendered
        // glyph cropped.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let item = self.item else { return }
            self.applyIcon(to: item)
        }

        // Covers both ways this can change: the menu item below, and the
        // Settings toggle, which writes the UserDefaults key directly rather
        // than going through `toggleActivationSuspended()`.
        NotificationCenter.default.addObserver(
            forName: .activationSuspendedChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshSuspendResumeState()
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "About ASCII Saver",
                     action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Activate Now",
                     action: #selector(activateNow), keyEquivalent: "")
            .target = self
        let suspendResumeItem = menu.addItem(
            withTitle: "", action: #selector(toggleSuspendResume), keyEquivalent: "")
        suspendResumeItem.target = self
        self.suspendResumeItem = suspendResumeItem
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…",
                     action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Check for Updates…",
                     action: #selector(checkForUpdates), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ASCII Saver",
                     action: #selector(quit), keyEquivalent: "q")
            .target = self
        item.menu = menu
        self.item = item
        refreshSuspendResumeState()
    }

    /// Keeps the menu item's title and the status icon in step with
    /// `activationSuspended`, whichever of the two places changed it.
    private func refreshSuspendResumeState() {
        let suspended = appDelegate?.isActivationSuspended() ?? false
        suspendResumeItem?.title = suspended ? "Resume" : "Suspend"
        if let item { applyIcon(to: item) }
    }

    /// SF Symbol — camera viewfinder, the one glyph that says what this thing
    /// points at, or the same frame with the camera gone while suspended.
    /// Template image so the system tints it for the active appearance
    /// (light/dark).
    private func applyIcon(to item: NSStatusItem) {
        guard let button = item.button else { return }
        let suspended = appDelegate?.isActivationSuspended() ?? false
        button.image = suspended ? Self.suspendedIcon() : Self.normalIcon()
        button.image?.isTemplate = true
    }

    private static func normalIcon() -> NSImage? {
        NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ASCII Saver")
    }

    /// One complete glyph Apple already drew, not a composite: Save Cannes
    /// tried compositing a slash over its icon twice, and both looked broken
    /// at menu-bar size. Falls back to the ordinary glyph if the symbol is
    /// ever missing, because a nil image draws nothing, and an app that
    /// vanishes from the menu bar while suspended hides the one state this
    /// icon exists to show.
    private static func suspendedIcon() -> NSImage? {
        NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "ASCII Saver (suspended)")
            ?? NSImage(systemSymbolName: "camera.viewfinder",
                       accessibilityDescription: "ASCII Saver (suspended)")
    }

    @objc private func showAbout() {
        JorvikAboutView.showWindow(
            appName: "ASCII Saver",
            repoName: "ASCIISaver",
            productPage: "screensavers/asciisaver"
        )
    }

    @objc private func toggleSuspendResume() {
        appDelegate?.toggleActivationSuspended()
        refreshSuspendResumeState()
    }

    @objc private func activateNow() {
        appDelegate?.activateNowFromMenu()
    }

    @objc private func openSettings() {
        appDelegate?.openSettings()
    }

    @objc private func checkForUpdates() {
        // Foreground the app so Sparkle's first dialog isn't hidden behind
        // whatever was previously frontmost.
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        appDelegate?.sparkleUpdater.checkForUpdates(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
