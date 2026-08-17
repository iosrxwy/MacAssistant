import XCTest
@testable import MacAssistantKit

final class TweakInjectServiceTests: XCTestCase {

    func testRewriteSubstrateFramework() {
        let to = TweakInjectService.rewriteTarget(for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate")
        XCTAssertEqual(to, "@rpath/CydiaSubstrate.framework/CydiaSubstrate")
    }

    func testRewriteGenericFramework() {
        let to = TweakInjectService.rewriteTarget(for: "/Library/Frameworks/Cephei.framework/Cephei")
        XCTAssertEqual(to, "@rpath/Cephei.framework/Cephei")
    }

    func testRewriteMobileSubstrateDylib() {
        let to = TweakInjectService.rewriteTarget(for: "/Library/MobileSubstrate/DynamicLibraries/MyTweak.dylib")
        XCTAssertEqual(to, "@rpath/MyTweak.dylib")
    }

    func testRewriteRootlessVarJB() {
        let to = TweakInjectService.rewriteTarget(for: "/var/jb/usr/lib/libhooker.dylib")
        XCTAssertEqual(to, "@rpath/libhooker.dylib")
    }

    func testSystemLibNotRewritten() {
        XCTAssertNil(TweakInjectService.rewriteTarget(for: "/usr/lib/libSystem.B.dylib"))
        XCTAssertNil(TweakInjectService.rewriteTarget(for: "/usr/lib/libobjc.A.dylib"))
    }

    func testAlreadyRpathNotRewritten() {
        XCTAssertNil(TweakInjectService.rewriteTarget(for: "@rpath/Foo.dylib"))
        XCTAssertNil(TweakInjectService.rewriteTarget(for: "@executable_path/Bar.dylib"))
    }

    func testPlanRewritesDeduplicatesAndFilters() {
        let deps = [
            "/usr/lib/libSystem.B.dylib",
            "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            "@rpath/Already.dylib"
        ]
        let plan = TweakInjectService.planRewrites(for: deps)
        XCTAssertEqual(plan.count, 1)
        XCTAssertTrue(TweakInjectService.requiresSubstrateFramework(plan))
    }

    func testInjectTweaksUsesValidatedWorkflow() throws {
        for tool in [ExternalTool.clang, .otool, .zip, .unzip] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "tweak-plan")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("fixture.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let tweakSource = root.appendingPathComponent("tweak.c")
        try "int tweak_value(void) { return 1; }\n".write(to: tweakSource, atomically: true, encoding: .utf8)

        let dylib = root.appendingPathComponent("Fixture.dylib")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", dylib.path, tweakSource.path]
        ).succeeded)

        let ipaRoot = root.appendingPathComponent("ipa-root")
        let app = ipaRoot.appendingPathComponent("Payload/Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let executable = app.appendingPathComponent("Fixture")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", executable.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "Fixture",
                "CFBundleIdentifier": "com.example.fixture"
            ],
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))

        let ipa = root.appendingPathComponent("Fixture.ipa")
        XCTAssertTrue(try Shell.run(
            ExternalTool.zip.path!,
            ["-qry", ipa.path, "Payload"],
            currentDirectory: ipaRoot
        ).succeeded)

        let output = root.appendingPathComponent("Fixture.injected.ipa")
        let result = try TweakInjectService.injectTweaks(
            ipaAt: ipa,
            options: TweakInjectOptions(tweaks: [dylib], signMethod: .none),
            outputURL: output
        )
        XCTAssertEqual(result.injected, ["Fixture.dylib"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.output.path))

        let verify = root.appendingPathComponent("verify")
        try IpaService.unzip(result.output, to: verify)
        let outputApp = try IpaService.locateApp(in: verify)
        let dependencies = try DylibService.dependencies(
            fileAt: outputApp.appendingPathComponent("Fixture")
        )
        XCTAssertTrue(dependencies.contains { $0.path.hasSuffix("Fixture.dylib") })
    }

    func testInjectTweaksUsesMacOSBundleLayout() throws {
        for tool in [ExternalTool.clang, .otool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "mac-tweak-plan")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("fixture.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let app = root.appendingPathComponent("Fixture.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("Fixture")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", executable.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "Fixture",
                "CFBundleIdentifier": "com.example.fixture"
            ],
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Contents/Info.plist"))

        let dylib = root.appendingPathComponent("Fixture.dylib")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", dylib.path, source.path]
        ).succeeded)

        let output = root.appendingPathComponent("Fixture.injected.app")
        _ = try TweakInjectService.injectTweaks(
            input: .app(app),
            options: TweakInjectOptions(tweaks: [dylib], signMethod: .none),
            outputURL: output
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Contents/Frameworks/Fixture.dylib").path
        ))
        let dependencies = try DylibService.dependencies(
            fileAt: output.appendingPathComponent("Contents/MacOS/Fixture")
        )
        XCTAssertTrue(dependencies.contains { $0.path == "@loader_path/../Frameworks/Fixture.dylib" })
    }
}
