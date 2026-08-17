import XCTest
@testable import MacAssistantKit

/// 端到端验证 Mach-O 注入器:编译真实的 dylib 与可执行文件,注入后重新签名并运行,
/// 确认被注入的 dylib 构造函数确实被 dyld 加载执行。
final class DylibInjectorTests: XCTestCase {
    private func putU32BE(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xff)
        bytes[offset + 1] = UInt8((value >> 16) & 0xff)
        bytes[offset + 2] = UInt8((value >> 8) & 0xff)
        bytes[offset + 3] = UInt8(value & 0xff)
    }

    private func putU32LE(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xff)
        bytes[offset + 1] = UInt8((value >> 8) & 0xff)
        bytes[offset + 2] = UInt8((value >> 16) & 0xff)
        bytes[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private func putU64LE(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        for index in 0..<8 {
            bytes[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff)
        }
    }

    private func syntheticThin64(cpuType: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x500)
        putU32LE(0xfeedfacf, into: &bytes, at: 0)
        putU32LE(cpuType, into: &bytes, at: 4)
        putU32LE(0, into: &bytes, at: 8)
        putU32LE(2, into: &bytes, at: 12)
        putU32LE(1, into: &bytes, at: 16)
        putU32LE(152, into: &bytes, at: 20)
        putU32LE(0x19, into: &bytes, at: 32)
        putU32LE(152, into: &bytes, at: 36)
        Array("__TEXT".utf8).enumerated().forEach { bytes[40 + $0.offset] = $0.element }
        putU64LE(0x1_0000_0000, into: &bytes, at: 56)
        putU64LE(0x500, into: &bytes, at: 64)
        putU64LE(0, into: &bytes, at: 72)
        putU64LE(0x500, into: &bytes, at: 80)
        putU32LE(7, into: &bytes, at: 88)
        putU32LE(5, into: &bytes, at: 92)
        putU32LE(1, into: &bytes, at: 96)
        Array("__text".utf8).enumerated().forEach { bytes[104 + $0.offset] = $0.element }
        Array("__TEXT".utf8).enumerated().forEach { bytes[120 + $0.offset] = $0.element }
        putU64LE(0x1_0000_0300, into: &bytes, at: 136)
        putU64LE(0x20, into: &bytes, at: 144)
        putU32LE(0x300, into: &bytes, at: 152)
        return bytes
    }

    private func syntheticFat() -> [UInt8] {
        let firstOffset = 0x1000
        let secondOffset = 0x2000
        let sliceSize = 0x500
        var bytes = [UInt8](repeating: 0, count: secondOffset + sliceSize)
        putU32BE(0xcafebabe, into: &bytes, at: 0)
        putU32BE(2, into: &bytes, at: 4)
        putU32BE(0x0100_0007, into: &bytes, at: 8)
        putU32BE(3, into: &bytes, at: 12)
        putU32BE(UInt32(firstOffset), into: &bytes, at: 16)
        putU32BE(UInt32(sliceSize), into: &bytes, at: 20)
        putU32BE(12, into: &bytes, at: 24)
        putU32BE(0x0100_000c, into: &bytes, at: 28)
        putU32BE(0, into: &bytes, at: 32)
        putU32BE(UInt32(secondOffset), into: &bytes, at: 36)
        putU32BE(UInt32(sliceSize), into: &bytes, at: 40)
        putU32BE(12, into: &bytes, at: 44)
        bytes.replaceSubrange(firstOffset..<(firstOffset + sliceSize), with: syntheticThin64(cpuType: 0x0100_0007))
        bytes.replaceSubrange(secondOffset..<(secondOffset + sliceSize), with: syntheticThin64(cpuType: 0x0100_000c))
        return bytes
    }

    private func requireTool(_ tool: ExternalTool) throws -> String {
        guard let path = tool.path else {
            throw XCTSkip("缺少工具 \(tool.commandName),跳过该测试")
        }
        return path
    }

    func testInjectAndRunLoadsDylib() throws {
        let clang = try requireTool(.clang)
        let codesign = try requireTool(.codesign)

        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "InjectTest")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1) 被注入的 dylib:构造函数向 stderr 打印标记。
        let dylibSource = dir.appendingPathComponent("payload.c")
        try """
        #include <stdio.h>
        __attribute__((constructor)) static void payload_init(void) {
            fprintf(stderr, "INJECTED_DYLIB_LOADED\\n");
        }
        """.write(to: dylibSource, atomically: true, encoding: .utf8)

        let dylibURL = dir.appendingPathComponent("libpayload.dylib")
        let buildDylib = try Shell.run(clang, [
            "-dynamiclib", "-o", dylibURL.path, dylibSource.path
        ])
        XCTAssertTrue(buildDylib.succeeded, "编译 dylib 失败:\(buildDylib.combinedOutput)")

        // 2) 目标可执行文件,预留头部填充以保证有插入空间。
        let victimSource = dir.appendingPathComponent("victim.c")
        try """
        #include <stdio.h>
        int main(void) { printf("VICTIM_MAIN\\n"); return 0; }
        """.write(to: victimSource, atomically: true, encoding: .utf8)

        let victimURL = dir.appendingPathComponent("victim")
        let buildVictim = try Shell.run(clang, [
            "-o", victimURL.path, victimSource.path, "-Wl,-headerpad,0x1000"
        ])
        XCTAssertTrue(buildVictim.succeeded, "编译可执行文件失败:\(buildVictim.combinedOutput)")

        // 注入前应能正常运行。
        let before = try Shell.run(victimURL.path, [])
        XCTAssertTrue(before.stdout.contains("VICTIM_MAIN"))

        // 3) 注入 dylib 加载命令。
        let report = try DylibInjector.inject(
            dylibPath: "@executable_path/libpayload.dylib",
            intoFileAt: victimURL,
            stripCodeSignature: true
        )
        XCTAssertGreaterThanOrEqual(report.injectedSliceCount, 1)

        // 4) 原生解析应能读到注入的路径。
        let paths = try DylibInjector.loadedDylibPaths(fileAt: victimURL)
        XCTAssertTrue(paths.contains("@executable_path/libpayload.dylib"),
                      "注入后的依赖列表:\(paths)")

        // 5) 重新 ad-hoc 签名(注入使原签名失效)。
        let sign = try Shell.run(codesign, ["-f", "-s", "-", victimURL.path])
        XCTAssertTrue(sign.succeeded, "重新签名失败:\(sign.combinedOutput)")

        // 6) 运行:应同时看到主程序输出与被注入 dylib 的构造函数输出。
        let after = try Shell.run(victimURL.path, [])
        XCTAssertTrue(after.stdout.contains("VICTIM_MAIN"),
                      "stdout=\(after.stdout) stderr=\(after.stderr)")
        XCTAssertTrue(after.stderr.contains("INJECTED_DYLIB_LOADED"),
                      "注入的 dylib 未被加载。stdout=\(after.stdout) stderr=\(after.stderr)")
    }

    func testRejectsNonMachO() throws {
        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "InjectReject")
        defer { try? FileManager.default.removeItem(at: dir) }
        let txt = dir.appendingPathComponent("hello.txt")
        try "not a mach-o".write(to: txt, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DylibInjector.inject(dylibPath: "@rpath/x.dylib", intoFileAt: txt))
    }

    func testInjectsEveryFatSliceIncludingNonFirstSlice() throws {
        var bytes = syntheticFat()
        var report = InjectionReport()
        try DylibInjector.injectAll(
            &bytes,
            dylibPath: "@rpath/FatPayload.dylib",
            weak: false,
            stripCodeSignature: false,
            report: &report
        )
        XCTAssertEqual(report.injectedSliceCount, 2)
        let paths = try DylibInjector.loadedDylibPathsBySlice(bytes)
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.allSatisfy { $0.contains("@rpath/FatPayload.dylib") })
    }

    func testRejectsDuplicateInjectionAcrossFatSlices() throws {
        var bytes = syntheticFat()
        var report = InjectionReport()
        try DylibInjector.injectAll(
            &bytes,
            dylibPath: "@rpath/Duplicate.dylib",
            weak: false,
            stripCodeSignature: false,
            report: &report
        )
        XCTAssertThrowsError(
            try DylibInjector.injectAll(
                &bytes,
                dylibPath: "@rpath/Duplicate.dylib",
                weak: false,
                stripCodeSignature: false,
                report: &report
            )
        )
    }

    func testRejectsTruncatedAndOverflowingFatSlice() {
        var truncated = [UInt8](repeating: 0, count: 28)
        putU32BE(0xcafebabe, into: &truncated, at: 0)
        putU32BE(2, into: &truncated, at: 4)
        var report = InjectionReport()
        XCTAssertThrowsError(
            try DylibInjector.injectAll(
                &truncated, dylibPath: "@rpath/X.dylib", weak: false,
                stripCodeSignature: false, report: &report
            )
        )

        var malicious = [UInt8](repeating: 0, count: 64)
        putU32BE(0xcafebabf, into: &malicious, at: 0)
        putU32BE(1, into: &malicious, at: 4)
        for index in 16..<24 { malicious[index] = 0xff }
        for index in 24..<32 { malicious[index] = 0xff }
        XCTAssertThrowsError(
            try DylibInjector.injectAll(
                &malicious, dylibPath: "@rpath/X.dylib", weak: false,
                stripCodeSignature: false, report: &report
            )
        )
    }
}
