import Foundation

/// Mach-O 处理相关错误。
public enum MachOError: LocalizedError, Sendable {
    case notMachO
    case truncated
    case unsupported(String)
    case noSpace(arch: String)
    case emptyFat
    case duplicateDylib(String)

    public var errorDescription: String? {
        switch self {
        case .notMachO: return L("dylib.macho.error.notMachO")
        case .truncated: return L("dylib.macho.error.truncated")
        case let .unsupported(reason): return L("dylib.macho.error.unsupported", reason)
        case let .noSpace(arch):
            return L("dylib.macho.error.noSpace", arch)
        case .emptyFat: return L("dylib.macho.error.emptyFat")
        case let .duplicateDylib(path): return L("dylib.macho.error.duplicateDylib", path)
        }
    }
}

/// 一次注入操作的结果报告。
public struct InjectionReport: Sendable {
    public var injectedSliceCount: Int = 0
    public var strippedSignature: Bool = false
    public var messages: [String] = []
}

public struct DylibInjectionRequest: Hashable, Sendable {
    public let dylibPath: String
    public let weak: Bool
    public let existingPolicy: ExistingLoadCommandPolicy

    public init(
        dylibPath: String,
        weak: Bool,
        existingPolicy: ExistingLoadCommandPolicy = .fail
    ) {
        self.dylibPath = dylibPath
        self.weak = weak
        self.existingPolicy = existingPolicy
    }
}

public struct DylibLoadCommandInfo: Hashable, Sendable {
    public let path: String
    public let weak: Bool
}

public struct DylibSliceInspection: Hashable, Sendable {
    public let index: Int
    public let commands: [DylibLoadCommandInfo]
}

// MARK: - 字节读写辅助

@inline(__always)
private func readU32(_ b: [UInt8], _ off: Int, littleEndian le: Bool) -> UInt32 {
    let b0 = UInt32(b[off]), b1 = UInt32(b[off + 1]), b2 = UInt32(b[off + 2]), b3 = UInt32(b[off + 3])
    return le ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
              : (b3 | (b2 << 8) | (b1 << 16) | (b0 << 24))
}

@inline(__always)
private func readU64(_ b: [UInt8], _ off: Int, littleEndian le: Bool) -> UInt64 {
    var v: UInt64 = 0
    if le { for i in 0..<8 { v |= UInt64(b[off + i]) << (8 * i) } }
    else { for i in 0..<8 { v = (v << 8) | UInt64(b[off + i]) } }
    return v
}

@inline(__always)
private func writeU32(_ b: inout [UInt8], _ off: Int, _ v: UInt32, littleEndian le: Bool) {
    if le {
        b[off] = UInt8(v & 0xff); b[off + 1] = UInt8((v >> 8) & 0xff)
        b[off + 2] = UInt8((v >> 16) & 0xff); b[off + 3] = UInt8((v >> 24) & 0xff)
    } else {
        b[off] = UInt8((v >> 24) & 0xff); b[off + 1] = UInt8((v >> 16) & 0xff)
        b[off + 2] = UInt8((v >> 8) & 0xff); b[off + 3] = UInt8(v & 0xff)
    }
}

// MARK: - 常量

private enum LC {
    static let reqDyld: UInt32 = 0x8000_0000
    static let loadDylib: UInt32 = 0x0c
    static let loadWeakDylib: UInt32 = 0x18 | 0x8000_0000
    static let idDylib: UInt32 = 0x0d
    static let reexportDylib: UInt32 = 0x1f | 0x8000_0000
    static let codeSignature: UInt32 = 0x1d
    static let segment: UInt32 = 0x01
    static let segment64: UInt32 = 0x19
}

/// 原生实现的 Mach-O dylib 注入器。
///
/// 通过把新的 `LC_LOAD_DYLIB`(或 `LC_LOAD_WEAK_DYLIB`)load command 写入头部的
/// 空闲填充区来完成注入,不改变各架构切片的大小,因此对胖二进制同样安全。
/// 由于注入会使既有代码签名失效,注入后通常需要重新(伪)签名。
public enum DylibInjector {

    private struct Slice { let offset: Int; let size: Int }

    /// 向磁盘上的 Mach-O 文件注入 dylib 加载命令。
    /// - Parameters:
    ///   - dylibPath: 要注入的 dylib 路径,常用 `@executable_path/xxx.dylib` 或 `@rpath/xxx.dylib`。
    ///   - url: 目标可执行文件。
    ///   - weak: 是否使用弱引用(`LC_LOAD_WEAK_DYLIB`)。
    ///   - stripCodeSignature: 头部空间不足时,是否移除 `LC_CODE_SIGNATURE` 以腾出空间。
    @discardableResult
    public static func inject(
        dylibPath: String,
        intoFileAt url: URL,
        weak: Bool = false,
        stripCodeSignature: Bool = false
    ) throws -> InjectionReport {
        var report = InjectionReport()
        var bytes = [UInt8](try Data(contentsOf: url))
        try injectAll(&bytes, dylibPath: dylibPath, weak: weak,
                      stripCodeSignature: stripCodeSignature, report: &report)
        try Data(bytes).write(to: url, options: .atomic)
        return report
    }

    /// 在同一个内存事务中完成多条注入；任一请求失败时不会写回磁盘。
    @discardableResult
    public static func inject(
        requests: [DylibInjectionRequest],
        intoFileAt url: URL,
        stripCodeSignature: Bool = false
    ) throws -> InjectionReport {
        var report = InjectionReport()
        var bytes = [UInt8](try Data(contentsOf: url))
        for request in requests {
            try apply(
                request,
                to: &bytes,
                stripCodeSignature: stripCodeSignature,
                report: &report
            )
        }
        try Data(bytes).write(to: url, options: .atomic)
        return report
    }

    /// 在内存字节缓冲上执行注入(便于测试)。
    public static func injectAll(
        _ b: inout [UInt8],
        dylibPath: String,
        weak: Bool,
        stripCodeSignature: Bool,
        report: inout InjectionReport
    ) throws {
        try apply(
            DylibInjectionRequest(dylibPath: dylibPath, weak: weak, existingPolicy: .fail),
            to: &b,
            stripCodeSignature: stripCodeSignature,
            report: &report
        )
    }

    /// 读取文件中(首个切片)已加载的 dylib 路径列表。
    public static func loadedDylibPaths(fileAt url: URL) throws -> [String] {
        let b = [UInt8](try Data(contentsOf: url))
        let slices = try parseSlices(b)
        guard let first = slices.first else { return [] }
        return try dylibPaths(b, sliceOffset: first.offset, sliceSize: first.size)
    }

    /// 返回每个切片各自的动态库加载路径，供 fat 二进制验证。
    public static func loadedDylibPathsBySlice(_ bytes: [UInt8]) throws -> [[String]] {
        try parseSlices(bytes).map {
            try dylibPaths(bytes, sliceOffset: $0.offset, sliceSize: $0.size)
        }
    }

    public static func inspectLoadCommands(fileAt url: URL) throws -> [DylibSliceInspection] {
        try inspectLoadCommands([UInt8](Data(contentsOf: url)))
    }

    public static func inspectLoadCommands(_ bytes: [UInt8]) throws -> [DylibSliceInspection] {
        try parseSlices(bytes).enumerated().map { index, slice in
            let commands = try dylibCommandLocations(
                bytes,
                sliceOffset: slice.offset,
                sliceSize: slice.size
            ).map { DylibLoadCommandInfo(path: $0.path, weak: $0.command == LC.loadWeakDylib) }
            return DylibSliceInspection(index: index, commands: commands)
        }
    }

    private static func apply(
        _ request: DylibInjectionRequest,
        to bytes: inout [UInt8],
        stripCodeSignature: Bool,
        report: inout InjectionReport
    ) throws {
        let slices = try parseSlices(bytes)
        guard !slices.isEmpty else { throw MachOError.emptyFat }
        guard !request.dylibPath.isEmpty, !request.dylibPath.utf8.contains(0) else {
            throw MachOError.unsupported(L("dylib.macho.unsupported.emptyPath"))
        }
        guard request.dylibPath.utf8.count <= Int(UInt32.max) - 25 else {
            throw MachOError.unsupported(L("dylib.macho.unsupported.pathTooLong"))
        }

        let occurrences = try slices.map {
            try dylibCommandLocations(
                bytes,
                sliceOffset: $0.offset,
                sliceSize: $0.size
            ).filter { $0.path == request.dylibPath }
        }
        if occurrences.contains(where: { $0.count > 1 }) {
            throw MachOError.unsupported(L("dylib.macho.unsupported.duplicateInSlice", request.dylibPath))
        }
        let presentCount = occurrences.filter { !$0.isEmpty }.count
        switch request.existingPolicy {
        case .fail:
            if presentCount > 0 { throw MachOError.duplicateDylib(request.dylibPath) }
        case .skip:
            if presentCount == slices.count {
                let expectedCommand = request.weak ? LC.loadWeakDylib : LC.loadDylib
                guard occurrences.allSatisfy({ $0.first?.command == expectedCommand }) else {
                    throw MachOError.unsupported(
                        L("dylib.macho.unsupported.referenceKindMismatch", request.dylibPath)
                    )
                }
                report.messages.append(L("dylib.macho.log.skippedExisting", request.dylibPath))
                return
            }
            if presentCount > 0 {
                throw MachOError.unsupported(L("dylib.macho.unsupported.partialSlices", request.dylibPath))
            }
        case .replace:
            break
        }

        for (index, slice) in slices.enumerated() {
            if let existing = occurrences[index].first {
                guard request.existingPolicy == .replace else {
                    throw MachOError.duplicateDylib(request.dylibPath)
                }
                writeU32(
                    &bytes,
                    existing.offset,
                    request.weak ? LC.loadWeakDylib : LC.loadDylib,
                    littleEndian: existing.littleEndian
                )
                report.messages.append(
                    L(
                        request.weak
                            ? "dylib.macho.log.replacedWithWeak"
                            : "dylib.macho.log.replacedWithStrong",
                        index + 1,
                        request.dylibPath
                    )
                )
            } else {
                try injectIntoSlice(
                    &bytes,
                    sliceOffset: slice.offset,
                    sliceSize: slice.size,
                    dylibPath: request.dylibPath,
                    weak: request.weak,
                    stripCodeSignature: stripCodeSignature,
                    report: &report
                )
            }
        }
    }

    // MARK: 切片解析

    private static func parseSlices(_ b: [UInt8]) throws -> [Slice] {
        guard b.count >= 8 else { throw MachOError.notMachO }
        let mBE = readU32(b, 0, littleEndian: false)
        if mBE == 0xCAFE_BABE || mBE == 0xCAFE_BABF {
            return try fatSlices(b, is64: mBE == 0xCAFE_BABF, fatLE: false)
        }
        let mLE = readU32(b, 0, littleEndian: true)
        if mLE == 0xCAFE_BABE || mLE == 0xCAFE_BABF {
            return try fatSlices(b, is64: mLE == 0xCAFE_BABF, fatLE: true)
        }
        switch mLE {
        case 0xFEED_FACF, 0xFEED_FACE, 0xCFFA_EDFE, 0xCEFA_EDFE:
            return [Slice(offset: 0, size: b.count)]
        default:
            throw MachOError.notMachO
        }
    }

    private static func fatSlices(_ b: [UInt8], is64: Bool, fatLE le: Bool) throws -> [Slice] {
        let nfat = Int(readU32(b, 4, littleEndian: le))
        let entrySize = is64 ? 32 : 20
        guard nfat > 0, nfat <= (b.count - 8) / entrySize else {
            throw MachOError.truncated
        }
        let tableEnd = 8 + nfat * entrySize
        var result: [Slice] = []
        var p = 8
        for _ in 0..<nfat {
            let offset: Int
            let size: Int
            if is64 {
                guard p + 32 <= b.count else { throw MachOError.truncated }
                let rawOffset = readU64(b, p + 8, littleEndian: le)
                let rawSize = readU64(b, p + 16, littleEndian: le)
                guard rawOffset <= UInt64(Int.max), rawSize <= UInt64(Int.max) else {
                    throw MachOError.unsupported(L("dylib.macho.unsupported.fatSliceOverflow"))
                }
                offset = Int(rawOffset)
                size = Int(rawSize)
                p += 32
            } else {
                guard p + 20 <= b.count else { throw MachOError.truncated }
                offset = Int(readU32(b, p + 8, littleEndian: le))
                size = Int(readU32(b, p + 12, littleEndian: le))
                p += 20
            }
            guard offset >= tableEnd, size >= 4, offset <= b.count, size <= b.count - offset else {
                throw MachOError.truncated
            }
            result.append(Slice(offset: offset, size: size))
        }
        let sorted = result.sorted { $0.offset < $1.offset }
        for pair in zip(sorted, sorted.dropFirst()) {
            guard pair.0.size <= pair.1.offset - pair.0.offset else {
                throw MachOError.unsupported(L("dylib.macho.unsupported.fatSliceOverlap"))
            }
        }
        return result
    }

    // MARK: 头部解析

    private static func headerInfo(_ b: [UInt8], sliceOffset: Int) throws -> (is64: Bool, le: Bool, headerSize: Int) {
        guard sliceOffset + 4 <= b.count else { throw MachOError.truncated }
        switch readU32(b, sliceOffset, littleEndian: true) {
        case 0xFEED_FACF: return (true, true, 32)
        case 0xFEED_FACE: return (false, true, 28)
        case 0xCFFA_EDFE: return (true, false, 32)
        case 0xCEFA_EDFE: return (false, false, 28)
        default: throw MachOError.notMachO
        }
    }

    private struct DylibCommandLocation {
        let path: String
        let command: UInt32
        let offset: Int
        let littleEndian: Bool
    }

    private static func dylibPaths(_ b: [UInt8], sliceOffset: Int, sliceSize: Int) throws -> [String] {
        try dylibCommandLocations(b, sliceOffset: sliceOffset, sliceSize: sliceSize).map(\.path)
    }

    private static func dylibCommandLocations(
        _ b: [UInt8],
        sliceOffset: Int,
        sliceSize: Int
    ) throws -> [DylibCommandLocation] {
        let (_, le, headerSize) = try headerInfo(b, sliceOffset: sliceOffset)
        guard sliceSize >= headerSize, sliceOffset <= b.count, sliceSize <= b.count - sliceOffset else {
            throw MachOError.truncated
        }
        let sliceEnd = sliceOffset + sliceSize
        let ncmds = Int(readU32(b, sliceOffset + 16, littleEndian: le))
        let sizeofcmds = Int(readU32(b, sliceOffset + 20, littleEndian: le))
        guard sizeofcmds <= sliceSize - headerSize else { throw MachOError.truncated }
        let commandsEnd = sliceOffset + headerSize + sizeofcmds
        var p = sliceOffset + headerSize
        var commands: [DylibCommandLocation] = []
        for _ in 0..<ncmds {
            guard p <= commandsEnd, p + 8 <= commandsEnd, p + 8 <= sliceEnd else {
                throw MachOError.truncated
            }
            let cmd = readU32(b, p, littleEndian: le)
            let cmdsize = Int(readU32(b, p + 4, littleEndian: le))
            guard cmdsize >= 8, cmdsize <= commandsEnd - p else { throw MachOError.truncated }
            if cmd == LC.loadDylib || cmd == LC.loadWeakDylib || cmd == LC.reexportDylib {
                guard cmdsize >= 12 else { throw MachOError.truncated }
                let nameOff = Int(readU32(b, p + 8, littleEndian: le))
                if nameOff >= 12, nameOff < cmdsize {
                    let start = p + nameOff
                    var end = start
                    while end < p + cmdsize && b[end] != 0 { end += 1 }
                    commands.append(
                        DylibCommandLocation(
                            path: String(decoding: b[start..<end], as: UTF8.self),
                            command: cmd,
                            offset: p,
                            littleEndian: le
                        )
                    )
                }
            }
            p += cmdsize
        }
        return commands
    }

    // MARK: 单切片注入

    private static func injectIntoSlice(
        _ b: inout [UInt8],
        sliceOffset: Int,
        sliceSize: Int,
        dylibPath: String,
        weak: Bool,
        stripCodeSignature: Bool,
        report: inout InjectionReport
    ) throws {
        let (is64, le, headerSize) = try headerInfo(b, sliceOffset: sliceOffset)
        guard sliceSize >= headerSize, sliceOffset <= b.count, sliceSize <= b.count - sliceOffset else {
            throw MachOError.truncated
        }
        let sliceEnd = sliceOffset + sliceSize

        let ncmdsOff = sliceOffset + 16
        let sizeofcmdsOff = sliceOffset + 20
        var ncmds = readU32(b, ncmdsOff, littleEndian: le)
        var sizeofcmds = readU32(b, sizeofcmdsOff, littleEndian: le)
        let loadCommandsStart = sliceOffset + headerSize
        guard Int(sizeofcmds) <= sliceSize - headerSize else { throw MachOError.truncated }
        let cmdsEndAbs = loadCommandsStart + Int(sizeofcmds)
        guard cmdsEndAbs <= sliceEnd else { throw MachOError.truncated }

        // 扫描:最小 section 文件偏移(切片内相对偏移)与代码签名命令位置。
        var minSectionOffset = sliceSize
        var codeSigOffset: Int?
        var codeSigSize = 0
        var p = loadCommandsStart
        for _ in 0..<ncmds {
            guard p + 8 <= cmdsEndAbs else { throw MachOError.truncated }
            let cmd = readU32(b, p, littleEndian: le)
            let cmdsize = Int(readU32(b, p + 4, littleEndian: le))
            guard cmdsize >= 8, p + cmdsize <= cmdsEndAbs else { throw MachOError.truncated }

            if cmd == LC.segment64, cmdsize >= 72 {
                let nsects = Int(readU32(b, p + 64, littleEndian: le))
                guard nsects <= (cmdsize - 72) / 80 else { throw MachOError.truncated }
                var s = p + 72
                for _ in 0..<nsects {
                    let off = Int(readU32(b, s + 48, littleEndian: le))
                    guard off <= sliceSize else { throw MachOError.truncated }
                    if off > 0 { minSectionOffset = min(minSectionOffset, off) }
                    s += 80
                }
            } else if cmd == LC.segment, cmdsize >= 56 {
                let nsects = Int(readU32(b, p + 48, littleEndian: le))
                guard nsects <= (cmdsize - 56) / 68 else { throw MachOError.truncated }
                var s = p + 56
                for _ in 0..<nsects {
                    let off = Int(readU32(b, s + 40, littleEndian: le))
                    guard off <= sliceSize else { throw MachOError.truncated }
                    if off > 0 { minSectionOffset = min(minSectionOffset, off) }
                    s += 68
                }
            } else if cmd == LC.codeSignature {
                codeSigOffset = p
                codeSigSize = cmdsize
            }
            p += cmdsize
        }

        // 计算新命令长度并对齐。
        let align = is64 ? 8 : 4
        var cmdSize = 24 + dylibPath.utf8.count + 1
        cmdSize = (cmdSize + (align - 1)) & ~(align - 1)

        func hasRoom() -> Bool {
            let end = headerSize + Int(sizeofcmds) + cmdSize
            guard end <= minSectionOffset else { return false }
            let writeAbs = loadCommandsStart + Int(sizeofcmds)
            guard writeAbs <= sliceEnd, cmdSize <= sliceEnd - writeAbs else { return false }
            for i in 0..<cmdSize where b[writeAbs + i] != 0 { return false }
            return true
        }

        if !hasRoom(), stripCodeSignature, let csOff = codeSigOffset {
            let tailStart = csOff + codeSigSize
            let end = loadCommandsStart + Int(sizeofcmds)
            if tailStart <= end {
                let moveCount = end - tailStart
                for i in 0..<moveCount { b[csOff + i] = b[tailStart + i] }
                for i in (csOff + moveCount)..<end { b[i] = 0 }
                ncmds -= 1
                sizeofcmds -= UInt32(codeSigSize)
                writeU32(&b, ncmdsOff, ncmds, littleEndian: le)
                writeU32(&b, sizeofcmdsOff, sizeofcmds, littleEndian: le)
                report.strippedSignature = true
                report.messages.append(L("dylib.macho.log.strippedCodeSignature", is64 ? "64" : "32"))
            }
        }

        guard hasRoom() else { throw MachOError.noSpace(arch: is64 ? "64-bit" : "32-bit") }

        let writeAbs = loadCommandsStart + Int(sizeofcmds)
        writeU32(&b, writeAbs + 0, weak ? LC.loadWeakDylib : LC.loadDylib, littleEndian: le)
        writeU32(&b, writeAbs + 4, UInt32(cmdSize), littleEndian: le)
        writeU32(&b, writeAbs + 8, 24, littleEndian: le)  // name.offset
        writeU32(&b, writeAbs + 12, 2, littleEndian: le)  // timestamp
        writeU32(&b, writeAbs + 16, 0, littleEndian: le)  // current_version
        writeU32(&b, writeAbs + 20, 0, littleEndian: le)  // compatibility_version
        for (i, byte) in dylibPath.utf8.enumerated() { b[writeAbs + 24 + i] = byte }

        ncmds += 1
        sizeofcmds += UInt32(cmdSize)
        writeU32(&b, ncmdsOff, ncmds, littleEndian: le)
        writeU32(&b, sizeofcmdsOff, sizeofcmds, littleEndian: le)
        report.injectedSliceCount += 1
        report.messages.append(L("dylib.macho.log.injectedIntoSlice", is64 ? "64" : "32", dylibPath))
    }
}
