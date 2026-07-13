import Compression
import Foundation

// A tiny, dependency-free ZIP codec — just enough for shotAI's shareable package
// (.zip). Keeping it in-tree avoids the project's first third-party dependency
// (simpler Phase E notarization) and keeps full control over the UNTRUSTED-input
// import path. The reader is deliberately narrow: STORED (method 0) and DEFLATE
// (method 8, via Apple's Compression — COMPRESSION_ZLIB is raw RFC-1951 DEFLATE,
// exactly ZIP method 8); no zip64, encryption, or multi-disk. Anything else, or
// any out-of-bounds offset/size, is rejected. The writer emits STORED entries
// (images are already compressed; project.json is tiny), which JSZip on Windows
// reads fine — so packages round-trip both directions.

public struct ZipEntry {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

public enum ZipError: Error, LocalizedError, Equatable {
    case notAZip
    case corrupt(String)
    case entryTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip: "This file is not a valid .zip package."
        case .corrupt(let why): "The .zip package is corrupt: \(why)"
        case .entryTooLarge(let name): "A file in the package is too large: \(name)"
        }
    }
}

private let sigLocal = 0x0403_4b50
private let sigCentral = 0x0201_4b50
private let sigEOCD = 0x0605_4b50

// MARK: - Writer (STORED)

/// Build a ZIP archive (all entries STORED/uncompressed) from `entries` in order.
public func zipStored(_ entries: [(name: String, data: Data)]) -> Data {
    var out = Data()
    var central = Data()
    var offsets: [Int] = []

    func appU16(_ into: inout Data, _ v: Int) {
        into.append(UInt8(v & 0xff)); into.append(UInt8((v >> 8) & 0xff))
    }
    func appU32(_ into: inout Data, _ v: UInt32) {
        into.append(UInt8(v & 0xff)); into.append(UInt8((v >> 8) & 0xff))
        into.append(UInt8((v >> 16) & 0xff)); into.append(UInt8((v >> 24) & 0xff))
    }

    for (name, data) in entries {
        let nameBytes = Array(name.utf8)
        let crc = crc32(data)
        let size = UInt32(data.count)
        offsets.append(out.count)

        // Local file header.
        appU32(&out, UInt32(sigLocal))
        appU16(&out, 20)            // version needed
        appU16(&out, 0)             // flags
        appU16(&out, 0)             // method: stored
        appU16(&out, 0)             // mod time
        appU16(&out, 0x21)          // mod date (1980-01-01)
        appU32(&out, crc)
        appU32(&out, size)          // compressed
        appU32(&out, size)          // uncompressed
        appU16(&out, nameBytes.count)
        appU16(&out, 0)             // extra len
        out.append(contentsOf: nameBytes)
        out.append(data)

        // Central directory record.
        appU32(&central, UInt32(sigCentral))
        appU16(&central, 20)        // version made by
        appU16(&central, 20)        // version needed
        appU16(&central, 0)         // flags
        appU16(&central, 0)         // method
        appU16(&central, 0)         // mod time
        appU16(&central, 0x21)      // mod date
        appU32(&central, crc)
        appU32(&central, size)
        appU32(&central, size)
        appU16(&central, nameBytes.count)
        appU16(&central, 0)         // extra
        appU16(&central, 0)         // comment
        appU16(&central, 0)         // disk number start
        appU16(&central, 0)         // internal attrs
        appU32(&central, 0)         // external attrs
        appU32(&central, UInt32(offsets.last!))
        central.append(contentsOf: nameBytes)
    }

    let cdOffset = out.count
    out.append(central)
    let cdSize = central.count

    // End of central directory.
    appU32(&out, UInt32(sigEOCD))
    appU16(&out, 0)                 // this disk
    appU16(&out, 0)                 // cd start disk
    appU16(&out, entries.count)     // entries on this disk
    appU16(&out, entries.count)     // total entries
    appU32(&out, UInt32(cdSize))
    appU32(&out, UInt32(cdOffset))
    appU16(&out, 0)                 // comment len
    return out
}

// MARK: - Reader (STORED + DEFLATE)

/// A listed archive entry — metadata only, no decompression yet. Splitting list
/// from extract lets a caller inflate ONLY the entries it keeps (with a running
/// total cap), so a zip bomb of junk/non-whitelisted entries is never inflated.
public struct ZipItem {
    public let name: String
    public let method: Int            // 0 = stored, 8 = deflate
    public let uncompressedSize: Int
    let compressedRange: Range<Int>  // absolute indices into the source Data (in-module use only)
}

/// Parse a ZIP's central directory into entry metadata (files only; directories
/// skipped). Every offset/length is bounds-checked; malformed input throws rather
/// than crashing. NO decompression happens here.
public func zipList(_ data: Data) throws -> [ZipItem] {
    let n = data.count
    guard n >= 22 else { throw ZipError.notAZip }

    func u16(_ o: Int) -> Int {
        let i = data.startIndex + o
        return Int(data[i]) | (Int(data[i + 1]) << 8)
    }
    func u32(_ o: Int) -> Int {
        let i = data.startIndex + o
        return Int(data[i]) | (Int(data[i + 1]) << 8) | (Int(data[i + 2]) << 16) | (Int(data[i + 3]) << 24)
    }

    // Locate the End Of Central Directory record (scan back over the optional
    // trailing comment, up to its 0xffff max).
    var eocd = -1
    let lowest = max(0, n - 22 - 0xffff)
    var p = n - 22
    while p >= lowest {
        if u32(p) == sigEOCD { eocd = p; break }
        p -= 1
    }
    guard eocd >= 0 else { throw ZipError.notAZip }

    let count = u16(eocd + 10)
    let cdSize = u32(eocd + 12)
    let cdOffset = u32(eocd + 16)
    guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= n else {
        throw ZipError.corrupt("central directory out of bounds")
    }

    var items: [ZipItem] = []
    var c = cdOffset
    let cdEnd = cdOffset + cdSize
    for _ in 0..<count {
        guard c + 46 <= cdEnd, u32(c) == sigCentral else {
            throw ZipError.corrupt("bad central directory record")
        }
        let method = u16(c + 10)
        let compSize = u32(c + 20)
        let uncompSize = u32(c + 24)
        let nameLen = u16(c + 28)
        let extraLen = u16(c + 30)
        let commentLen = u16(c + 32)
        let localOff = u32(c + 42)
        guard c + 46 + nameLen <= cdEnd else { throw ZipError.corrupt("truncated name") }
        let nameData = data.subdata(in: (data.startIndex + c + 46)..<(data.startIndex + c + 46 + nameLen))
        let name = String(decoding: nameData, as: UTF8.self)
        c += 46 + nameLen + extraLen + commentLen

        // Skip directory entries (and anything with a zero-length name).
        if name.isEmpty || name.hasSuffix("/") { continue }

        // Resolve the data range via the LOCAL header (its name/extra lengths can
        // differ from the central record's). Bounds-checked so zipExtract's slice
        // is always valid.
        guard localOff >= 0, localOff + 30 <= n, u32(localOff) == sigLocal else {
            throw ZipError.corrupt("bad local header for \(name)")
        }
        let lNameLen = u16(localOff + 26)
        let lExtraLen = u16(localOff + 28)
        let dataStart = localOff + 30 + lNameLen + lExtraLen
        guard compSize >= 0, uncompSize >= 0, dataStart >= 0, dataStart + compSize <= n else {
            throw ZipError.corrupt("data out of bounds for \(name)")
        }
        let start = data.startIndex + dataStart
        items.append(ZipItem(name: name, method: method, uncompressedSize: uncompSize,
                             compressedRange: start..<(start + compSize)))
    }
    return items
}

/// Decompress one listed entry to bytes (STORED = copy, DEFLATE = inflate). Pass
/// the SAME `data` that was given to `zipList`.
public func zipExtract(_ data: Data, _ item: ZipItem) throws -> Data {
    let comp = data.subdata(in: item.compressedRange)
    switch item.method {
    case 0: // STORED
        guard comp.count == item.uncompressedSize else {
            throw ZipError.corrupt("stored size mismatch for \(item.name)")
        }
        return comp
    case 8: // DEFLATE
        guard let out = inflateRaw(comp, expected: item.uncompressedSize) else {
            throw ZipError.corrupt("could not decompress \(item.name)")
        }
        return out
    default:
        throw ZipError.corrupt("unsupported compression for \(item.name)")
    }
}

/// Convenience: list + extract every entry (used by tests and simple callers). An
/// entry whose uncompressed size exceeds `maxEntryBytes` throws. Prefer
/// zipList + selective zipExtract for untrusted input (avoids inflating junk).
public func zipRead(_ data: Data, maxEntryBytes: Int) throws -> [ZipEntry] {
    try zipList(data).map { item in
        guard item.uncompressedSize <= maxEntryBytes else { throw ZipError.entryTooLarge(item.name) }
        return ZipEntry(name: item.name, data: try zipExtract(data, item))
    }
}

/// Inflate raw DEFLATE (ZIP method 8) to a known size via Apple's Compression.
private func inflateRaw(_ src: Data, expected: Int) -> Data? {
    if expected == 0 { return Data() }
    guard !src.isEmpty else { return nil }
    var dst = Data(count: expected)
    let written = dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
        src.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
            guard let d = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                  let s = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(d, expected, s, src.count, nil, COMPRESSION_ZLIB)
        }
    }
    return written == expected ? dst : nil
}

// MARK: - CRC-32 (IEEE 802.3)

private let crcTable: [UInt32] = {
    (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
}()

public func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for byte in data {
        c = crcTable[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8)
    }
    return c ^ 0xFFFF_FFFF
}
