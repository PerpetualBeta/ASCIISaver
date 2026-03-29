import Foundation
import AVFoundation
import Accelerate
import Vision

final class CameraCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    struct Config {
        let targetWidth: Int
        let targetHeight: Int
        let fps: Int
    }

    struct Frame {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: UnsafeRawPointer
        let timestampNs: UInt64
        let counter: UInt64
        let pixelFormat: SharedFramePixelFormat

        /// Person segmentation mask (width×height bytes, 0=bg, 255=person), or nil
        let maskData: UnsafeRawPointer?
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ASCIISaverCameraAgent.capture")

    private var callback: ((Frame) -> Void)?
    private var frameCounter: UInt64 = 0

    var needsWriterOpen: Bool = true

    private var isConfigured: Bool = false
    private var output: AVCaptureVideoDataOutput?
    private var input: AVCaptureDeviceInput?

    // Downscale target
    private var targetW: Int = 0
    private var targetH: Int = 0

    // Working buffers (reused)
    private var scaledBGRA: [UInt8] = []
    private var lumaScaled: [UInt8] = []

    // Person segmentation
    private var segmentation: PersonSegmentationService?

    /// Whether silhouette mode is active (set by AppDelegate based on user prefs)
    var silhouetteEnabled: Bool = false {
        didSet {
            if silhouetteEnabled && segmentation == nil {
                segmentation = PersonSegmentationService(qualityLevel: .accurate)
            } else if !silhouetteEnabled {
                segmentation = nil
            }
        }
    }

    func start(config: Config, onFrame: @escaping (Frame) -> Void) throws {
        stop()

        callback = onFrame
        frameCounter = 0
        needsWriterOpen = true

        targetW = max(1, config.targetWidth)
        targetH = max(1, config.targetHeight)

        scaledBGRA = [UInt8](repeating: 0, count: targetW * targetH * 4)
        lumaScaled = [UInt8](repeating: 0, count: targetW * targetH)

        session.beginConfiguration()
        session.sessionPreset = .high

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )

        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            throw NSError(domain: "ASCIISaver", code: 10, userInfo: [NSLocalizedDescriptionKey: "No video capture device found"])
        }

        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else {
                session.commitConfiguration()
                throw NSError(domain: "ASCIISaver", code: 11, userInfo: [NSLocalizedDescriptionKey: "Cannot add capture input"])
            }
            session.addInput(newInput)
            input = newInput
        } catch {
            session.commitConfiguration()
            throw error
        }

        let newOutput = AVCaptureVideoDataOutput()
        newOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        newOutput.alwaysDiscardsLateVideoFrames = true
        newOutput.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(newOutput) else {
            session.commitConfiguration()
            throw NSError(domain: "ASCIISaver", code: 12, userInfo: [NSLocalizedDescriptionKey: "Cannot add capture output"])
        }
        session.addOutput(newOutput)
        output = newOutput

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            if !ranges.isEmpty {
                let requested = Double(config.fps)
                let fixed = ranges.filter { abs($0.minFrameRate - $0.maxFrameRate) < 0.0001 }
                let bestFixed = fixed.min(by: { abs($0.maxFrameRate - requested) < abs($1.maxFrameRate - requested) })
                let bestContaining = ranges.first(where: { requested >= $0.minFrameRate && requested <= $0.maxFrameRate })
                let best = bestFixed ?? bestContaining ?? ranges.first

                if let r = best {
                    device.activeVideoMinFrameDuration = r.minFrameDuration
                    device.activeVideoMaxFrameDuration = r.maxFrameDuration
                }
            }
        } catch { }

        session.commitConfiguration()
        isConfigured = true

        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        callback = nil

        queue.sync {
            if self.session.isRunning {
                self.session.stopRunning()
            }

            guard self.isConfigured else {
                self.needsWriterOpen = true
                return
            }

            self.session.beginConfiguration()

            if let out = self.output {
                self.session.removeOutput(out)
            }
            self.output = nil

            if let inp = self.input {
                self.session.removeInput(inp)
            }
            self.input = nil

            self.session.commitConfiguration()

            self.isConfigured = false
            self.needsWriterOpen = true
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let callback = callback,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let tw = targetW
        let th = targetH
        let pixelCount = tw * th

        if scaledBGRA.count != pixelCount * 4 {
            scaledBGRA = [UInt8](repeating: 0, count: pixelCount * 4)
        }
        if lumaScaled.count != pixelCount {
            lumaScaled = [UInt8](repeating: 0, count: pixelCount)
        }

        // Run person segmentation on the FULL-RES buffer BEFORE downscaling
        var maskResult: (ptr: UnsafePointer<UInt8>, width: Int, height: Int)? = nil
        if silhouetteEnabled, let seg = segmentation {
            maskResult = seg.processFrame(
                pixelBuffer: pixelBuffer,
                targetWidth: tw,
                targetHeight: th
            )
        }

        // Downscale BGRA
        var src = vImage_Buffer(data: base, height: vImagePixelCount(srcH), width: vImagePixelCount(srcW), rowBytes: srcRowBytes)

        let scaleOK: Bool = scaledBGRA.withUnsafeMutableBytes { scaledPtr -> Bool in
            var dst = vImage_Buffer(data: scaledPtr.baseAddress!, height: vImagePixelCount(th), width: vImagePixelCount(tw), rowBytes: tw * 4)
            return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
        }
        guard scaleOK else { return }

        // Convert BGRA to luma
        for i in 0..<pixelCount {
            let p = i * 4
            let b = UInt16(scaledBGRA[p])
            let g = UInt16(scaledBGRA[p + 1])
            let r = UInt16(scaledBGRA[p + 2])
            lumaScaled[i] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
        }

        frameCounter &+= 1
        let maskPointer: UnsafeRawPointer? = maskResult.map { UnsafeRawPointer($0.ptr) }
        let ts: UInt64 = DispatchTime.now().uptimeNanoseconds

        lumaScaled.withUnsafeBytes { lumaPtr in
            let frame = Frame(
                width: tw,
                height: th,
                bytesPerRow: tw,
                data: lumaPtr.baseAddress!,
                timestampNs: ts,
                counter: frameCounter,
                pixelFormat: .luma8,
                maskData: maskPointer
            )
            callback(frame)
        }
    }
}
