import Foundation

// Diagnostic logging — off by default, enabled per-machine via:
//
//   defaults write cc.jorviksoftware.ASCIISaver debugLogging -bool YES
//   defaults delete cc.jorviksoftware.ASCIISaver debugLogging   # turn off
//
// When on, timestamped lines are appended to
//   ~/Library/Logs/ASCII Saver/asciisaver.log
// (per-user, owner-only directory — not /private/tmp, where a predictable
// filename invites a symlink-target-overwrite by any same-user process.)
// The flag is read once per call so toggling it takes effect on the next
// log line.
//
// Worth noting against the old shape: the .saver wrote its live settings to
// /tmp/ASCIISaver/config.plist so the camera agent could read them. That file
// is gone with the agent, and nothing this app writes lands in /tmp.

private let asLogPath: String = {
    let logs = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("ASCII Saver", isDirectory: true)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return logs.appendingPathComponent("asciisaver.log").path
}()
private let asLogQueue = DispatchQueue(label: "cc.jorviksoftware.ASCIISaver.log")
private let asLogFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func asLog(_ msg: String) {
    guard UserDefaults.standard.bool(forKey: "debugLogging") else { return }
    let line = "\(asLogFmt.string(from: Date()))  \(msg)\n"
    asLogQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        // O_NOFOLLOW: refuse to follow a symlink at this path. Combined with
        // the 0700 parent directory created above, this closes the
        // symlink-attack vector entirely.
        let fd = open(asLogPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
    }
}
