import Foundation
import CoreGraphics

/// Locks the screen by calling `SACLockScreenImmediate` in
/// `/System/Library/PrivateFrameworks/login.framework`.
///
/// `CGSession -suspend` was removed in macOS 26 — only the header survives.
/// Synthesising `⌃⌘Q` via `CGEvent` is no better: Tahoe consumes the
/// keystroke but loginwindow never receives it, so the lock never happens.
///
/// `SACLockScreenImmediate` is the IPC path loginwindow uses internally, and
/// the canonical approach in Hammerspoon, Bear, and most other menu-bar lock
/// apps. It needs no Accessibility grant, because nothing is being
/// synthesised — loginwindow is simply told to lock.
///
/// Private API caveat: Apple could remove or rename the symbol. The
/// fall-through logs and returns gracefully, and the dismiss flow then
/// proceeds without locking rather than hanging.
enum LockScreen {
    private typealias SACLockFn = @convention(c) () -> Int32

    /// Resolved once at first access and cached for the process lifetime —
    /// the framework and symbol don't change while we're running.
    private static let sacLockScreenImmediate: SACLockFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
              let sym = dlsym(handle, "SACLockScreenImmediate")
        else {
            return nil
        }
        return unsafeBitCast(sym, to: SACLockFn.self)
    }()

    static func lock() {
        guard let fn = sacLockScreenImmediate else {
            asLog("LockScreen: SACLockScreenImmediate unavailable — lock skipped")
            return
        }
        let result = fn()
        asLog("LockScreen: SACLockScreenImmediate → result=\(result)")
    }

    /// Whether the login session is locked **right now**.
    ///
    /// `SACLockScreenImmediate` returns 0 whether it locked the screen or found
    /// it already locked, and `com.apple.screenIsLocked` is posted only on a
    /// *transition*. When the display has already slept — and a Mac set to
    /// require a password immediately locks the session at that moment — the
    /// call succeeds, nothing changes, no notification is posted, and a listener
    /// waiting to be told concludes the lock failed. It did not.
    ///
    /// Measured across Rainy Day, Save Cannes and this app: every lock request
    /// made after the saver had been up longer than the display-sleep timeout
    /// failed to confirm, 19 of 19, going back to May. Under that threshold,
    /// 1.7%. ASCII Saver has never hit it only because it is rarely used.
    ///
    /// `CGSSessionScreenIsLocked` is absent when unlocked rather than
    /// present-and-false, so a missing key means unlocked.
    static var screenIsLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
