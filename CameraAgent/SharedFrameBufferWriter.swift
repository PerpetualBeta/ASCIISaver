import Foundation

final class SharedFrameBufferWriter {
    private let url: URL
    private var fd: Int32 = -1
    private var mapPtr: UnsafeMutableRawPointer?
    private var mapSize: Int = 0

    /// Whether mask space is allocated in the current mmap
    private var maskAllocated: Bool = false

    init(url: URL = SharedFrameBufferPath.url()) {
        self.url = url
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("[ASCIISaverCameraAgent] Shared buffer path: \(url.path)")
    }

    deinit { close() }

    func touch() {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let handle = FileHandle(forWritingAtPath: url.path)
        if handle == nil {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        } else {
            try? handle?.close()
        }
    }

    /// Open the shared framebuffer.
    /// - Parameter includeMask: If true, allocate space for a person mask plane after the pixel data.
    func open(width: Int, height: Int, bytesPerRow: Int, pixelFormat: SharedFramePixelFormat, includeMask: Bool = false) throws {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        touch()

        let headerSize = SharedFrameHeader.size
        let payloadSize = bytesPerRow * height
        let maskSize = includeMask ? (width * height) : 0
        let totalSize = headerSize + payloadSize + maskSize

        fd = Darwin.open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: "ASCIISaver", code: 1, userInfo: [NSLocalizedDescriptionKey: "open() failed for \(url.path)"]) }

        if ftruncate(fd, off_t(totalSize)) != 0 { throw NSError(domain: "ASCIISaver", code: 2, userInfo: [NSLocalizedDescriptionKey: "ftruncate() failed"]) }

        mapPtr = mmap(nil, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let mapPtr = mapPtr, mapPtr != MAP_FAILED else { throw NSError(domain: "ASCIISaver", code: 3, userInfo: [NSLocalizedDescriptionKey: "mmap() failed"]) }
        mapSize = totalSize
        maskAllocated = includeMask

        var hdr = SharedFrameHeader()
        hdr.width = UInt32(width)
        hdr.height = UInt32(height)
        hdr.bytesPerRow = UInt32(bytesPerRow)
        hdr.pixelFormat = pixelFormat.rawValue
        hdr.frameCounter = 0
        hdr.timestampNs = 0
        hdr.seq = 0

        if includeMask {
            hdr.maskOffset = UInt32(headerSize + payloadSize)
            hdr.flags = SharedFrameHeader.flagMaskPresent
        } else {
            hdr.maskOffset = 0
            hdr.flags = 0
        }

        mapPtr.storeBytes(of: hdr, as: SharedFrameHeader.self)
        msync(mapPtr, headerSize, MS_SYNC)

        print("[ASCIISaverCameraAgent] Opened shared mmap: \(url.path) size=\(totalSize) mask=\(includeMask)")
    }

    func close() {
        if let mapPtr = mapPtr, mapPtr != MAP_FAILED { munmap(mapPtr, mapSize) }
        mapPtr = nil
        mapSize = 0
        maskAllocated = false
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// Write a luma8 frame, optionally with a person segmentation mask.
    /// - Parameter maskData: Optional mask buffer (width×height bytes, 0=bg, 255=person). Pass nil if no mask.
    func writeFrameLuma8(width: Int, height: Int, bytesPerRow: Int, data: UnsafeRawPointer, timestampNs: UInt64, maskData: UnsafeRawPointer? = nil) {
        guard let mapPtr = mapPtr else { return }

        var hdr = mapPtr.load(as: SharedFrameHeader.self)

        guard hdr.magic == SharedFrameHeader.magic,
              hdr.pixelFormat == SharedFramePixelFormat.luma8.rawValue
        else { return }

        if Int(hdr.width) != width || Int(hdr.height) != height || Int(hdr.bytesPerRow) != bytesPerRow { return }

        hdr.seq &+= 1 // begin write (odd)
        mapPtr.storeBytes(of: hdr, as: SharedFrameHeader.self)

        // Write pixel data
        let payloadOffset = SharedFrameHeader.size
        let payloadPtr = mapPtr.advanced(by: payloadOffset)
        memcpy(payloadPtr, data, bytesPerRow * height)

        // Write mask data if present
        if let maskData = maskData, maskAllocated, hdr.maskOffset > 0 {
            let maskOffset = Int(hdr.maskOffset)
            let maskSize = width * height
            if maskOffset + maskSize <= mapSize {
                let maskPtr = mapPtr.advanced(by: maskOffset)
                memcpy(maskPtr, maskData, maskSize)
            }
            hdr.flags |= SharedFrameHeader.flagMaskPresent
        } else {
            hdr.flags &= ~SharedFrameHeader.flagMaskPresent
        }

        hdr.frameCounter &+= 1
        hdr.timestampNs = timestampNs

        hdr.seq &+= 1 // end write (even)
        mapPtr.storeBytes(of: hdr, as: SharedFrameHeader.self)

        let syncSize = maskAllocated ? mapSize : (payloadOffset + (bytesPerRow * height))
        msync(mapPtr, syncSize, MS_ASYNC)
    }
}
