import XCTest
@testable import MacAssistantKit

final class MachOInspectorTests: XCTestCase {

    // 构造一个最小 64 位 thin arm64 Mach-O(FEEDFACF),给定若干 load command。
    private func craftThinMachO(cpusubtype: UInt32 = 0, commands: [[UInt8]]) -> [UInt8] {
        var b: [UInt8] = []
        func u32(_ v: UInt32) { for i in 0..<4 { b.append(UInt8((v >> (8 * i)) & 0xff)) } }
        let sizeofcmds = commands.reduce(0) { $0 + $1.count }
        u32(0xFEED_FACF)      // magic
        u32(0x0100_000C)      // cputype arm64
        u32(cpusubtype)       // cpusubtype
        u32(6)                // filetype MH_DYLIB
        u32(UInt32(commands.count))   // ncmds
        u32(UInt32(sizeofcmds))       // sizeofcmds
        u32(0)                // flags
        u32(0)                // reserved
        for c in commands { b.append(contentsOf: c) }
        return b
    }

    private func u32bytes(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
    private func u64bytes(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }

    private func writeTemp(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macho-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    func testDetectsEncryption() throws {
        // LC_ENCRYPTION_INFO_64 (0x2C), cmdsize 24, cryptid=1
        var cmd = u32bytes(0x2C) + u32bytes(24)
        cmd += u32bytes(0)   // cryptoff
        cmd += u32bytes(0)   // cryptsize
        cmd += u32bytes(1)   // cryptid = 1
        cmd += u32bytes(0)   // pad
        let url = try writeTemp(craftThinMachO(commands: [cmd]))
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = MachOInspector.facts(fileAt: url)
        XCTAssertEqual(facts?.isEncrypted, true)
        XCTAssertEqual(facts?.archs, ["arm64"])
        XCTAssertEqual(facts?.nativeObjCDumpSupported, false)
    }

    func testDetectsChainedFixups() throws {
        // LC_DYLD_CHAINED_FIXUPS (0x80000034), linkedit_data_command 16 bytes
        let cmd = u32bytes(0x8000_0034) + u32bytes(16) + u32bytes(0) + u32bytes(0)
        let url = try writeTemp(craftThinMachO(commands: [cmd]))
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = MachOInspector.facts(fileAt: url)
        XCTAssertEqual(facts?.hasChainedFixups, true)
        XCTAssertEqual(facts?.nativeObjCDumpSupported, false)
    }

    func testDetectsArm64eAndSwift() throws {
        // LC_SEGMENT_64 (0x19) 带一个 __swift5_types section
        var seg = u32bytes(0x19)
        let cmdsize = 72 + 80
        seg += u32bytes(UInt32(cmdsize))
        seg += padName("__TEXT", to: 16)          // segname
        seg += u64bytes(0)                          // vmaddr
        seg += u64bytes(0x1000)                     // vmsize
        seg += u64bytes(0)                          // fileoff
        seg += u64bytes(0x1000)                     // filesize
        seg += u32bytes(5) + u32bytes(5)            // maxprot/initprot
        seg += u32bytes(1)                          // nsects
        seg += u32bytes(0)                          // flags
        // section_64
        seg += padName("__swift5_types", to: 16)    // sectname
        seg += padName("__TEXT", to: 16)            // segname
        seg += u64bytes(0) + u64bytes(0)            // addr/size
        seg += u32bytes(0) + u32bytes(0) + u32bytes(0) + u32bytes(0) // offset/align/reloff/nreloc
        seg += u32bytes(0) + u32bytes(0) + u32bytes(0) + u32bytes(0) // flags/reserved123
        let url = try writeTemp(craftThinMachO(cpusubtype: 2, commands: [seg]))
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = MachOInspector.facts(fileAt: url)
        XCTAssertEqual(facts?.isArm64e, true)
        XCTAssertEqual(facts?.archs, ["arm64e"])
        XCTAssertEqual(facts?.hasSwift, true)
    }

    private func padName(_ s: String, to n: Int) -> [UInt8] {
        var bytes = Array(s.utf8)
        while bytes.count < n { bytes.append(0) }
        return Array(bytes.prefix(n))
    }
}
