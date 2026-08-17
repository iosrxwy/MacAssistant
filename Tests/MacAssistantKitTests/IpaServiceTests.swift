import XCTest
@testable import MacAssistantKit

/// 端到端验证 IPA 注入流程。用 macOS 可执行文件冒充 App 主程序,
/// 因此可在 macOS 上真实运行,验证注入的 dylib 是否被加载。
final class IpaServiceTests: XCTestCase {

    private func requireTools(_ tools: [ExternalTool]) throws {
        for tool in tools where !tool.isAvailable {
            throw XCTSkip("缺少工具 \(tool.commandName),跳过 IPA 测试")
        }
    }

    func testInjectIntoSyntheticIPA() throws {
        try requireTools([.clang, .codesign, .zip, .unzip, .otool])

        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-test")
        defer { try? FileManager.default.removeItem(at: root) }

        // 1) payload dylib
        let dylibSrc = root.appendingPathComponent("payload.c")
        try """
        #include <stdio.h>
        __attribute__((constructor)) static void payload_init(void) {
            fprintf(stderr, "IPA_INJECTED_OK\\n");
        }
        """.write(to: dylibSrc, atomically: true, encoding: .utf8)
        let dylibURL = root.appendingPathComponent("libhook.dylib")
        XCTAssertTrue(try Shell.run(ExternalTool.clang.path!,
            ["-dynamiclib", "-o", dylibURL.path, dylibSrc.path]).succeeded)

        // 2) 主可执行文件(预留头部空间)
        let execSrc = root.appendingPathComponent("app.c")
        try """
        #include <stdio.h>
        int main(void){ printf("APP_RUNNING\\n"); return 0; }
        """.write(to: execSrc, atomically: true, encoding: .utf8)

        // 3) 组装 Payload/Demo.app
        let ipaRoot = root.appendingPathComponent("ipaRoot")
        let appDir = ipaRoot.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let execURL = appDir.appendingPathComponent("Demo")
        XCTAssertTrue(try Shell.run(ExternalTool.clang.path!,
            ["-o", execURL.path, execSrc.path, "-Wl,-headerpad,0x1000"]).succeeded)

        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "Demo",
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleName": "Demo",
            "CFBundleVersion": "1.0"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: appDir.appendingPathComponent("Info.plist"))

        // 4) 打包为 Demo.ipa
        let ipaURL = root.appendingPathComponent("Demo.ipa")
        let zip = try Shell.run(ExternalTool.zip.path!, ["-qry", ipaURL.path, "Payload"],
                                currentDirectory: ipaRoot)
        XCTAssertTrue(zip.succeeded, zip.combinedOutput)

        // 5) 注入
        let options = IpaInjectionOptions(dylibSource: dylibURL,
                                          signMethod: .codesignAdhoc,
                                          embedIntoFrameworks: true)
        let outIPA = root.appendingPathComponent("Demo.injected.ipa")
        let result = try IpaService.inject(ipaAt: ipaURL, options: options, outputURL: outIPA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outIPA.path))
        XCTAssertEqual(result.executableName, "Demo")

        // 6) 解包产物,验证注入路径与 dylib 存在
        let verifyDir = root.appendingPathComponent("verify")
        try IpaService.unzip(outIPA, to: verifyDir)
        let outApp = try IpaService.locateApp(in: verifyDir)
        let outExec = outApp.appendingPathComponent("Demo")
        let deps = try DylibService.dependencies(fileAt: outExec)
        XCTAssertTrue(deps.contains { $0.path.contains("libhook.dylib") },
                      "依赖:\(deps.map(\.path))")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outApp.appendingPathComponent("Frameworks/libhook.dylib").path))

        // 7) 运行验证:主程序输出 + 注入 dylib 构造函数输出
        let run = try Shell.run(outExec.path, [])
        XCTAssertTrue(run.stdout.contains("APP_RUNNING"),
                      "stdout=\(run.stdout) stderr=\(run.stderr)")
        XCTAssertTrue(run.stderr.contains("IPA_INJECTED_OK"),
                      "注入 dylib 未加载。stdout=\(run.stdout) stderr=\(run.stderr)")
    }
}
