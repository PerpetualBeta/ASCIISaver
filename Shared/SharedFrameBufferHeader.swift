import Foundation

enum SharedFramePixelFormat: UInt32 {
    case bgra8 = 0
    case luma8 = 1
}

struct SharedFrameHeader {
    static let magic: UInt32 = 0x49534341 // "ASCI"
    static let currentVersion: UInt32 = 3

    var magic: UInt32 = SharedFrameHeader.magic
    var version: UInt32 = SharedFrameHeader.currentVersion

    // Seqlock: even = stable, odd = writer in progress
    var seq: UInt32 = 0
    var _reservedSeqPad: UInt32 = 0

    var width: UInt32 = 0
    var height: UInt32 = 0
    var bytesPerRow: UInt32 = 0
    var pixelFormat: UInt32 = SharedFramePixelFormat.bgra8.rawValue

    var frameCounter: UInt64 = 0
    var timestampNs: UInt64 = 0

    // v3 fields
    var maskOffset: UInt32 = 0
    var flags: UInt32 = 0
    var reserved1: UInt64 = 0

    static let flagMaskPresent: UInt32 = 1
    static var size: Int { MemoryLayout<SharedFrameHeader>.stride }
}
