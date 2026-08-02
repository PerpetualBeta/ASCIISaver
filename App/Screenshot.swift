import AppKit

/// Capture the current ASCII frame. Saves as PNG to
/// `~/Pictures/ASCII Saver/screenshot-TIMESTAMP.png`.
///
/// Rainy Day pulls its screenshot out of a WebGL canvas via
/// `canvas.toDataURL`, which needs `preserveDrawingBuffer` monkey-patched into
/// the page. Nothing so indirect is needed here: the render view is an
/// ordinary AppKit view drawing an attributed string, so
/// `cacheDisplay(in:to:)` gives back exactly what is on screen.
///
/// Called on the main thread from the hotkey handler, while the saver is up.
enum Screenshot {

    /// Capture from the render view of whichever screensaver window the user
    /// is currently looking at; AppDelegate picks it.
    static func capture(from view: NSView) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            asLog("screenshot: view has zero bounds")
            return
        }
        // bitmapImageRepForCachingDisplay honours the view's backing scale, so
        // this comes out at native Retina resolution rather than points.
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            asLog("screenshot: could not create bitmap rep")
            return
        }
        view.cacheDisplay(in: bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            asLog("screenshot: PNG encode failed")
            return
        }
        saveToPicturesFolder(data)
    }

    private static func saveToPicturesFolder(_ pngData: Data) {
        let fm = FileManager.default
        guard let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            asLog("screenshot: no Pictures dir")
            return
        }
        let dir = pictures.appendingPathComponent("ASCII Saver", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "screenshot-\(formatter.string(from: Date())).png"
        let url = dir.appendingPathComponent(filename)

        do {
            try pngData.write(to: url)
            asLog("screenshot: saved \(url.path)")
        } catch {
            asLog("screenshot: write failed \(error.localizedDescription)")
        }
    }
}
