import Cocoa
import ScreenSaver

@objc(ASCIISaverHostView)
final class ASCIISaverHostView: NSView {

    private let renderView: ASCIIRenderView
    private let isPreview: Bool

    private static let moduleName = "com.jorviksoftware.ASCIISaver"

    @objc init(frame: NSRect, isPreview: Bool) {
        self.isPreview = isPreview
        self.renderView = ASCIIRenderView(frame: frame)
        super.init(frame: frame)

        wantsLayer = true

        renderView.frame = bounds
        renderView.autoresizingMask = [.width, .height]

        renderView.allowCameraFallback = false

        renderView.placeholderEnabled = true
        renderView.placeholderStaleDelaySeconds = isPreview ? 0.35 : 0.75
        renderView.placeholderFadeInSeconds = 0.8

        applyDefaults()

        addSubview(renderView)
    }

    @objc required init?(coder: NSCoder) {
        return nil
    }

    @objc func applyDefaults() {
        guard let defs = ScreenSaverDefaults(forModuleWithName: Self.moduleName) else { return }

        defs.register(defaults: [
            "colourFilter": 0,
            "invertColours": false,
            "fontSize": 9.0,
            "targetFPS": 24.0,
            "rotation": 0,
            "mirrorX": true,
            "mirrorY": false,
            "scanlinesEnabled": true,
            "persistenceEnabled": false,
            "glitchEnabled": false,
            "interferenceEnabled": false
        ])

        defs.synchronize()

        let colourIndex = defs.integer(forKey: "colourFilter")
        switch colourIndex {
            case 1:  renderView.colourFilter = .matrix
            case 2:  renderView.colourFilter = .amber
            case 3:  renderView.colourFilter = .rawFeed
            case 4:  renderView.colourFilter = .silhouette
            default: renderView.colourFilter = .classic
        }

        renderView.invertColours = defs.bool(forKey: "invertColours")

        let fontSize = defs.double(forKey: "fontSize")
        renderView.fontSize = isPreview ? max(6.0, fontSize - 2.0) : CGFloat(fontSize)

        renderView.targetFPS = defs.double(forKey: "targetFPS")

        let rotationIndex = defs.integer(forKey: "rotation")
        switch rotationIndex {
            case 1:  renderView.rotation = .right90
            case 2:  renderView.rotation = .left90
            case 3:  renderView.rotation = .flip180
            default: renderView.rotation = .none
        }

        renderView.mirrorX = defs.bool(forKey: "mirrorX")
        renderView.mirrorY = defs.bool(forKey: "mirrorY")

        renderView.scanlinesEnabled = defs.bool(forKey: "scanlinesEnabled")
        renderView.persistenceEnabled = defs.bool(forKey: "persistenceEnabled")
        renderView.glitchEnabled = defs.bool(forKey: "glitchEnabled")
        renderView.interferenceEnabled = defs.bool(forKey: "interferenceEnabled")

        // Write shared config so the agent can read it (ScreenSaverDefaults is sandboxed)
        let config: [String: Any] = [
            "colourFilter": defs.integer(forKey: "colourFilter"),
            "invertColours": defs.bool(forKey: "invertColours"),
            "fontSize": defs.double(forKey: "fontSize"),
            "targetFPS": defs.double(forKey: "targetFPS"),
            "rotation": defs.integer(forKey: "rotation"),
            "mirrorX": defs.bool(forKey: "mirrorX"),
            "mirrorY": defs.bool(forKey: "mirrorY"),
            "scanlinesEnabled": defs.bool(forKey: "scanlinesEnabled"),
            "persistenceEnabled": defs.bool(forKey: "persistenceEnabled"),
            "glitchEnabled": defs.bool(forKey: "glitchEnabled"),
            "interferenceEnabled": defs.bool(forKey: "interferenceEnabled")
        ]
        let configURL = URL(fileURLWithPath: "/tmp/ASCIISaver/config.plist")
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        (config as NSDictionary).write(to: configURL, atomically: true)
    }

    // MARK: - Lifecycle

    @objc func screensaverDidStart() {
        AgentControlNotifications.postStart()
    }

    @objc func screensaverDidStop() {
        AgentControlNotifications.postStop()
    }
}
