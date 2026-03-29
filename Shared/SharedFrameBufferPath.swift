import Foundation

public enum SharedFrameBufferPath {

    /// Both agent and screen saver use /tmp so the legacyScreenSaver sandbox
    /// can read the framebuffer without App Group entitlements.
    private static let directory = "/tmp/ASCIISaver"

    public static func url() -> URL {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("framebuffer.bin")
    }

    public static func debugDescription() -> String {
        return "final=\(url().path)"
    }
}
