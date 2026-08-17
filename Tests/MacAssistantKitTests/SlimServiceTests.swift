import XCTest
@testable import MacAssistantKit

final class SlimServiceTests: XCTestCase {

    func testMeasureUnpacked() throws {
        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "slim-measure")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 4096).write(to: dir.appendingPathComponent("a.bin"))
        try Data(count: 4096).write(to: dir.appendingPathComponent("b.bin"))
        XCTAssertGreaterThan(SlimService.measureUnpacked(dir), 0)
    }

    func testRemoveRootDebris() throws {
        let extractDir = try FileSystemHelper.makeTemporaryDirectory(prefix: "slim-debris")
        defer { try? FileManager.default.removeItem(at: extractDir) }
        let symbols = extractDir.appendingPathComponent("Symbols")
        try FileManager.default.createDirectory(at: symbols, withIntermediateDirectories: true)
        try Data([0]).write(to: symbols.appendingPathComponent("x"))
        let dsym = extractDir.appendingPathComponent("Demo.dSYM")
        try FileManager.default.createDirectory(at: dsym, withIntermediateDirectories: true)
        let payload = extractDir.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)

        var log: [String] = []
        try SlimService.removeRootDebris(in: extractDir, log: &log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: symbols.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dsym.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    func testRepackageRefusesToOverwriteExistingOutput() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "slim-output")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Payload/Demo.app"),
            withIntermediateDirectories: true
        )
        let output = root.appendingPathComponent("existing.ipa")
        try Data("keep".utf8).write(to: output)
        XCTAssertThrowsError(try SlimService.repackage(extractDir: root, to: output))
        XCTAssertEqual(try Data(contentsOf: output), Data("keep".utf8))
    }

    /// 端到端:构造含胖二进制(arm64+x86_64)的 IPA,瘦身仅保留 arm64,验证体积下降与架构收敛。
    func testSlimThinsFatBinary() throws {
        for tool in [ExternalTool.clang, .lipo, .zip, .unzip, .codesign] where !tool.isAvailable {
            throw XCTSkip("缺少工具 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "slim-e2e")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("m.c")
        try "int main(void){return 0;}".write(to: src, atomically: true, encoding: .utf8)
        let arm = root.appendingPathComponent("m.arm64")
        let x86 = root.appendingPathComponent("m.x86_64")
        let armR = try Shell.run(ExternalTool.clang.path!, ["-arch", "arm64", "-o", arm.path, src.path])
        let x86R = try Shell.run(ExternalTool.clang.path!, ["-arch", "x86_64", "-o", x86.path, src.path])
        try XCTSkipUnless(armR.succeeded && x86R.succeeded, "交叉编译不可用")

        let app = root.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let exec = app.appendingPathComponent("Demo")
        let fat = try BinaryService.createFat(from: [arm, x86], to: exec)
        try XCTSkipUnless(fat.succeeded, "lipo -create 失败")
        let archsBefore = try BinaryService.architectures(fileAt: exec)
        try XCTSkipUnless(archsBefore.count > 1, "未得到胖二进制")

        let info: [String: Any] = ["CFBundleExecutable": "Demo", "CFBundleIdentifier": "com.example.demo"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        // 根级 Symbols
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Symbols"), withIntermediateDirectories: true)

        let ipa = root.appendingPathComponent("Demo.ipa")
        let zip = try Shell.run(ExternalTool.zip.path!, ["-qry", ipa.path, "Payload", "Symbols"], currentDirectory: root)
        XCTAssertTrue(zip.succeeded, zip.combinedOutput)

        let out = root.appendingPathComponent("Demo.slim.ipa")
        let options = SlimOptions(thinToArch: "arm64", removeArchs: [], stripSymbols: false,
                                  gentleStripFrameworksOnly: false, removeAppDSYM: true,
                                  removeRootDebris: true, signMethod: .codesignAdhoc)
        let result = try SlimService.slim(ipaAt: ipa, options: options, outputURL: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertTrue(result.touchedMachO)

        // 验证:输出的主程序只剩 arm64
        let verify = root.appendingPathComponent("verify")
        try IpaService.unzip(out, to: verify)
        let outApp = try IpaService.locateApp(in: verify)
        let outArchs = try BinaryService.architectures(fileAt: outApp.appendingPathComponent("Demo"))
        XCTAssertEqual(outArchs, ["arm64"])
    }
}
