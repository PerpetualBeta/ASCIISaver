import Foundation

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
}
