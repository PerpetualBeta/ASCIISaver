import Foundation

/// Cross-process IPC between the screen saver and the camera agent
/// using Darwin notifications (CFNotificationCenter).
///
/// Darwin notifications work across process boundaries and are not
/// blocked by the legacyScreenSaver sandbox.
enum AgentControlNotifications {

    // MARK: - Notification names (must match on both sides)

    static let startName     = "com.jorviksoftware.ASCIISaver.agent.start"     as CFString
    static let stopName      = "com.jorviksoftware.ASCIISaver.agent.stop"      as CFString
    static let heartbeatName = "com.jorviksoftware.ASCIISaver.agent.heartbeat" as CFString
    static let configChanged = "com.jorviksoftware.ASCIISaver.configChanged"   as CFString

    // MARK: - Posting

    static func postStart() {
        post(startName)
    }

    static func postStop() {
        post(stopName)
    }

    static func postHeartbeat() {
        post(heartbeatName)
    }

    static func postConfigChanged() {
        post(configChanged)
    }

    // MARK: - Observing

    static func observeStart(callback: @escaping () -> Void) {
        observe(name: startName, callback: callback)
    }

    static func observeStop(callback: @escaping () -> Void) {
        observe(name: stopName, callback: callback)
    }

    static func observeHeartbeat(callback: @escaping () -> Void) {
        observe(name: heartbeatName, callback: callback)
    }

    static func observeConfigChanged(callback: @escaping () -> Void) {
        observe(name: configChanged, callback: callback)
    }

    static func removeAll() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(token).toOpaque())
    }

    // MARK: - Internals

    private static let token = TokenObject()
    private final class TokenObject {}

    private static let lock = NSLock()
    private static var handlers: [String: () -> Void] = [:]

    private static func post(_ name: CFString) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil, nil, true
        )
    }

    private static func observe(name: CFString, callback: @escaping () -> Void) {
        let key = name as String

        lock.lock()
        handlers[key] = callback
        lock.unlock()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(token).toOpaque(),
            { _, _, notifName, _, _ in
                guard let cfName = notifName?.rawValue as String? else { return }
                AgentControlNotifications.lock.lock()
                let handler = AgentControlNotifications.handlers[cfName]
                AgentControlNotifications.lock.unlock()
                handler?()
            },
            key as CFString,
            nil,
            .deliverImmediately
        )
    }
}
