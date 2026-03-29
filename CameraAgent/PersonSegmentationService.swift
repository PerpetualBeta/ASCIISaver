import Foundation
import Vision
import Accelerate

final class PersonSegmentationService {

    private let qualityLevel: VNGeneratePersonSegmentationRequest.QualityLevel

    private lazy var request: VNGeneratePersonSegmentationRequest = {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = qualityLevel
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return req
    }()

    private var maskBuffer: [UInt8] = []
    private var prevMask: [UInt8] = []
    private var maskWidth: Int = 0
    private var maskHeight: Int = 0
    private var hasPrevious: Bool = false

    init(qualityLevel: VNGeneratePersonSegmentationRequest.QualityLevel = .accurate) {
        self.qualityLevel = qualityLevel
    }

    func processFrame(pixelBuffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) -> (ptr: UnsafePointer<UInt8>, width: Int, height: Int)? {

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let result = request.results?.first else { return nil }
        let maskPixelBuffer = result.pixelBuffer

        let maskW = CVPixelBufferGetWidth(maskPixelBuffer)
        let maskH = CVPixelBufferGetHeight(maskPixelBuffer)

        CVPixelBufferLockBaseAddress(maskPixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskPixelBuffer, .readOnly) }

        guard let maskBase = CVPixelBufferGetBaseAddress(maskPixelBuffer) else { return nil }
        let maskBytesPerRow = CVPixelBufferGetBytesPerRow(maskPixelBuffer)
        let srcMask = maskBase.assumingMemoryBound(to: UInt8.self)

        let needed = targetWidth * targetHeight
        if maskBuffer.count != needed || maskWidth != targetWidth || maskHeight != targetHeight {
            maskBuffer = [UInt8](repeating: 0, count: needed)
            prevMask = [UInt8](repeating: 0, count: needed)
            maskWidth = targetWidth
            maskHeight = targetHeight
            hasPrevious = false
        }

        // Bilinear scale from Vision mask to target dimensions
        maskBuffer.withUnsafeMutableBufferPointer { outBuf in
            for y in 0..<targetHeight {
                let srcYf = Float(y) * Float(maskH) / Float(targetHeight)
                let sy0 = min(maskH - 1, Int(srcYf))
                let sy1 = min(maskH - 1, sy0 + 1)
                let fy = srcYf - Float(sy0)

                for x in 0..<targetWidth {
                    let srcXf = Float(x) * Float(maskW) / Float(targetWidth)
                    let sx0 = min(maskW - 1, Int(srcXf))
                    let sx1 = min(maskW - 1, sx0 + 1)
                    let fx = srcXf - Float(sx0)

                    let p00 = Float(srcMask[sy0 * maskBytesPerRow + sx0])
                    let p10 = Float(srcMask[sy0 * maskBytesPerRow + sx1])
                    let p01 = Float(srcMask[sy1 * maskBytesPerRow + sx0])
                    let p11 = Float(srcMask[sy1 * maskBytesPerRow + sx1])

                    let top = p00 + (p10 - p00) * fx
                    let bot = p01 + (p11 - p01) * fx
                    let val = top + (bot - top) * fy

                    outBuf[y * targetWidth + x] = UInt8(min(255, max(0, val)))
                }
            }
        }

        // Aggressive confidence curve — crush low values, boost high values
        for i in 0..<needed {
            let raw = Float(maskBuffer[i]) / 255.0
            let steepness: Float = 12.0
            let midpoint: Float = 0.5
            let curved = 1.0 / (1.0 + exp(-steepness * (raw - midpoint)))
            maskBuffer[i] = UInt8(min(255, max(0, curved * 255.0)))
        }

        // Asymmetric temporal smoothing:
        // - Slow to ADD new person pixels (reduces false positives)
        // - Fast to REMOVE person pixels (reduces ghosting)
        if hasPrevious {
            for i in 0..<needed {
                let prev = Float(prevMask[i])
                let curr = Float(maskBuffer[i])
                let blended: Float
                if curr > prev {
                    blended = prev * 0.6 + curr * 0.4
                } else {
                    blended = prev * 0.2 + curr * 0.8
                }
                maskBuffer[i] = UInt8(min(255, max(0, blended)))
            }
        }

        prevMask.withUnsafeMutableBufferPointer { dst in
            maskBuffer.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress!, count: needed)
            }
        }
        hasPrevious = true

        return maskBuffer.withUnsafeBufferPointer { buf in
            (ptr: buf.baseAddress!, width: targetWidth, height: targetHeight)
        }
    }
}
