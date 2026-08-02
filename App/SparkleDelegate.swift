import AppKit
import Sparkle

/// Keeps Sparkle's update-flow UI in front while a session is in progress.
/// Canonical pattern from the Jorvik KB (conventions/sparkle-integration.md,
/// step 6) — proven on ClipMan and Rainy Day.
///
/// An LSUIElement app has no Dock icon to click, so if a Sparkle sheet ends
/// up behind another window the user has no way to reach it. Three things in
/// combination avoid that:
///   1. Modern activation API (NSApp.activate(ignoringOtherApps:) is
///      deprecated on macOS 14+ and unreliable for accessory apps).
///   2. Promote every visible window to .floating during the session.
///   3. Re-foreground every time a Sparkle window becomes key — the
///      "Ready to Install" sheet has no dedicated delegate hook.
///
/// New to ASCII Saver: as a .saver it had no Sparkle at all, and no appcast.
final class ASCIISaverUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {

    private var sessionObserver: NSObjectProtocol?
    private var elevatedWindows: [(window: NSWindow, originalLevel: NSWindow.Level)] = []

    func standardUserDriverWillShowModalAlert() {
        bringForward()
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        startFocusGuard()
        bringForward()
    }

    func standardUserDriverWillFinishUpdateSession() {
        stopFocusGuard()
    }

    private func bringForward() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        elevateAllWindows()
    }

    private func startFocusGuard() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringForward()
        }
    }

    private func stopFocusGuard() {
        if let obs = sessionObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionObserver = nil
        }
        for entry in elevatedWindows {
            entry.window.level = entry.originalLevel
        }
        elevatedWindows.removeAll()
    }

    private func elevateAllWindows() {
        for window in NSApp.windows where window.isVisible && window.level == .normal {
            elevatedWindows.append((window, window.level))
            window.level = .floating
        }
    }
}
