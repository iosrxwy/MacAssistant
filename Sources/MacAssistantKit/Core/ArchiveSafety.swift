import Foundation

public struct ArchiveLimits: Sendable, Equatable {
    public var maxEntries: Int
    public var maxSingleFileBytes: UInt64
    public var maxTotalBytes: UInt64
    public var maxArchiveBytes: UInt64

    public init(
        maxEntries: Int = 20_000,
        maxSingleFileBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024,
        maxTotalBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024,
        maxArchiveBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
    ) {
        self.maxEntries = maxEntries
        self.maxSingleFileBytes = maxSingleFileBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxArchiveBytes = maxArchiveBytes
    }

    public static let `default` = ArchiveLimits()
}

public struct ArchiveValidationReport: Sendable, Equatable {
    public let entryCount: Int
    public let totalUncompressedBytes: UInt64
}

public enum ArchiveSafetyError: LocalizedError, Equatable {
    case malformed(String)
    case unsafePath(String)
    case symbolicLink(String)
    case entryLimit(Int)
    case singleFileLimit(path: String, size: UInt64)
    case totalSizeLimit(UInt64)

    public var errorDescription: String? {
        switch self {
        case let .malformed(reason): return L("archive.error.malformed", reason)
        case let .unsafePath(path): return L("archive.error.unsafePath", path)
        case let .symbolicLink(path): return L("archive.error.symbolicLink", path)
        case let .entryLimit(count): return L("archive.error.entryLimit", count)
        case let .singleFileLimit(path, size): return L("archive.error.singleFileLimit", path, String(size))
        case let .totalSizeLimit(size): return L("archive.error.totalSizeLimit", String(size))
        }
    }
}

public enum ArchiveSafety {
    public static func validatePath(_ path: String) throws {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        while normalized.hasPrefix("./") { normalized.removeFirst(2) }
        if normalized == "." { normalized = "" }
        guard !normalized.isEmpty,
              !normalized.contains("\0"),
              !normalized.hasPrefix("/"),
              path.range(of: #"^[A-Za-z]:[/\\]"#, options: .regularExpression) == nil
        else {
            throw ArchiveSafetyError.unsafePath(path)
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        for (index, component) in components.enumerated() {
            if component == ".." || component == "." {
                throw ArchiveSafetyError.unsafePath(path)
            }
            let isAllowedDirectoryTerminator = component.isEmpty
                && index == components.count - 1
                && normalized.hasSuffix("/")
            if component.isEmpty && !isAllowedDirectoryTerminator {
                throw ArchiveSafetyError.unsafePath(path)
            }
        }
    }

    public static func validateEntries(
        _ entries: [(path: String, size: Int64, link: String?)],
        limits: ArchiveLimits = .default
    ) throws -> ArchiveValidationReport {
        guard entries.count <= limits.maxEntries else {
            throw ArchiveSafetyError.entryLimit(entries.count)
        }
        var total: UInt64 = 0
        for entry in entries {
            if entry.path == "." || entry.path == "./" { continue }
            try validatePath(entry.path)
            if entry.link != nil { throw ArchiveSafetyError.symbolicLink(entry.path) }
            let size = UInt64(max(0, entry.size))
            guard size <= limits.maxSingleFileBytes else {
                throw ArchiveSafetyError.singleFileLimit(path: entry.path, size: size)
            }
            guard total <= UInt64.max - size else {
                throw ArchiveSafetyError.totalSizeLimit(UInt64.max)
            }
            total += size
            guard total <= limits.maxTotalBytes else { throw ArchiveSafetyError.totalSizeLimit(total) }
        }
        return ArchiveValidationReport(entryCount: entries.count, totalUncompressedBytes: total)
    }

    public static func validateZIP(
        _ data: Data,
        limits: ArchiveLimits = .default
    ) throws -> ArchiveValidationReport {
        guard UInt64(data.count) <= limits.maxArchiveBytes else {
            throw ArchiveSafetyError.totalSizeLimit(UInt64(data.count))
        }
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ArchiveSafetyError.malformed(L("archive.malformed.missingEndRecord")) }
        let searchStart = max(0, bytes.count - 22 - 65_535)
        var eocd: Int?
        var cursor = bytes.count - 22
        while cursor >= searchStart {
            if readU32(bytes, cursor) == 0x0605_4b50 {
                eocd = cursor
                break
            }
            cursor -= 1
        }
        guard let eocd else { throw ArchiveSafetyError.malformed(L("archive.malformed.noCentralDirectory")) }
        let entries = Int(readU16(bytes, eocd + 10))
        let centralSize = Int(readU32(bytes, eocd + 12))
        let centralOffset = Int(readU32(bytes, eocd + 16))
        guard entries <= limits.maxEntries else { throw ArchiveSafetyError.entryLimit(entries) }
        guard centralOffset <= bytes.count,
              centralSize <= bytes.count - centralOffset,
              centralOffset + centralSize <= eocd
        else {
            throw ArchiveSafetyError.malformed(L("archive.malformed.centralDirectoryOutOfRange"))
        }

        var pointer = centralOffset
        var total: UInt64 = 0
        for _ in 0..<entries {
            guard pointer <= bytes.count - 46, readU32(bytes, pointer) == 0x0201_4b50 else {
                throw ArchiveSafetyError.malformed(L("archive.malformed.centralEntryTruncated"))
            }
            let flags = readU16(bytes, pointer + 8)
            guard flags & 0x1 == 0 else { throw ArchiveSafetyError.malformed(L("archive.malformed.encryptedZIP")) }
            let compressedSize = UInt64(readU32(bytes, pointer + 20))
            let uncompressedSize = UInt64(readU32(bytes, pointer + 24))
            let nameLength = Int(readU16(bytes, pointer + 28))
            let extraLength = Int(readU16(bytes, pointer + 30))
            let commentLength = Int(readU16(bytes, pointer + 32))
            let externalAttributes = readU32(bytes, pointer + 38)
            let localOffset = Int(readU32(bytes, pointer + 42))
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, recordLength <= bytes.count - pointer else {
                throw ArchiveSafetyError.malformed(L("archive.malformed.nameOrExtraOutOfRange"))
            }
            let nameData = Data(bytes[(pointer + 46)..<(pointer + 46 + nameLength)])
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ArchiveSafetyError.malformed(L("archive.malformed.nameNotUTF8"))
            }
            try validatePath(name)
            let unixType = (externalAttributes >> 16) & 0o170000
            if unixType == 0o120000 {
                throw ArchiveSafetyError.symbolicLink(name)
            }
            guard uncompressedSize <= limits.maxSingleFileBytes else {
                throw ArchiveSafetyError.singleFileLimit(path: name, size: uncompressedSize)
            }
            guard total <= UInt64.max - uncompressedSize else {
                throw ArchiveSafetyError.totalSizeLimit(UInt64.max)
            }
            total += uncompressedSize
            guard total <= limits.maxTotalBytes else { throw ArchiveSafetyError.totalSizeLimit(total) }
            guard compressedSize <= limits.maxArchiveBytes,
                  localOffset <= bytes.count - 30,
                  readU32(bytes, localOffset) == 0x0403_4b50
            else {
                throw ArchiveSafetyError.malformed(L("archive.malformed.localEntryOutOfRange"))
            }
            pointer += recordLength
        }
        guard pointer == centralOffset + centralSize else {
            throw ArchiveSafetyError.malformed(L("archive.malformed.centralDirectorySizeMismatch"))
        }
        return ArchiveValidationReport(entryCount: entries, totalUncompressedBytes: total)
    }

    public static func validateZIP(
        at url: URL,
        limits: ArchiveLimits = .default
    ) throws -> ArchiveValidationReport {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard UInt64(max(0, size)) <= limits.maxArchiveBytes else {
            throw ArchiveSafetyError.totalSizeLimit(UInt64(max(0, size)))
        }
        return try validateZIP(Data(contentsOf: url, options: .mappedIfSafe), limits: limits)
    }

    private static func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
