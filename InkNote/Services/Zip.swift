import Foundation
import Compression

enum ZipError: LocalizedError {
    case cannotCreate
    case entryTooLarge
    case tooManyEntries
    case badArchive
    case unsupportedCompression
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cannotCreate: return "The export file could not be created."
        case .entryTooLarge: return "The export is too large for a single zip file."
        case .tooManyEntries: return "There are too many files for a single zip file."
        case .badArchive: return "That file is not a readable InkNote backup."
        case .unsupportedCompression: return "That archive uses a compression method InkNote cannot read."
        case .cancelled: return "The export was cancelled."
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

// MARK: - Writer

/// Writes a standard .zip file with stored (uncompressed) entries. PDFs, JPEGs and audio are
/// already compressed, so storing them costs almost nothing and keeps this code small.
final class ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
        let time: UInt16
        let date: UInt16
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var c = ~seed
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        return ~c
    }

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else {
            throw ZipError.cannotCreate
        }
        handle = h
    }

    func addData(_ name: String, _ data: Data, date: Date = Date()) throws {
        guard data.count < 0xFFFF_FFFF else { throw ZipError.entryTooLarge }
        let crc = ZipWriter.crc32(data)
        try writeLocalHeader(name: name, crc: crc, size: UInt32(data.count), date: date)
        try write(data)
    }

    func addFile(_ name: String, from url: URL, date: Date = Date()) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size < 0xFFFF_FFFF else { throw ZipError.entryTooLarge }

        let chunkSize = 1 << 20
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }

        // First pass: the checksum has to be known before the data is written.
        var crc: UInt32 = 0
        while true {
            guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            crc = ZipWriter.crc32(chunk, seed: crc)
        }
        try reader.seek(toOffset: 0)

        try writeLocalHeader(name: name, crc: crc, size: UInt32(size), date: date)
        var written: UInt64 = 0
        while true {
            guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try write(chunk)
            written += UInt64(chunk.count)
        }
        if written != size { throw ZipError.badArchive }
    }

    func finish() throws {
        let directoryStart = offset
        guard directoryStart < 0xFFFF_FFFF else { throw ZipError.entryTooLarge }
        var directory = Data()
        for e in entries {
            directory.appendLE(UInt32(0x0201_4B50))
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(0x0800))
            directory.appendLE(UInt16(0))
            directory.appendLE(e.time)
            directory.appendLE(e.date)
            directory.appendLE(e.crc)
            directory.appendLE(e.size)
            directory.appendLE(e.size)
            directory.appendLE(UInt16(e.name.count))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt32(0))
            directory.appendLE(e.offset)
            directory.append(e.name)
        }
        // Measured before the end record is added: it is the size of the entry list alone.
        let directorySize = UInt32(directory.count)
        directory.appendLE(UInt32(0x0605_4B50))
        directory.appendLE(UInt16(0))
        directory.appendLE(UInt16(0))
        directory.appendLE(UInt16(entries.count))
        directory.appendLE(UInt16(entries.count))
        directory.appendLE(directorySize)
        directory.appendLE(UInt32(directoryStart))
        directory.appendLE(UInt16(0))
        try write(directory)
        try handle.close()
    }

    func abandon() {
        try? handle.close()
    }

    // MARK: Internals

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private func writeLocalHeader(name: String, crc: UInt32, size: UInt32, date: Date) throws {
        guard entries.count < 65_535 else { throw ZipError.tooManyEntries }
        guard offset < 0xFFFF_FFFF else { throw ZipError.entryTooLarge }
        let nameData = Data(name.utf8)
        let stamp = ZipWriter.dosStamp(date)

        var header = Data()
        header.appendLE(UInt32(0x0403_4B50))
        header.appendLE(UInt16(20))
        header.appendLE(UInt16(0x0800))
        header.appendLE(UInt16(0))
        header.appendLE(stamp.time)
        header.appendLE(stamp.date)
        header.appendLE(crc)
        header.appendLE(size)
        header.appendLE(size)
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(0))
        header.append(nameData)

        entries.append(Entry(name: nameData, crc: crc, size: size, offset: UInt32(offset),
                             time: stamp.time, date: stamp.date))
        try write(header)
    }

    private static func dosStamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let time = ((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2)
        let day = (year << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1)
        return (UInt16(time), UInt16(day))
    }
}

// MARK: - Reader

/// Reads zip files. Entries may be stored or deflated, so ordinary zips open as well as our own.
final class ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: UInt32
        let size: UInt32
        let localOffset: UInt32
    }

    private let handle: FileHandle
    let entries: [Entry]

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    init(url: URL) throws {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ZipError.badArchive }
        handle = h

        let fileSize = try h.seekToEnd()
        let tailLength = min(fileSize, 65_557)
        if tailLength < 22 { throw ZipError.badArchive }
        try h.seek(toOffset: fileSize - tailLength)
        let tail = [UInt8](try h.read(upToCount: Int(tailLength)) ?? Data())

        // The end-of-directory record is the last place the signature 50 4B 05 06 appears.
        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 0x05 && tail[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard let end = eocd else { throw ZipError.badArchive }

        let count = Int(ZipReader.le16(tail, end + 10))
        let directorySize = ZipReader.le32(tail, end + 12)
        let directoryOffset = ZipReader.le32(tail, end + 16)
        if directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF { throw ZipError.entryTooLarge }
        if UInt64(directoryOffset) + UInt64(directorySize) > fileSize { throw ZipError.badArchive }

        try h.seek(toOffset: UInt64(directoryOffset))
        let directory = [UInt8](try h.read(upToCount: Int(directorySize)) ?? Data())

        var parsed: [Entry] = []
        var p = 0
        for _ in 0..<count {
            if p + 46 > directory.count { throw ZipError.badArchive }
            if ZipReader.le32(directory, p) != 0x0201_4B50 { throw ZipError.badArchive }
            let method = ZipReader.le16(directory, p + 10)
            let compressed = ZipReader.le32(directory, p + 20)
            let size = ZipReader.le32(directory, p + 24)
            let nameLength = Int(ZipReader.le16(directory, p + 28))
            let extraLength = Int(ZipReader.le16(directory, p + 30))
            let commentLength = Int(ZipReader.le16(directory, p + 32))
            let localOffset = ZipReader.le32(directory, p + 42)
            if p + 46 + nameLength > directory.count { throw ZipError.badArchive }
            let nameBytes = Array(directory[(p + 46)..<(p + 46 + nameLength)])
            let name = String(decoding: nameBytes, as: UTF8.self)
            parsed.append(Entry(name: name, method: method, compressedSize: compressed,
                                size: size, localOffset: localOffset))
            p += 46 + nameLength + extraLength + commentLength
        }
        entries = parsed
    }

    deinit {
        try? handle.close()
    }

    /// Writes one entry to disk. Stored entries are copied in chunks, so large audio files stay out of memory.
    func extract(_ entry: Entry, to destination: URL) throws {
        try handle.seek(toOffset: UInt64(entry.localOffset))
        let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
        if header.count < 30 || ZipReader.le32(header, 0) != 0x0403_4B50 { throw ZipError.badArchive }
        let nameLength = UInt64(ZipReader.le16(header, 26))
        let extraLength = UInt64(ZipReader.le16(header, 28))
        let dataStart = UInt64(entry.localOffset) + 30 + nameLength + extraLength
        try handle.seek(toOffset: dataStart)

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        switch entry.method {
        case 0:
            try? FileManager.default.removeItem(at: destination)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw ZipError.cannotCreate
            }
            let out = try FileHandle(forWritingTo: destination)
            defer { try? out.close() }
            var remaining = Int(entry.compressedSize)
            while remaining > 0 {
                guard let chunk = try handle.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty else {
                    throw ZipError.badArchive
                }
                try out.write(contentsOf: chunk)
                remaining -= chunk.count
            }

        case 8:
            guard let compressed = try handle.read(upToCount: Int(entry.compressedSize)),
                  compressed.count == Int(entry.compressedSize) else {
                throw ZipError.badArchive
            }
            let expected = Int(entry.size)
            if expected > 1_000_000_000 { throw ZipError.entryTooLarge }
            if expected == 0 {
                try Data().write(to: destination)
                return
            }
            let output = UnsafeMutablePointer<UInt8>.allocate(capacity: expected)
            defer { output.deallocate() }
            let produced = compressed.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(output, expected, base, compressed.count, nil, COMPRESSION_ZLIB)
            }
            guard produced == expected else { throw ZipError.badArchive }
            try Data(bytes: output, count: produced).write(to: destination)

        default:
            throw ZipError.unsupportedCompression
        }
    }

    /// A relative path that cannot climb out of the folder it is extracted into, or nil to skip the entry.
    static func safePath(_ name: String) -> String? {
        if name.hasSuffix("/") || name.hasPrefix("/") { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return nil }
        if parts.first == "__MACOSX" { return nil }
        return parts.joined(separator: "/")
    }
}
