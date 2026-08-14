import Foundation

/// Mach-O 一个段(segment)。
public struct MachOSegment: Sendable {
    public let name: String
    public let vmaddr: UInt64
    public let vmsize: UInt64
    public let fileoff: UInt64   // 相对切片起点
    public let filesize: UInt64
    public let sections: [MachOSection]
}

/// Mach-O 一个 section。
public struct MachOSection: Sendable {
    public let segname: String
    public let sectname: String
    public let addr: UInt64
    public let size: UInt64
    public let offset: UInt32    // 相对切片起点的文件偏移
}

/// 一个可执行文件/库的静态事实,用于决定「原生解析」还是「回退外部工具」。
public struct MachOFacts: Sendable {
    public var archs: [String]
    public var isFat: Bool
    public var isEncrypted: Bool        // cryptid == 1(FairPlay 加密壳)
    public var hasChainedFixups: Bool   // LC_DYLD_CHAINED_FIXUPS(arm64e / iOS15+)
    public var hasSwift: Bool           // 含 __swift5_* section
    public var isArm64e: Bool

    /// 原生 ObjC 元数据解析是否适用(未加密、传统指针格式)。
    public var nativeObjCDumpSupported: Bool { !isEncrypted && !hasChainedFixups && !isArm64e }

    public init(archs: [String] = [], isFat: Bool = false, isEncrypted: Bool = false,
                hasChainedFixups: Bool = false, hasSwift: Bool = false, isArm64e: Bool = false) {
        self.archs = archs
        self.isFat = isFat
        self.isEncrypted = isEncrypted
        self.hasChainedFixups = hasChainedFixups
        self.hasSwift = hasSwift
        self.isArm64e = isArm64e
    }
}

/// 纯 Swift 的 Mach-O 只读解析:切片、load command、段/节、cryptid、chained fixups、Swift 探测。
public enum MachOInspector {

    struct Slice { let offset: Int; let is64: Bool; let le: Bool }

    // MARK: 常量
    private enum LC {
        static let reqDyld: UInt32 = 0x8000_0000
        static let segment64: UInt32 = 0x19
        static let segment: UInt32 = 0x01
        static let encryptionInfo: UInt32 = 0x21
        static let encryptionInfo64: UInt32 = 0x2C
        static let dyldChainedFixups: UInt32 = 0x34 | 0x8000_0000
    }

    // MARK: 事实探测

    public static func facts(fileAt url: URL) -> MachOFacts? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let b = [UInt8](data)
        guard let slices = try? parseSlices(b), !slices.isEmpty else { return nil }
        var facts = MachOFacts(isFat: slices.count > 1 || isFatMagic(b))
        for slice in slices {
            let arch = archName(b, slice: slice)
            if let arch { facts.archs.append(arch) }
            if arch == "arm64e" { facts.isArm64e = true }
            scanSlice(b, slice: slice, into: &facts)
        }
        return facts
    }

    private static func scanSlice(_ b: [UInt8], slice: Slice, into facts: inout MachOFacts) {
        let headerSize = slice.is64 ? 32 : 28
        let le = slice.le
        guard slice.offset + headerSize <= b.count else { return }
        let ncmds = Int(readU32(b, slice.offset + 16, le))
        var p = slice.offset + headerSize
        for _ in 0..<ncmds {
            guard p + 8 <= b.count else { break }
            let cmd = readU32(b, p, le)
            let cmdsize = Int(readU32(b, p + 4, le))
            guard cmdsize >= 8, p + cmdsize <= b.count else { break }
            switch cmd {
            case LC.encryptionInfo, LC.encryptionInfo64:
                if p + 20 <= b.count, readU32(b, p + 16, le) != 0 { facts.isEncrypted = true }
            case LC.dyldChainedFixups:
                facts.hasChainedFixups = true
            case LC.segment64:
                scanSegmentSections(b, at: p, is64: true, le: le) { sect in
                    if sect.hasPrefix("__swift5") { facts.hasSwift = true }
                }
            case LC.segment:
                scanSegmentSections(b, at: p, is64: false, le: le) { sect in
                    if sect.hasPrefix("__swift5") { facts.hasSwift = true }
                }
            default:
                break
            }
            p += cmdsize
        }
    }

    private static func scanSegmentSections(_ b: [UInt8], at p: Int, is64: Bool, le: Bool,
                                            _ body: (String) -> Void) {
        if is64 {
            guard p + 72 <= b.count else { return }
            let nsects = Int(readU32(b, p + 64, le))
            var s = p + 72
            for _ in 0..<nsects where s + 80 <= b.count {
                body(cString(b, s, max: 16))
                s += 80
            }
        } else {
            guard p + 56 <= b.count else { return }
            let nsects = Int(readU32(b, p + 48, le))
            var s = p + 56
            for _ in 0..<nsects where s + 68 <= b.count {
                body(cString(b, s, max: 16))
                s += 68
            }
        }
    }

    // MARK: 段/节(供 ObjC 解析使用,针对指定切片)

    /// 解析指定切片的段/节。sliceIndex 越界时取首切片。
    public static func segments(_ b: [UInt8], sliceIndex: Int = 0) -> (sliceOffset: Int, le: Bool, is64: Bool, segments: [MachOSegment])? {
        guard let slices = try? parseSlices(b), !slices.isEmpty else { return nil }
        let slice = sliceIndex < slices.count ? slices[sliceIndex] : slices[0]
        let headerSize = slice.is64 ? 32 : 28
        let le = slice.le
        guard slice.offset + headerSize <= b.count else { return nil }
        let ncmds = Int(readU32(b, slice.offset + 16, le))
        var p = slice.offset + headerSize
        var segs: [MachOSegment] = []
        for _ in 0..<ncmds {
            guard p + 8 <= b.count else { break }
            let cmd = readU32(b, p, le)
            let cmdsize = Int(readU32(b, p + 4, le))
            guard cmdsize >= 8, p + cmdsize <= b.count else { break }
            if cmd == LC.segment64, p + 72 <= b.count {
                let name = cString(b, p + 8, max: 16)
                let vmaddr = readU64(b, p + 24, le)
                let vmsize = readU64(b, p + 32, le)
                let fileoff = readU64(b, p + 40, le)
                let filesize = readU64(b, p + 48, le)
                let nsects = Int(readU32(b, p + 64, le))
                var sects: [MachOSection] = []
                var s = p + 72
                for _ in 0..<nsects where s + 80 <= b.count {
                    sects.append(MachOSection(segname: cString(b, s + 16, max: 16),
                                              sectname: cString(b, s, max: 16),
                                              addr: readU64(b, s + 32, le),
                                              size: readU64(b, s + 40, le),
                                              offset: readU32(b, s + 48, le)))
                    s += 80
                }
                segs.append(MachOSegment(name: name, vmaddr: vmaddr, vmsize: vmsize,
                                         fileoff: fileoff, filesize: filesize, sections: sects))
            }
            p += cmdsize
        }
        return (slice.offset, le, slice.is64, segs)
    }

    /// 选择匹配架构名的切片索引;找不到返回 0(首切片)。
    public static func sliceIndex(_ b: [UInt8], arch: String?) -> Int {
        guard let arch, let slices = try? parseSlices(b) else { return 0 }
        for (i, slice) in slices.enumerated() where archName(b, slice: slice) == arch { return i }
        return 0
    }

    // MARK: 切片解析

    private static func isFatMagic(_ b: [UInt8]) -> Bool {
        guard b.count >= 4 else { return false }
        let be = readU32(b, 0, false)
        let le = readU32(b, 0, true)
        return be == 0xCAFE_BABE || be == 0xCAFE_BABF || le == 0xCAFE_BABE || le == 0xCAFE_BABF
    }

    static func parseSlices(_ b: [UInt8]) throws -> [Slice] {
        guard b.count >= 8 else { throw MachOError.notMachO }
        let beMagic = readU32(b, 0, false)
        if beMagic == 0xCAFE_BABE || beMagic == 0xCAFE_BABF {
            return try fatSlices(b, is64: beMagic == 0xCAFE_BABF, fatLE: false)
        }
        let leMagic = readU32(b, 0, true)
        if leMagic == 0xCAFE_BABE || leMagic == 0xCAFE_BABF {
            return try fatSlices(b, is64: leMagic == 0xCAFE_BABF, fatLE: true)
        }
        switch leMagic {
        case 0xFEED_FACF: return [Slice(offset: 0, is64: true, le: true)]
        case 0xFEED_FACE: return [Slice(offset: 0, is64: false, le: true)]
        case 0xCFFA_EDFE: return [Slice(offset: 0, is64: true, le: false)]
        case 0xCEFA_EDFE: return [Slice(offset: 0, is64: false, le: false)]
        default: throw MachOError.notMachO
        }
    }

    private static func fatSlices(_ b: [UInt8], is64: Bool, fatLE le: Bool) throws -> [Slice] {
        let nfat = Int(readU32(b, 4, le))
        var result: [Slice] = []
        var p = 8
        for _ in 0..<nfat {
            let offset: Int
            if is64 {
                guard p + 32 <= b.count else { throw MachOError.truncated }
                offset = Int(readU64(b, p + 8, le)); p += 32
            } else {
                guard p + 20 <= b.count else { throw MachOError.truncated }
                offset = Int(readU32(b, p + 8, le)); p += 20
            }
            guard offset + 4 <= b.count else { continue }
            let m = readU32(b, offset, true)
            switch m {
            case 0xFEED_FACF: result.append(Slice(offset: offset, is64: true, le: true))
            case 0xFEED_FACE: result.append(Slice(offset: offset, is64: false, le: true))
            case 0xCFFA_EDFE: result.append(Slice(offset: offset, is64: true, le: false))
            case 0xCEFA_EDFE: result.append(Slice(offset: offset, is64: false, le: false))
            default: break
            }
        }
        return result
    }

    private static func archName(_ b: [UInt8], slice: Slice) -> String? {
        guard slice.offset + 12 <= b.count else { return nil }
        let cputype = readU32(b, slice.offset + 4, slice.le)
        let cpusub = readU32(b, slice.offset + 8, slice.le) & 0x00FF_FFFF
        switch cputype {
        case 0x0100_000C: return cpusub == 2 ? "arm64e" : "arm64"
        case 0x0000_000C: return "arm"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        default: return "cpu(\(cputype))"
        }
    }

    // MARK: 字节读取

    static func readU32(_ b: [UInt8], _ o: Int, _ le: Bool) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        let b0 = UInt32(b[o]), b1 = UInt32(b[o + 1]), b2 = UInt32(b[o + 2]), b3 = UInt32(b[o + 3])
        return le ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) : (b3 | (b2 << 8) | (b1 << 16) | (b0 << 24))
    }

    static func readU64(_ b: [UInt8], _ o: Int, _ le: Bool) -> UInt64 {
        guard o + 8 <= b.count else { return 0 }
        var v: UInt64 = 0
        if le { for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * i) } }
        else { for i in 0..<8 { v = (v << 8) | UInt64(b[o + i]) } }
        return v
    }

    static func cString(_ b: [UInt8], _ o: Int, max: Int) -> String {
        var bytes: [UInt8] = []
        var i = o
        while i < b.count, i < o + max, b[i] != 0 { bytes.append(b[i]); i += 1 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
