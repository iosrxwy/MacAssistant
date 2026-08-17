import XCTest
@testable import MacAssistantKit

/// 问题 2:未知 /usr/lib 依赖不能再被当成系统库;应列为「本机无法确认」,产 warning,
/// 但不因此让审计 passed 变 false。
final class IpaAuditUnconfirmedDependencyTests: XCTestCase {

    func testUnknownUsrLibDependencyIsUnconfirmedNotResolvedAndKeepsPassed() throws {
        for tool in [ExternalTool.clang, .otool, .zip, .unzip] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "audit-unconfirmed")
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writeInfoPlist(executable: "Demo", to: app)

        let source = root.appendingPathComponent("source.c")
        try "int main(void){return 0;}\n".write(to: source, atomically: true, encoding: .utf8)

        // 一个 install name 为 /usr/lib 下、但并非已知系统库的伪库;链接后会在插件里留下
        // 指向 /usr/lib/libMysteryVendor.dylib 的 LC_LOAD_DYLIB。构建完即删,不留在产物里。
        let fakeLib = root.appendingPathComponent("libMysteryVendor.dylib")
        XCTAssertTrue(try Shell.run(ExternalTool.clang.path!, [
            "-dynamiclib", "-o", fakeLib.path, source.path,
            "-install_name", "/usr/lib/libMysteryVendor.dylib"
        ]).succeeded)

        let main = app.appendingPathComponent("Demo")
        XCTAssertTrue(try Shell.run(ExternalTool.clang.path!, [
            "-o", main.path, source.path, "-Wl,-headerpad,0x1000"
        ]).succeeded)

        let plugin = root.appendingPathComponent("Plugin.dylib")
        XCTAssertTrue(try Shell.run(ExternalTool.clang.path!, [
            "-dynamiclib", "-o", plugin.path, source.path,
            "-L", root.path, "-lMysteryVendor", "-Wl,-headerpad,0x1000"
        ]).succeeded)
        // 依赖已经写进插件的 load command,原始伪库可删,证明「本机确实无法验证它存在」。
        try FileManager.default.removeItem(at: fakeLib)

        let plan = InjectionPlan(
            input: .app(app),
            items: [InjectionItem(dylibURL: plugin)],
            signing: .none,
            customOutputName: "Out.app"
        )
        let output = root.appendingPathComponent("Result.app")
        let result = try IpaInjectionWorkflow.execute(plan, outputURL: output)

        let audit = result.audit
        // 未确认不等于失败:passed 仍为 true。
        XCTAssertTrue(audit.passed)
        // 未知 /usr/lib 依赖不再冒充系统库被静默吞掉,而是出现在未确认列表里。
        let mystery = audit.unconfirmedDependencies.first {
            $0.installPath == "/usr/lib/libMysteryVendor.dylib"
        }
        XCTAssertNotNil(mystery)
        XCTAssertEqual(mystery?.classification, .unknown)
        XCTAssertTrue(audit.unconfirmedDependencies.allSatisfy {
            $0.classification == .unknown || $0.classification == .deviceProvided
        })
        // 真正的系统库(libSystem 等)属于已解析,不应出现在未确认列表。
        XCTAssertFalse(audit.unconfirmedDependencies.contains {
            $0.fileName.lowercased() == "libsystem.b.dylib"
        })
        // 「确认缺失」列表为空:本机静态分析无法证明设备上的缺失。
        XCTAssertTrue(audit.unresolvedDependencies.isEmpty)
    }

    private func writeInfoPlist(executable: String, to app: URL) throws {
        let plist: [String: Any] = [
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleName": "Demo",
            "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
    }
}
