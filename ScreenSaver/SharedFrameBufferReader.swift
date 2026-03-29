import Foundation

struct SharedFrameReadResult {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelFormat: SharedFramePixelFormat
    let counter: UInt64
    let timestampNs: UInt64
    let pixelPtr: UnsafeRawPointer
    let maskPtr: UnsafeRawPointer?
}

final class SharedFrameBufferReader {
    private let url: URL

    private var fd: Int32 = -1
    private var mapPtr: UnsafeMutableRawPointer?
    private var mapSize: Int = 0

    private var lastCounter: UInt64 = 0

    init(url: URL = SharedFrameBufferPath.url()) { self.url = url }
    deinit { close() }

    func close() {
        if let mapPtr = mapPtr, mapPtr != MAP_FAILED { munmap(mapPtr, mapSize) }
        mapPtr = nil
        mapSize = 0
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        lastCounter = 0
    }

    private func ensureMapped() -> Bool {
        if mapPtr != nil {
            var st = stat()
            if fstat(fd, &st) == 0 {
                let currentSize = Int(st.st_size)
                if currentSize > mapSize {
                    munmap(mapPtr!, mapSize)
                    mapPtr = mmap(nil, currentSize, PROT_READ, MAP_SHARED, fd, 0)
                    guard let p = mapPtr, p != MAP_FAILED else { close(); return false }
                    mapSize = currentSize
                }
            }
            return true
        }

        fd = Darwin.open(url.path, O_RDONLY)
        if fd < 0 { return false }

        var st = stat()
        if fstat(fd, &st) != 0 { close(); return false }
        let size = Int(st.st_size)
        if size < SharedFrameHeader.size { close(); return false }

        mapPtr = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0)
        guard let mapPtr = mapPtr, mapPtr != MAP_FAILED else { close(); return false }

        mapSize = size
        return true
    }

    func readIfNew() -> SharedFrameReadResult? {
        guard ensureMapped(), let mapPtr = mapPtr else { return nil }

        for _ in 0..<3 {
            let hdr1 = mapPtr.load(as: SharedFrameHeader.self)
            if hdr1.magic != SharedFrameHeader.magic { return nil }
            if hdr1.version < 2 || hdr1.version > 3 { return nil }
            if (hdr1.seq & 1) != 0 { continue }

            let payloadOffset = SharedFrameHeader.size
            let needed = payloadOffset + Int(hdr1.bytesPerRow) * Int(hdr1.height)
            if needed > mapSize { return nil }

            let hdr2 = mapPtr.load(as: SharedFrameHeader.self)
            if hdr1.seq != hdr2.seq { continue }
            if (hdr2.seq & 1) != 0 { continue }

            let counter = hdr2.frameCounter
            if counter == 0 || counter == lastCounter { return nil }
            lastCounter = counter

            let pf = SharedFramePixelFormat(rawValue: hdr2.pixelFormat) ?? .bgra8
            let pixelPtr = UnsafeRawPointer(mapPtr.advanced(by: payloadOffset))

            var maskPtr: UnsafeRawPointer? = nil
            if hdr2.version >= 3 {
                let maskOff = Int(hdr2.maskOffset)
                let hasMaskFlag = (hdr2.flags & SharedFrameHeader.flagMaskPresent) != 0
                if hasMaskFlag && maskOff > 0 {
                    let maskEnd = maskOff + Int(hdr2.width) * Int(hdr2.height)
                    if maskEnd <= mapSize {
                        maskPtr = UnsafeRawPointer(mapPtr.advanced(by: maskOff))
                    }
                }
            }

            return SharedFrameReadResult(
                width: Int(hdr2.width),
                height: Int(hdr2.height),
                bytesPerRow: Int(hdr2.bytesPerRow),
                pixelFormat: pf,
                counter: counter,
                timestampNs: hdr2.timestampNs,
                pixelPtr: pixelPtr,
                maskPtr: maskPtr
            )
        }

        return nil
    }
}
