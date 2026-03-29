import Cocoa
import CoreVideo
import QuartzCore

final class ASCIIRenderView: NSView {

    enum Rotation: Int, CaseIterable { case none = 0, right90 = 1, left90 = 2, flip180 = 3 }

    enum ColourFilter: Int, CaseIterable {
        case classic = 0
        case matrix = 1
        case amber  = 2
        case rawFeed = 3
        case silhouette = 4

        var baseColours: (bg: NSColor, fg: NSColor) {
            switch self {
                case .classic:
                    return (
                        bg: NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.91, alpha: 1.0),
                        fg: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.10, alpha: 1.0)
                    )
                case .matrix:
                    return (bg: .black, fg: NSColor(calibratedRed: 0.10, green: 0.90, blue: 0.25, alpha: 1.0))
                case .amber:
                    return (bg: .black, fg: NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.20, alpha: 1.0))
                case .rawFeed:
                    return (bg: .black, fg: .white)
                case .silhouette:
                    return (bg: .black, fg: .black)  // bg cycles; fg is the silhouette colour
            }
        }

        var ramp: [UInt8] {
            switch self {
                case .classic:
                    return Array("@%#*+=-:. ".utf8)
                case .matrix:
                    return Array(#"$@B%8&WM#*oahkbdpqwmZO0QLCJUYXzcvunxrjft/\|()1{}[]?-_+~<>i!lI;:,"^`'. "#.utf8)
                case .amber:
                    return Array("@%#*+=-:. ".utf8)
                case .rawFeed:
                    return Array("@%#*+=-:. ".utf8) // unused for raw feed
                case .silhouette:
                    return Array("█".utf8)  // single solid block character
            }
        }

        var isRawFeed: Bool { self == .rawFeed }
        var isSilhouette: Bool { self == .silhouette }

        var wantsGlow: Bool { self != .classic && self != .rawFeed && self != .silhouette }
        var glowStrength: CGFloat { (self == .matrix) ? 0.55 : ((self == .amber) ? 0.45 : 0.0) }
        var glowRadius: CGFloat { (self == .matrix) ? 3.5 : ((self == .amber) ? 3.0 : 0.0) }

        var scanlineAlpha: CGFloat {
            switch self {
                case .classic:  return 0.04
                case .matrix:   return 0.07
                case .amber:    return 0.06
                case .rawFeed:  return 0.05
                case .silhouette: return 0.0
            }
        }

        var persistenceAlpha: CGFloat {
            switch self {
                case .classic:  return 0.18
                case .matrix:   return 0.24
                case .amber:    return 0.22
                case .rawFeed:  return 0.20
                case .silhouette: return 0.0
            }
        }
    }

    // MARK: - Public options (keep all features)
    var rotation: Rotation = .none
    var mirrorX: Bool = true
    var mirrorY: Bool = false

    var fontSize: CGFloat = 8.0 { didSet { rebuildFont(); recalculateGrid() } }
    var targetFPS: Double = 24.0 { didSet { minFrameInterval = targetFPS > 0 ? (1.0 / targetFPS) : 0 } }

    var colourFilter: ColourFilter = .classic { didSet { applyColoursAndRamp() } }
    var invertColours: Bool = false { didSet { applyColoursAndRamp() } }

    var scanlinesEnabled: Bool = false
    var persistenceEnabled: Bool = false
    var glitchEnabled: Bool = false
    var interferenceEnabled: Bool = false

    // Silhouette mode — iPod-style dancing figure
    private var silhouetteColourIndex: Int = 0
    private var silhouetteColourTimer: CFTimeInterval = 0
    private let silhouetteColourInterval: CFTimeInterval = 4.0  // seconds per colour
    private let silhouettePalette: [NSColor] = [
        NSColor(calibratedRed: 0.85, green: 0.10, blue: 0.50, alpha: 1.0),  // Hot pink
        NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.05, alpha: 1.0),  // Lime green
        NSColor(calibratedRed: 0.10, green: 0.60, blue: 0.95, alpha: 1.0),  // Electric blue
        NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.00, alpha: 1.0),  // Orange
        NSColor(calibratedRed: 0.75, green: 0.15, blue: 0.85, alpha: 1.0),  // Purple
        NSColor(calibratedRed: 1.00, green: 0.85, blue: 0.00, alpha: 1.0),  // Yellow
    ]
    
    /// NEW: set FALSE for screensaver so we never prompt/compete for camera.
    var allowCameraFallback: Bool = true

    /// NEW: placeholder behaviour
    var placeholderEnabled: Bool = true
    var placeholderFadeInSeconds: CFTimeInterval = 0.8
    var placeholderStaleDelaySeconds: CFTimeInterval = 0.75

    // MARK: - Inputs
    private let sharedReader = SharedFrameBufferReader()

    private var displayLink: CVDisplayLink?

    private var latestASCII: NSAttributedString = NSAttributedString(string: "")
    private var previousASCII: NSAttributedString?

    // Raw feed image storage
    private var latestRawImage: CGImage?
    private var previousRawImage: CGImage?

    private let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byClipping
        p.lineSpacing = 0
        p.paragraphSpacing = 0
        p.alignment = .left
        return p
    }()

    private var gridCols: Int = 120
    private var gridRows: Int = 60

    private let stateLock = NSLock()
    private var cachedFont: NSFont = NSFont.monospacedSystemFont(ofSize: 8.0, weight: .regular)
    private var fg: NSColor = .black
    private var bg: NSColor = .white
    private var ramp: [UInt8] = Array("@%#*+=-:. ".utf8)

    private var lastProcessTime: CFTimeInterval = 0
    private var minFrameInterval: CFTimeInterval = 1.0 / 24.0

    // Shared freshness tracking
    private var lastSharedFrameCounter: UInt64 = 0
    private var lastSharedFrameWallTime: CFTimeInterval = 0

    // Placeholder fade state
    private var placeholderAlpha: CGFloat = 0.0
    private var placeholderTargetAlpha: CGFloat = 0.0
    private var placeholderLastTickTime: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        rebuildFont()
        applyColoursAndRamp()
        recalculateGrid()

        startDisplayLink()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true

        rebuildFont()
        applyColoursAndRamp()
        recalculateGrid()

        startDisplayLink()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recalculateGrid()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        recalculateGrid()
    }

    private func startDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let linkUnwrapped = link else { return }
        displayLink = linkUnwrapped

        CVDisplayLinkSetOutputCallback(linkUnwrapped, { (_, _, _, _, _, userInfo) -> CVReturn in
            let view = Unmanaged<ASCIIRenderView>.fromOpaque(userInfo!).takeUnretainedValue()
            view.tick()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())

        CVDisplayLinkStart(linkUnwrapped)
    }

    private func tick() {
        let now = CACurrentMediaTime()

        // throttle
        if minFrameInterval > 0, (now - lastProcessTime) < minFrameInterval { return }
        lastProcessTime = now

        // update placeholder alpha smoothly every tick
        stepPlaceholderAlpha(now: now)

        let isRaw = colourFilter.isRawFeed
        let isSilhouette = colourFilter.isSilhouette

        // Prefer shared LUMA8 frames
        if let shared = sharedReader.readIfNew(),
           shared.pixelFormat == .luma8 {
            lastSharedFrameCounter = shared.counter
            lastSharedFrameWallTime = now

            placeholderTargetAlpha = 0.0

            let lumaPtr = shared.pixelPtr.assumingMemoryBound(to: UInt8.self)

            if isSilhouette {
                // Cycle background colour
                if silhouetteColourTimer == 0 { silhouetteColourTimer = now }
                if (now - silhouetteColourTimer) >= silhouetteColourInterval {
                    silhouetteColourTimer = now
                    silhouetteColourIndex = (silhouetteColourIndex + 1) % silhouettePalette.count
                }

                let maskPtr = shared.maskPtr?.assumingMemoryBound(to: UInt8.self)
                if let img = makeSilhouetteImage(
                    lumaPtr: lumaPtr, maskPtr: maskPtr,
                    width: shared.width, height: shared.height,
                    bytesPerRow: shared.bytesPerRow,
                    bgColour: silhouettePalette[silhouetteColourIndex]
                ) {
                    DispatchQueue.main.async { [weak self] in self?.commitRawFrame(img) }
                }
            } else if isRaw {
                if let img = makeRawImage(lumaPtr: lumaPtr, width: shared.width, height: shared.height, bytesPerRow: shared.bytesPerRow) {
                    DispatchQueue.main.async { [weak self] in self?.commitRawFrame(img) }
                }
            } else {
                if let attr = makeASCII(lumaPtr: lumaPtr, width: shared.width, height: shared.height, bytesPerRow: shared.bytesPerRow) {
                    DispatchQueue.main.async { [weak self] in self?.commitFrame(attr) }
                }
            }
            return
        }

        // No new shared frame
        let sharedIsFresh = (lastSharedFrameCounter > 0) && ((now - lastSharedFrameWallTime) <= placeholderStaleDelaySeconds)
        if sharedIsFresh {
            // Hold last frame; keep placeholder target off until it becomes stale
            placeholderTargetAlpha = 0.0
            return
        }

        // Shared is stale → fade placeholder IN
        if placeholderEnabled {
            placeholderTargetAlpha = 1.0
        }

    }

    private func stepPlaceholderAlpha(now: CFTimeInterval) {
        if placeholderLastTickTime == 0 { placeholderLastTickTime = now }

        let dt = max(0.0, now - placeholderLastTickTime)
        placeholderLastTickTime = now

        let target = placeholderTargetAlpha
        let current = placeholderAlpha

        if abs(target - current) < 0.001 { return }

        let speed = (placeholderFadeInSeconds <= 0) ? 1_000.0 : (1.0 / placeholderFadeInSeconds)
        let delta = CGFloat(dt * speed)

        if target > current {
            placeholderAlpha = min(target, current + delta)
        } else {
            placeholderAlpha = max(target, current - delta)
        }

        DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
    }

    private func commitFrame(_ attr: NSAttributedString) {
        if persistenceEnabled {
            previousASCII = latestASCII
        } else {
            previousASCII = nil
        }
        latestASCII = attr
        latestRawImage = nil  // clear raw image when in ASCII mode
        previousRawImage = nil
        needsDisplay = true
    }

    private func commitRawFrame(_ image: CGImage) {
        if persistenceEnabled {
            previousRawImage = latestRawImage
        } else {
            previousRawImage = nil
        }
        latestRawImage = image
        latestASCII = NSAttributedString(string: "")  // clear ASCII when in raw mode
        previousASCII = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        stateLock.lock()
        let bgLocal = bg
        let fgLocal = fg
        let filterLocal = colourFilter
        stateLock.unlock()

        bgLocal.setFill()
        dirtyRect.fill()

        if filterLocal.isRawFeed || filterLocal.isSilhouette {
            drawRawFeed(bg: bgLocal, fg: fgLocal, filter: filterLocal)
        } else {
            drawASCII(fg: fgLocal, filter: filterLocal)
        }

        if scanlinesEnabled {
            drawScanlines(alpha: filterLocal.scanlineAlpha)
        }

        if interferenceEnabled {
            drawInterference()
        }
        
        if filterLocal.wantsGlow {
            applyGlowIfNeeded(strength: filterLocal.glowStrength, radius: filterLocal.glowRadius)
        } else {
            layer?.shadowOpacity = 0
            layer?.shadowRadius = 0
        }

        // Placeholder overlay on top, faded in
        if placeholderEnabled, placeholderAlpha > 0.001 {
            drawTestCardPlaceholder(alpha: placeholderAlpha)
        }
    }

    private func drawASCII(fg fgLocal: NSColor, filter: ColourFilter) {
        if let prev = previousASCII, persistenceEnabled {
            let alpha = filter.persistenceAlpha
            let faded = NSMutableAttributedString(attributedString: prev)
            faded.addAttribute(.foregroundColor, value: fgLocal.withAlphaComponent(alpha), range: NSRange(location: 0, length: faded.length))
            faded.draw(at: NSPoint(x: 0, y: 0))
        }

        if glitchEnabled {
            let dx = CGFloat(Int.random(in: -3...3))
            let dy = CGFloat(Int.random(in: -2...2))
            latestASCII.draw(at: NSPoint(x: dx, y: dy))
        } else {
            latestASCII.draw(at: NSPoint(x: 0, y: 0))
        }
    }

    private func drawRawFeed(bg bgLocal: NSColor, fg fgLocal: NSColor, filter: ColourFilter) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Draw persistence (previous frame faded)
        if let prev = previousRawImage, persistenceEnabled {
            let alpha = filter.persistenceAlpha
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.interpolationQuality = .none  // nearest-neighbour for pixelated look
            drawImageFilling(ctx: ctx, image: prev)
            ctx.restoreGState()
        }

        // Draw current frame
        if let img = latestRawImage {
            ctx.saveGState()
            if glitchEnabled {
                let dx = CGFloat(Int.random(in: -3...3))
                let dy = CGFloat(Int.random(in: -2...2))
                ctx.translateBy(x: dx, y: dy)
            }
            ctx.interpolationQuality = .none  // nearest-neighbour for pixelated look
            drawImageFilling(ctx: ctx, image: img)
            ctx.restoreGState()
        }
    }

    /// Draw a CGImage scaled to fill the view bounds, maintaining aspect ratio
    private func drawImageFilling(ctx: CGContext, image: CGImage) {
        let viewW = bounds.width
        let viewH = bounds.height
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        guard imgW > 0, imgH > 0, viewW > 0, viewH > 0 else { return }

        // Aspect-fill: scale to fill, then center-crop
        let scaleX = viewW / imgW
        let scaleY = viewH / imgH
        let scale = max(scaleX, scaleY)

        let drawW = imgW * scale
        let drawH = imgH * scale
        let drawX = (viewW - drawW) / 2
        let drawY = (viewH - drawH) / 2

        ctx.draw(image, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
    }

    private func drawScanlines(alpha: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)

        let h = Int(bounds.height)
        for y in stride(from: 0, to: h, by: 2) {
            ctx.fill(CGRect(x: 0, y: CGFloat(y), width: bounds.width, height: 1))
        }
        ctx.restoreGState()
    }

    private func drawInterference() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()

        let w = Int(bounds.width)
        let h = Int(bounds.height)
        guard w > 0, h > 0 else { ctx.restoreGState(); return }

        // Random horizontal bands of static — a few per frame for performance
        let bandCount = Int.random(in: 3...8)
        for _ in 0..<bandCount {
            let bandY = Int.random(in: 0..<h)
            let bandH = Int.random(in: 1...4)
            let alpha = CGFloat.random(in: 0.08...0.25)

            // Each band is a row of random white/black speckles
            for y in bandY..<min(bandY + bandH, h) {
                var x = 0
                while x < w {
                    let runLen = Int.random(in: 1...6)
                    let bright = CGFloat.random(in: 0.0...1.0)
                    ctx.setFillColor(NSColor(white: bright, alpha: alpha).cgColor)
                    ctx.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(runLen), height: 1))
                    x += runLen
                }
            }
        }

        // Occasional full-width horizontal tear line
        if Int.random(in: 0..<4) == 0 {
            let tearY = CGFloat(Int.random(in: 0..<h))
            let tearAlpha = CGFloat.random(in: 0.15...0.4)
            ctx.setFillColor(NSColor.white.withAlphaComponent(tearAlpha).cgColor)
            ctx.fill(CGRect(x: 0, y: tearY, width: CGFloat(w), height: 1))
        }

        ctx.restoreGState()
    }
    
    private func applyGlowIfNeeded(strength: CGFloat, radius: CGFloat) {
        guard let layer = self.layer else { return }
        layer.shadowOpacity = Float(strength)
        layer.shadowRadius = radius
        layer.shadowOffset = .zero
    }

    /// NEW: simple "BBC-ish" test card overlay (vector, not ASCII).
    private func drawTestCardPlaceholder(alpha: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)

        // Soft dark backing so it reads over ASCII
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.fill(bounds)

        let inset: CGFloat = 22
        let card = bounds.insetBy(dx: inset, dy: inset)

        // Outer border
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(card)

        // Top colour bars
        let barH = card.height * 0.22
        let bars = CGRect(x: card.minX, y: card.maxY - barH, width: card.width, height: barH)
        let colours: [NSColor] = [
            .white, .yellow, .cyan, .green, .magenta, .red, .blue
        ]
        let w = bars.width / CGFloat(colours.count)
        for (i, c) in colours.enumerated() {
            ctx.setFillColor(c.withAlphaComponent(0.95).cgColor)
            ctx.fill(CGRect(x: bars.minX + CGFloat(i) * w, y: bars.minY, width: w, height: bars.height))
        }

        // Central circle + crosshair
        let mid = CGPoint(x: card.midX, y: card.midY)
        let radius = min(card.width, card.height) * 0.26

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: mid.x - radius, y: mid.y - radius, width: radius * 2, height: radius * 2))

        ctx.move(to: CGPoint(x: card.minX, y: mid.y))
        ctx.addLine(to: CGPoint(x: card.maxX, y: mid.y))
        ctx.move(to: CGPoint(x: mid.x, y: card.minY))
        ctx.addLine(to: CGPoint(x: mid.x, y: card.maxY))
        ctx.strokePath()

        // Bottom grayscale blocks
        let grayH = card.height * 0.10
        let gray = CGRect(x: card.minX, y: card.minY, width: card.width, height: grayH)
        let steps = 10
        let gw = gray.width / CGFloat(steps)
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps - 1)
            let c = NSColor(calibratedWhite: t, alpha: 0.95)
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: gray.minX + CGFloat(i) * gw, y: gray.minY, width: gw, height: gray.height))
        }

        // Label
        let text = "ASCIISaver — waiting for camera agent"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        s.draw(at: CGPoint(x: card.minX + 10, y: card.minY + grayH + 12))

        ctx.restoreGState()
    }

    private func rebuildFont() {
        stateLock.lock()
        cachedFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        stateLock.unlock()
    }

    private func recalculateGrid() {
        let cellW = max(4.0, fontSize * 0.62)
        let cellH = max(6.0, fontSize * 1.05)

        let cols = max(20, Int(bounds.width / cellW))
        let rows = max(10, Int(bounds.height / cellH))

        stateLock.lock()
        gridCols = cols
        gridRows = rows
        stateLock.unlock()
    }

    private func applyColoursAndRamp() {
        let base = colourFilter.baseColours
        let (bgNew, fgNew) = invertColours ? (base.fg, base.bg) : (base.bg, base.fg)

        stateLock.lock()
        bg = bgNew
        fg = fgNew
        ramp = colourFilter.ramp
        stateLock.unlock()
    }

    private func mapUVToSource(_ u: Double, _ v: Double) -> (Double, Double) {
        var x = u
        var y = v

        if mirrorX { x = 1.0 - x }
        if mirrorY { y = 1.0 - y }

        switch rotation {
            case .none:    return (x, y)
            case .right90: return (y, 1.0 - x)
            case .left90:  return (1.0 - y, x)
            case .flip180: return (1.0 - x, 1.0 - y)
        }
    }

    // MARK: - Raw Feed Image Generation

    /// Create a CGImage from luma data with rotation/mirror/invert applied.
    /// The image is tinted using the current fg colour for non-white foregrounds.
    private func makeRawImage(lumaPtr: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 1, height > 1 else { return nil }

        stateLock.lock()
        let fgLocal = fg
        let bgLocal = bg
        stateLock.unlock()

        // Determine output dimensions (swap for 90° rotations)
        let outW: Int
        let outH: Int
        switch rotation {
        case .right90, .left90:
            outW = height
            outH = width
        default:
            outW = width
            outH = height
        }

        // Get fg/bg colour components for tinting
        let fgR, fgG, fgB: CGFloat
        let bgR, bgG, bgB: CGFloat
        if let fgConverted = fgLocal.usingColorSpace(.deviceRGB) {
            fgR = fgConverted.redComponent
            fgG = fgConverted.greenComponent
            fgB = fgConverted.blueComponent
        } else {
            fgR = 1.0; fgG = 1.0; fgB = 1.0
        }
        if let bgConverted = bgLocal.usingColorSpace(.deviceRGB) {
            bgR = bgConverted.redComponent
            bgG = bgConverted.greenComponent
            bgB = bgConverted.blueComponent
        } else {
            bgR = 0.0; bgG = 0.0; bgB = 0.0
        }

        // Build RGBA pixel buffer with rotation/mirror/tint applied
        var pixels = [UInt8](repeating: 0, count: outW * outH * 4)

        for oy in 0..<outH {
            let v = outH <= 1 ? 0.0 : Double(oy) / Double(outH - 1)
            for ox in 0..<outW {
                let u = outW <= 1 ? 0.0 : Double(ox) / Double(outW - 1)

                let (sxNorm, syNorm) = mapUVToSource(u, v)
                let sx = max(0, min(width - 1, Int(sxNorm * Double(width - 1))))
                let sy = max(0, min(height - 1, Int(syNorm * Double(height - 1))))

                let luma = CGFloat(lumaPtr[sy * bytesPerRow + sx]) / 255.0

                // Lerp between bg and fg based on luma
                let r = UInt8(max(0, min(255, (bgR + (fgR - bgR) * luma) * 255.0)))
                let g = UInt8(max(0, min(255, (bgG + (fgG - bgG) * luma) * 255.0)))
                let b = UInt8(max(0, min(255, (bgB + (fgB - bgB) * luma) * 255.0)))

                let offset = (oy * outW + ox) * 4
                pixels[offset]     = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = 255
            }
        }

        // Create CGImage from pixel buffer
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        return CGImage(
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Create a raw CGImage from a CVPixelBuffer (camera fallback path)
    private func makeRawImage(pixelBuffer pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pb) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)
        else { return nil }

        let srcW = CVPixelBufferGetWidthOfPlane(pb, 0)
        let srcH = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        return makeRawImage(lumaPtr: ptr, width: srcW, height: srcH, bytesPerRow: bytesPerRow)
    }

    // MARK: - ASCII rendering

    private func makeASCII(lumaPtr: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> NSAttributedString? {
        stateLock.lock()
        let cols = gridCols
        let rows = gridRows
        let font = cachedFont
        let rampLocal = ramp
        let fgLocal = fg
        stateLock.unlock()

        if width <= 1 || height <= 1 || cols <= 1 || rows <= 1 { return nil }

        func sampleLuma(_ sx: Int, _ sy: Int, _ dx: Int, _ dy: Int) -> UInt16 {
            let x0 = max(0, min(width - 1, sx))
            let y0 = max(0, min(height - 1, sy))
            let x1 = max(0, min(width - 1, sx + dx))
            let y1 = max(0, min(height - 1, sy + dy))

            let p00 = lumaPtr[y0 * bytesPerRow + x0]
            let p10 = lumaPtr[y0 * bytesPerRow + x1]
            let p01 = lumaPtr[y1 * bytesPerRow + x0]
            let p11 = lumaPtr[y1 * bytesPerRow + x1]
            return (UInt16(p00) + UInt16(p10) + UInt16(p01) + UInt16(p11)) >> 2
        }

        let dx = max(1, width / cols / 2)
        let dy = max(1, height / rows / 2)

        var out = [UInt8]()
        out.reserveCapacity((cols + 1) * rows)

        let rampMax = max(1, rampLocal.count - 1)

        for gy in 0..<rows {
            let v = rows <= 1 ? 0.0 : Double(gy) / Double(rows - 1)
            for gx in 0..<cols {
                let u = cols <= 1 ? 0.0 : Double(gx) / Double(cols - 1)

                let (sxNorm, syNorm) = mapUVToSource(u, v)
                let sx = Int(sxNorm * Double(width - 1))
                let sy = Int(syNorm * Double(height - 1))

                let avg = sampleLuma(sx, sy, dx, dy)
                let idx = Int((UInt32(avg) * UInt32(rampMax)) / 255)
                out.append(rampLocal[idx])
            }
            out.append(0x0A)
        }

        let str = String(decoding: out, as: UTF8.self)
        return NSAttributedString(
            string: str,
            attributes: [
                .font: font,
                .foregroundColor: fgLocal,
                .paragraphStyle: paragraph
            ]
        )
    }

    func makeASCII(pixelBuffer pb: CVPixelBuffer) -> NSAttributedString? {
        // Existing camera fallback path (unchanged)
        stateLock.lock()
        let cols = gridCols
        let rows = gridRows
        let font = cachedFont
        let rampLocal = ramp
        let fgLocal = fg
        stateLock.unlock()

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pb) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)
        else { return nil }

        let srcW = CVPixelBufferGetWidthOfPlane(pb, 0)
        let srcH = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        func sampleLuma(_ sx: Int, _ sy: Int, _ dx: Int, _ dy: Int) -> UInt16 {
            let x0 = max(0, min(srcW - 1, sx))
            let y0 = max(0, min(srcH - 1, sy))
            let x1 = max(0, min(srcW - 1, sx + dx))
            let y1 = max(0, min(srcH - 1, sy + dy))
            let p00 = ptr[y0 * bytesPerRow + x0]
            let p10 = ptr[y0 * bytesPerRow + x1]
            let p01 = ptr[y1 * bytesPerRow + x0]
            let p11 = ptr[y1 * bytesPerRow + x1]
            return (UInt16(p00) + UInt16(p10) + UInt16(p01) + UInt16(p11)) >> 2
        }

        let dx = max(1, srcW / cols / 2)
        let dy = max(1, srcH / rows / 2)

        var out = [UInt8]()
        out.reserveCapacity((cols + 1) * rows)

        let rampMax = max(1, rampLocal.count - 1)

        for gy in 0..<rows {
            let v = rows <= 1 ? 0.0 : Double(gy) / Double(rows - 1)
            for gx in 0..<cols {
                let u = cols <= 1 ? 0.0 : Double(gx) / Double(cols - 1)

                let (sxNorm, syNorm) = mapUVToSource(u, v)
                let sx = Int(sxNorm * Double(srcW - 1))
                let sy = Int(syNorm * Double(srcH - 1))

                let avg = sampleLuma(sx, sy, dx, dy)
                let idx = Int((UInt32(avg) * UInt32(rampMax)) / 255)
                out.append(rampLocal[idx])
            }
            out.append(0x0A)
        }

        let str = String(decoding: out, as: UTF8.self)
        return NSAttributedString(
            string: str,
            attributes: [
                .font: font,
                .foregroundColor: fgLocal,
                .paragraphStyle: paragraph
            ]
        )
    }
    
    /// Render iPod-style silhouette: person = black, background = solid colour
    private func makeSilhouetteImage(
        lumaPtr: UnsafePointer<UInt8>,
        maskPtr: UnsafePointer<UInt8>?,
        width: Int, height: Int, bytesPerRow: Int,
        bgColour: NSColor
    ) -> CGImage? {
        guard width > 1, height > 1 else { return nil }

        let outW: Int
        let outH: Int
        switch rotation {
        case .right90, .left90: outW = height; outH = width
        default: outW = width; outH = height
        }

        let bgR, bgG, bgB: CGFloat
        if let c = bgColour.usingColorSpace(.deviceRGB) {
            bgR = c.redComponent; bgG = c.greenComponent; bgB = c.blueComponent
        } else {
            bgR = 0.85; bgG = 0.10; bgB = 0.50
        }

        let bgRi = Float(bgR * 255)
        let bgGi = Float(bgG * 255)
        let bgBi = Float(bgB * 255)

        // Silhouette colour (dark, almost black)
        let silRi: Float = 0.03 * 255
        let silGi: Float = 0.03 * 255
        let silBi: Float = 0.03 * 255

        var pixels = [UInt8](repeating: 0, count: outW * outH * 4)

        for oy in 0..<outH {
            let v = outH <= 1 ? 0.0 : Double(oy) / Double(outH - 1)
            for ox in 0..<outW {
                let u = outW <= 1 ? 0.0 : Double(ox) / Double(outW - 1)

                let (sxNorm, syNorm) = mapUVToSource(u, v)
                let sx = max(0, min(width - 1, Int(sxNorm * Double(width - 1))))
                let sy = max(0, min(height - 1, Int(syNorm * Double(height - 1))))

                let r, g, b: UInt8
                if let mask = maskPtr {
                    // Continuous blend: 0 = full background, 255 = full silhouette
                    let maskVal = Float(mask[sy * width + sx]) / 255.0
                    let inv = 1.0 - maskVal
                    r = UInt8(min(255, max(0, silRi * maskVal + bgRi * inv)))
                    g = UInt8(min(255, max(0, silGi * maskVal + bgGi * inv)))
                    b = UInt8(min(255, max(0, silBi * maskVal + bgBi * inv)))
                } else {
                    let luma = lumaPtr[sy * bytesPerRow + sx]
                    if luma < 100 {
                        r = UInt8(silRi); g = UInt8(silGi); b = UInt8(silBi)
                    } else {
                        r = UInt8(bgRi); g = UInt8(bgGi); b = UInt8(bgBi)
                    }
                }

                let offset = (oy * outW + ox) * 4
                pixels[offset]     = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        return CGImage(
            width: outW, height: outH,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
