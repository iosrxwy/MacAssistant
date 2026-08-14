import Foundation

/// 轻量的 Mach-O 识别工具:仅读取文件头做判定,不依赖外部命令。
public enum MachOIdentifier {

    /// 判断文件是否为 Mach-O(瘦或胖二进制)。
    public static func isMachO(fileAt url: URL) -> Bool {
        guard let magic = readMagic(url) else { return false }
        switch magic.le {
        case 0xFEED_FACF, 0xFEED_FACE, 0xCFFA_EDFE, 0xCEFA_EDFE, 0xBEBA_FECA, 0xBFBA_FECA:
            return true
        default:
            return magic.be == 0xCAFE_BABE || magic.be == 0xCAFE_BABF
        }
    }

    /// 是否为动态库(MH_DYLIB)。对胖二进制读取首个切片判断。
    public static func isDylib(fileAt url: URL) -> Bool {
        machOFileType(fileAt: url) == 0x6 // MH_DYLIB
    }

    /// 读取 Mach-O 的 filetype 字段(瘦二进制或胖二进制首切片)。
    public static func machOFileType(fileAt url: URL) -> UInt32? {
        guard let data = try? readPrefix(url, count: 4096), data.count >= 32 else { return nil }
        let b = [UInt8](data)
        var sliceOffset = 0
        let mBE = u32(b, 0, le: false)
        if mBE == 0xCAFE_BABE || mBE == 0xCAFE_BABF {
            // 胖二进制:取第一个 arch 的 offset。
            sliceOffset = mBE == 0xCAFE_BABF ? Int(u64(b, 16, le: false)) : Int(u32(b, 12, le: false))
        }
        guard sliceOffset + 16 <= b.count else { return nil }
        let magic = u32(b, sliceOffset, le: true)
        let le: Bool
        switch magic {
        case 0xFEED_FACF, 0xFEED_FACE: le = true
        case 0xCFFA_EDFE, 0xCEFA_EDFE: le = false
        default: return nil
        }
        return u32(b, sliceOffset + 12, le: le) // filetype
    }

    // MARK: - 私有

    private static func readMagic(_ url: URL) -> (le: UInt32, be: UInt32)? {
        guard let data = try? readPrefix(url, count: 4), data.count == 4 else { return nil }
        let b = [UInt8](data)
        return (u32(b, 0, le: true), u32(b, 0, le: false))
    }

    private static func readPrefix(_ url: URL, count: Int) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        return (try fh.read(upToCount: count)) ?? Data()
    }

    private static func u32(_ b: [UInt8], _ o: Int, le: Bool) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        let b0 = UInt32(b[o]), b1 = UInt32(b[o + 1]), b2 = UInt32(b[o + 2]), b3 = UInt32(b[o + 3])
        return le ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) : (b3 | (b2 << 8) | (b1 << 16) | (b0 << 24))
    }

    private static func u64(_ b: [UInt8], _ o: Int, le: Bool) -> UInt64 {
        guard o + 8 <= b.count else { return 0 }
        var v: UInt64 = 0
        if le { for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * i) } }
        else { for i in 0..<8 { v = (v << 8) | UInt64(b[o + i]) } }
        return v
    }
}
