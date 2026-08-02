import Foundation

/// Pixel layout of a captured frame.
///
/// Was `SharedFramePixelFormat`, in the deleted Shared/ directory that both
/// the saver and the camera agent compiled. Nothing is shared between
/// processes any more, so the name would have been a lie — see the
/// "misnamed survivor" note on Citadel's GPURaymarch.swift for the same
/// mistake left un-fixed elsewhere.
enum ASCIIPixelFormat: UInt32 {
    case bgra8 = 0
    case luma8 = 1
}

/// One frame, handed to the renderer.
///
/// Deliberately the same shape the renderer already consumed from
/// `SharedFrameBufferReader` — width/height/bytesPerRow/pixelFormat/counter/
/// timestampNs/pixelPtr/maskPtr — so swapping the frame source is a one-line
/// change in ASCIIRenderView rather than surgery on its 900 lines.
struct FrameReadResult {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelFormat: ASCIIPixelFormat
    let counter: UInt64
    let timestampNs: UInt64
    let pixelPtr: UnsafeRawPointer
    let maskPtr: UnsafeRawPointer?
}

/// In-process replacement for `SharedFrameBufferReader`.
///
/// The camera agent used to write frames into an mmap'd file that the saver
/// read back; that existed only because the two lived in separate processes.
/// Now the capture callback and the renderer are in one app, and this class
/// is the whole of what remains: a latest-frame slot with a counter.
///
/// **It still has to copy.** `CameraCaptureService.Frame` hands out pointers
/// into the capture service's own scratch buffers, valid only for the
/// duration of the callback and written on the capture queue. The renderer
/// reads on the display link. Holding the pointer would be a use-after-free
/// with a race on top, so `submit` memcpys into buffers this class owns, under
/// a lock, and `readIfNew` copies back out the same way.
///
/// Two buffers, not one: the renderer can be mid-read while a new frame
/// arrives. Writing into the buffer being read would tear the image.
final class FrameSource {

    private let lock = NSLock()

    private var buffers: [[UInt8]] = [[], []]
    private var maskBuffers: [[UInt8]] = [[], []]
    private var writeIndex = 0

    private var width = 0
    private var height = 0
    private var bytesPerRow = 0
    private var pixelFormat: ASCIIPixelFormat = .luma8
    private var timestampNs: UInt64 = 0
    private var hasMask = false

    /// Monotonic frame counter. The renderer compares it to decide whether a
    /// frame is new, exactly as it did with the shared buffer's counter.
    private var counter: UInt64 = 0
    private var lastReadCounter: UInt64 = 0

    /// Called from the capture queue for every frame.
    func submit(_ frame: CameraCaptureService.Frame) {
        let byteCount = frame.bytesPerRow * frame.height
        guard byteCount > 0 else { return }
        let maskCount = frame.maskData != nil ? frame.width * frame.height : 0

        lock.lock()
        defer { lock.unlock() }

        let slot = writeIndex ^ 1        // write to the buffer nobody just read

        if buffers[slot].count != byteCount {
            buffers[slot] = [UInt8](repeating: 0, count: byteCount)
        }
        buffers[slot].withUnsafeMutableBytes { dst in
            _ = memcpy(dst.baseAddress!, frame.data, byteCount)
        }

        if let mask = frame.maskData, maskCount > 0 {
            if maskBuffers[slot].count != maskCount {
                maskBuffers[slot] = [UInt8](repeating: 0, count: maskCount)
            }
            maskBuffers[slot].withUnsafeMutableBytes { dst in
                _ = memcpy(dst.baseAddress!, mask, maskCount)
            }
            hasMask = true
        } else {
            hasMask = false
        }

        width = frame.width
        height = frame.height
        bytesPerRow = frame.bytesPerRow
        pixelFormat = frame.pixelFormat
        timestampNs = frame.timestampNs
        writeIndex = slot
        counter &+= 1
    }

    // Scratch the reader hands out. Owned for the lifetime of this object and
    // grown in place, never freed per frame.
    //
    // The first version of this allocated a fresh copy per call and freed it
    // with `DispatchQueue.main.async`, on the reasoning that the renderer
    // consumes the frame synchronously so the next runloop turn would be
    // safe. That was wrong, and produced intermittent bands of garbage in the
    // picture: `readIfNew` is called from `tick()`, which CVDisplayLink
    // invokes on **its own thread**, not the main one. The main queue was
    // therefore free to run the deallocation while the display link was still
    // reading the buffer, and whatever allocation next claimed that block got
    // rendered as ASCII.
    private var readBuf: UnsafeMutableRawPointer?
    private var readBufSize = 0
    private var readMaskBuf: UnsafeMutableRawPointer?
    private var readMaskBufSize = 0

    private func ensure(_ buf: inout UnsafeMutableRawPointer?, _ size: inout Int, _ needed: Int) {
        guard size < needed else { return }
        buf?.deallocate()
        buf = UnsafeMutableRawPointer.allocate(byteCount: needed,
                                               alignment: MemoryLayout<UInt8>.alignment)
        size = needed
    }

    /// Called from the display link. Returns nil when no frame has arrived
    /// since the last call, matching the old reader's contract.
    ///
    /// **Lifetime:** the returned pointers stay valid until the next
    /// `readIfNew()` on this instance. That is the same contract the mmap'd
    /// reader offered, and it holds because each render view owns its own
    /// FrameSource and consumes the frame before asking for another.
    func readIfNew() -> FrameReadResult? {
        lock.lock()
        defer { lock.unlock() }

        guard counter != lastReadCounter, width > 0, height > 0 else {
            return nil
        }
        lastReadCounter = counter

        let slot = writeIndex
        let byteCount = bytesPerRow * height
        ensure(&readBuf, &readBufSize, byteCount)
        guard let pixels = readBuf else { return nil }
        buffers[slot].withUnsafeBytes { src in
            _ = memcpy(pixels, src.baseAddress!, byteCount)
        }

        var mask: UnsafeMutableRawPointer?
        if hasMask {
            let maskCount = width * height
            if maskBuffers[slot].count >= maskCount {
                ensure(&readMaskBuf, &readMaskBufSize, maskCount)
                if let m = readMaskBuf {
                    maskBuffers[slot].withUnsafeBytes { src in
                        _ = memcpy(m, src.baseAddress!, maskCount)
                    }
                    mask = m
                }
            }
        }

        return FrameReadResult(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: pixelFormat,
            counter: counter,
            timestampNs: timestampNs,
            pixelPtr: UnsafeRawPointer(pixels),
            maskPtr: mask.map { UnsafeRawPointer($0) }
        )
    }

    deinit {
        readBuf?.deallocate()
        readMaskBuf?.deallocate()
    }

    /// Drop the latest frame so a restarted session doesn't briefly render a
    /// stale image from the previous activation.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        counter = 0
        lastReadCounter = 0
        width = 0
        height = 0
        hasMask = false
    }
}
