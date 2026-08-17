import XCTest
@testable import MacAssistantKit

final class TheosProjectServiceTests: XCTestCase {
    func testCreatesEditableRootlessTweakTemplate() throws {
        let project = try FileSystemHelper.makeTemporaryDirectory(prefix: "theos-template")
        defer { try? FileManager.default.removeItem(at: project) }

        let files = try TheosProjectService.createTweakProject(
            in: project,
            request: TheosTweakTemplateRequest(
                name: "DemoTweak",
                packageID: "com.example.demotweak",
                author: "Tester",
                description: "Demo",
                targetBundleID: "com.apple.springboard",
                minimumIOS: "15.0",
                layout: .rootless
            )
        )

        XCTAssertTrue(files.contains { $0.lastPathComponent == "Tweak.xm" })
        let makefile = try String(contentsOf: project.appendingPathComponent("Makefile"))
        XCTAssertTrue(makefile.contains("THEOS_PACKAGE_SCHEME = rootless"))
        XCTAssertTrue(makefile.contains("DemoTweak_FILES = Tweak.xm"))
        let control = try String(contentsOf: project.appendingPathComponent("control"))
        XCTAssertTrue(control.contains("Architecture: iphoneos-arm64"))
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: project.appendingPathComponent("DemoTweak.plist")),
            format: nil
        ) as? [String: [String: [String]]]
        XCTAssertEqual(plist?["Filter"]?["Bundles"], ["com.apple.springboard"])
    }

    func testBuildEnvironmentExposesHomebrewLdidToTheos() {
        XCTAssertEqual(
            TheosProjectService.makeArgumentGroups(clean: true),
            [["clean"], ["package", "THEOS_PACKAGE_SCHEME=rootless", "SCHEME=rootless"]]
        )
        XCTAssertEqual(TheosProjectService.makeArgumentGroups(clean: false, layout: .rootful), [["package"]])
        XCTAssertEqual(
            TheosProjectService.makeArgumentGroups(clean: false, layout: .roothide),
            [["package", "THEOS_PACKAGE_SCHEME=roothide", "SCHEME=roothide"]]
        )
        let environment = TheosProjectService.buildEnvironment(
            theosRoot: URL(fileURLWithPath: "/tmp/theos"),
            ldidPath: "/opt/homebrew/bin/ldid",
            dpkgDebPath: "/opt/homebrew/bin/dpkg-deb",
            base: ["PATH": "/usr/bin:/bin"]
        )
        XCTAssertEqual(environment["THEOS"], "/tmp/theos")
        XCTAssertEqual(environment["TARGET_CODESIGN"], "/opt/homebrew/bin/ldid")
        XCTAssertTrue(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        XCTAssertEqual(
            TheosProjectService.strippingANSI("\u{001B}[0;31merror\u{001B}[m"),
            "error"
        )
    }

    func testDiscoversEditsAndSavesTweakSources() throws {
        let project = try FileSystemHelper.makeTemporaryDirectory(prefix: "theos-project")
        defer { try? FileManager.default.removeItem(at: project) }
        try "include $(THEOS)/makefiles/common.mk\n".write(
            to: project.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8
        )
        let tweak = project.appendingPathComponent("Tweak.xm")
        try "%hook Demo\n%end\n".write(to: tweak, atomically: true, encoding: .utf8)
        let buildDir = project.appendingPathComponent("packages")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try "ignored".write(to: buildDir.appendingPathComponent("Generated.xm"), atomically: true, encoding: .utf8)

        let files = try TheosProjectService.editableFiles(in: project)
        XCTAssertTrue(files.contains { $0.lastPathComponent == tweak.lastPathComponent })
        XCTAssertFalse(files.contains { $0.path.contains("/packages/") })
        try TheosProjectService.save("%hook Updated\n%end\n", to: tweak, in: project)
        XCTAssertEqual(try TheosProjectService.read(tweak, in: project), "%hook Updated\n%end\n")
    }
}
