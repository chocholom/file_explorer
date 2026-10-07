import Foundation

/// Reads a ZIP central directory (incl. ZIP64) into `ArchiveEntry` values without
/// touching the compressed data. Extraction is left to bsdtar (see `SystemTar`),
/// which handles every compression method.
enum ZipReader {
    enum ZipError: LocalizedError {
        case notAZip
        case truncated

        var errorDescription: String? {
            switch self {
            case .notAZip: return "This file isn't a ZIP archive."
            case .truncated: return "The ZIP archive is damaged or truncated."
            }
        }
    }

    static func entries(of url: URL) throws -> [ArchiveEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())

        // End of central directory: last 22 bytes + up to 64 KB of comment.
        let tailLength = Int(min(fileSize, 65_557))
        try handle.seek(toOffset: UInt64(fileSize - Int64(tailLength)))
        guard let tail = try handle.read(upToCount: tailLength), tail.count == tailLength else {
            throw ZipError.truncated
        }
        guard let eocd = lastIndex(of: [0x50, 0x4b, 0x05, 0x06], in: tail) else { throw ZipError.notAZip }
        let eocdFileOffset = Int64(fileSize) - Int64(tailLength) + Int64(eocd)

        var totalEntries = Int64(tail.u16(at: eocd + 10))
        var centralSize = Int64(tail.u32(at: eocd + 12))
        var centralOffset = Int64(tail.u32(at: eocd + 16))

        if totalEntries == 0xFFFF || centralSize == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF {
            // ZIP64: locator sits right before the EOCD and points at the EOCD64 record.
            let locator = eocd - 20
            if locator >= 0, tail.u32(at: locator) == 0x0706_4b50 {
                let eocd64Offset = tail.u64(at: locator + 8)
                try handle.seek(toOffset: eocd64Offset)
                guard let record = try handle.read(upToCount: 56), record.count == 56,
                    record.u32(at: 0) == 0x0606_4b50
                else { throw ZipError.truncated }
                totalEntries = Int64(record.u64(at: 32))
                centralSize = Int64(record.u64(at: 40))
                centralOffset = Int64(record.u64(at: 48))
            }
        }
        guard centralOffset + centralSize <= eocdFileOffset || centralOffset + centralSize <= fileSize else {
            throw ZipError.truncated
        }

        try handle.seek(toOffset: UInt64(centralOffset))
        guard let directory = try handle.read(upToCount: Int(centralSize)), directory.count == Int(centralSize)
        else { throw ZipError.truncated }

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(Int(min(totalEntries, 1_000_000)))
        var cursor = 0
        while cursor + 46 <= directory.count, directory.u32(at: cursor) == 0x0201_4b50 {
            let versionMadeBy = directory.u16(at: cursor + 4)
            let flags = directory.u16(at: cursor + 8)
            let dosTime = directory.u16(at: cursor + 12)
            let dosDate = directory.u16(at: cursor + 14)
            var uncompressedSize = Int64(directory.u32(at: cursor + 24))
            let nameLength = Int(directory.u16(at: cursor + 28))
            let extraLength = Int(directory.u16(at: cursor + 30))
            let commentLength = Int(directory.u16(at: cursor + 32))
            let externalAttributes = directory.u32(at: cursor + 38)

            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { break }

            let nameData = directory.subdata(in: nameStart..<extraStart)
            let rawName = decodeName(nameData, utf8Flag: flags & 0x800 != 0)

            var modified = dosDate == 0 ? Date.distantPast : date(dosDate: dosDate, dosTime: dosTime)
            // Extra fields: ZIP64 sizes (0x0001) and Info-ZIP extended timestamp (0x5455).
            var extraCursor = extraStart
            let extraEnd = extraStart + extraLength
            while extraCursor + 4 <= extraEnd {
                let id = directory.u16(at: extraCursor)
                let size = Int(directory.u16(at: extraCursor + 2))
                let dataStart = extraCursor + 4
                guard dataStart + size <= extraEnd else { break }
                if id == 0x0001, uncompressedSize == 0xFFFF_FFFF, size >= 8 {
                    uncompressedSize = Int64(bitPattern: directory.u64(at: dataStart))
                } else if id == 0x5455, size >= 5, directory[dataStart] & 0x01 != 0 {
                    modified = Date(timeIntervalSince1970: TimeInterval(directory.u32(at: dataStart + 1)))
                }
                extraCursor = dataStart + size
            }

            let unixMode = (externalAttributes >> 16) & 0o170000
            let madeOnUnix = (versionMadeBy >> 8) == 3
            let isDirectory = rawName.hasSuffix("/")
                || (externalAttributes & 0x10 != 0 && !madeOnUnix)
                || (madeOnUnix && unixMode == 0o040000)

            if let path = ArchiveEntry.normalize(rawName) {
                entries.append(ArchiveEntry(
                    path: path, isDirectory: isDirectory,
                    size: isDirectory ? 0 : max(0, uncompressedSize), modified: modified))
            }
            cursor = next
        }
        return entries
    }

    // MARK: Helpers

    private static func lastIndex(of pattern: [UInt8], in data: Data) -> Int? {
        guard data.count >= pattern.count else { return nil }
        var index = data.count - pattern.count
        while index >= 0 {
            if data[data.startIndex + index] == pattern[0] {
                var matches = true
                for offset in 1..<pattern.count where data[data.startIndex + index + offset] != pattern[offset] {
                    matches = false
                    break
                }
                if matches { return index }
            }
            index -= 1
        }
        return nil
    }

    private static func decodeName(_ data: Data, utf8Flag: Bool) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if utf8Flag { return String(decoding: data, as: UTF8.self) }
        let cp437 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: cp437)) ?? String(decoding: data, as: UTF8.self)
    }

    private static func date(dosDate: UInt16, dosTime: UInt16) -> Date {
        var components = DateComponents()
        components.year = 1980 + Int(dosDate >> 9)
        components.month = Int((dosDate >> 5) & 0x0F)
        components.day = Int(dosDate & 0x1F)
        components.hour = Int(dosTime >> 11)
        components.minute = Int((dosTime >> 5) & 0x3F)
        components.second = Int(dosTime & 0x1F) * 2
        return Calendar.current.date(from: components) ?? .distantPast
    }
}

extension Data {
    fileprivate func u16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    fileprivate func u32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }

    fileprivate func u64(at offset: Int) -> UInt64 {
        UInt64(u32(at: offset)) | UInt64(u32(at: offset + 4)) << 32
    }
}
