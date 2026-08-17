import XCTest
@testable import MacAssistantKit

final class DebServiceTests: XCTestCase {
    func testTarTraversalAndSymlinkEntriesAreRejected() {
        let traversal = DebService.parseTarVerbose(
            "-rw-r--r--  0 root wheel 10 Jan 01 00:00 ../../escape"
        )
        XCTAssertThrowsError(
            try ArchiveSafety.validateEntries(traversal.map { ($0.path, $0.size ?? 0, $0.link) })
        )

        let link = DebService.parseTarVerbose(
            "lrwxr-xr-x  0 root wheel 0 Jan 01 00:00 ./usr/lib/link -> ../../escape"
        )
        XCTAssertThrowsError(
            try ArchiveSafety.validateEntries(link.map { ($0.path, $0.size ?? 0, $0.link) })
        )
    }


    private func metadata(
        architecture: String = "iphoneos-arm64",
        version: String = "1.2.3"
    ) -> DebPackageMetadata {
        DebPackageMetadata(
            packageID: "com.example.fixture",
            name: "Fixture Tweak",
            version: version,
            architecture: architecture,
            description: "Fixture summary\nLong description.\n\nFinal paragraph.",
            maintainer: "Tester <test@example.com>",
            author: "Tester",
            depends: "mobilesubstrate (>= 0.9.5000), firmware (>= 15.0)",
            section: "Tweaks"
        )
    }

    func testParseControlHandlesMultilineDescription() {
        let text = """
        Package: com.example.demo
        Version: 1.2.3
        Architecture: iphoneos-arm64
        Description: Short summary
         Long description line one.
         Long description line two.
        """
        let control = DebService.parseControl(text)
        XCTAssertEqual(control.package, "com.example.demo")
        XCTAssertEqual(control.version, "1.2.3")
        XCTAssertEqual(control.architecture, "iphoneos-arm64")
        XCTAssertTrue(control.descriptionText?.contains("Long description line two.") == true)
    }

    func testBuildInspectExtractRoundTrip() throws {
        guard ExternalTool.dpkgDeb.isAvailable else {
            throw XCTSkip("缺少 dpkg-deb,跳过 deb 往返测试")
        }

        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }

        // 构造包目录:DEBIAN/control + 一个数据文件。
        let pkgDir = root.appendingPathComponent("pkg")
        let debianDir = pkgDir.appendingPathComponent("DEBIAN")
        let binDir = pkgDir.appendingPathComponent("usr/local/bin")
        try FileManager.default.createDirectory(at: debianDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try """
        Package: com.example.roundtrip
        Version: 0.9.0
        Architecture: iphoneos-arm64
        Maintainer: Tester <t@example.com>
        Description: round trip test

        """.write(to: debianDir.appendingPathComponent("control"), atomically: true, encoding: .utf8)
        try "echo hello\n".write(to: binDir.appendingPathComponent("hello"),
                                 atomically: true, encoding: .utf8)

        // 打包。
        let debURL = root.appendingPathComponent("out.deb")
        _ = try DebService.repack(directory: pkgDir, to: debURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: debURL.path))

        // 查看。
        let info = try DebService.inspect(debAt: debURL)
        XCTAssertEqual(info.control.package, "com.example.roundtrip")
        XCTAssertTrue(info.entries.contains { $0.path.hasSuffix("usr/local/bin/hello") },
                      "条目:\(info.entries.map(\.path))")

        // 解包 data。
        let extractDir = root.appendingPathComponent("extract")
        _ = try DebService.extract(debAt: debURL, to: extractDir, dataOnly: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: extractDir.appendingPathComponent("usr/local/bin/hello").path))
    }

    func testMetadataValidationAndControlFormatting() throws {
        XCTAssertThrowsError(
            try DebService.validate(
                metadata: DebPackageMetadata(
                    packageID: "Not A Reverse Domain",
                    name: "Bad",
                    version: "v1",
                    architecture: "iphoneos-arm",
                    description: "",
                    maintainer: ""
                ),
                layout: .rootless
            )
        )

        let control = try DebService.renderControl(metadata())
        XCTAssertTrue(control.hasSuffix("\n"))
        XCTAssertTrue(control.contains("Description: Fixture summary\n Long description.\n .\n Final paragraph."))
        XCTAssertTrue(control.contains("\n Depends:") || control.contains("\nDepends:"))
    }

    func testRootfulAndRootlessPathPlansHaveNoAbsolutePaths() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-plan")
        defer { try? FileManager.default.removeItem(at: root) }
        let dylib = root.appendingPathComponent("Fixture.dylib")
        try Data([0xCA, 0xFE]).write(to: dylib)

        let rootful = try DebService.plan(
            DebPackageRequest(
                metadata: metadata(architecture: "iphoneos-arm"),
                layout: .rootful,
                dylibs: [dylib],
                generatedFilter: TweakFilter(bundles: ["com.apple.springboard"])
            )
        )
        XCTAssertTrue(rootful.entries.contains {
            $0.relativePath == "Library/MobileSubstrate/DynamicLibraries/Fixture.dylib"
        })

        let rootless = try DebService.plan(
            DebPackageRequest(
                metadata: metadata(),
                layout: .rootless,
                dylibs: [dylib],
                generatedFilter: TweakFilter(executables: ["SpringBoard"])
            )
        )
        XCTAssertTrue(rootless.entries.contains {
            $0.relativePath == "var/jb/Library/MobileSubstrate/DynamicLibraries/Fixture.dylib"
        })
        XCTAssertFalse(rootless.entries.contains { $0.relativePath.hasPrefix("/") })
        XCTAssertTrue(rootless.tree.contains("var/"))
    }

    func testStageConvertsDylibInstallNameWithoutTreatingItAsDependency() throws {
        for tool in [ExternalTool.clang, .otool, .installNameTool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-install-name")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.c")
        let dylib = root.appendingPathComponent("ThemeBox.dylib")
        try "int fixture(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let built = try Shell.run(ExternalTool.clang.path!, [
            "-dynamiclib", "-Wl,-install_name,/Library/MobileSubstrate/DynamicLibraries/ThemeBox.dylib",
            "-o", dylib.path, source.path
        ])
        XCTAssertTrue(built.succeeded, built.combinedOutput)

        let package = root.appendingPathComponent("package")
        _ = try DebService.stage(
            DebPackageRequest(
                metadata: metadata(),
                layout: .rootless,
                sourceLayout: .rootful,
                dylibs: [dylib]
            ),
            at: package
        )
        let staged = package.appendingPathComponent(
            "var/jb/Library/MobileSubstrate/DynamicLibraries/ThemeBox.dylib"
        )
        XCTAssertEqual(
            try DylibService.analyze(fileAt: staged).installName,
            "/var/jb/Library/MobileSubstrate/DynamicLibraries/ThemeBox.dylib"
        )
    }

    func testFrameworkOnlyPlanSupportsRoothideLayout() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-framework-plan")
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = root.appendingPathComponent("ProtobufLite3.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: framework.appendingPathComponent("ProtobufLite3"))

        let plan = try DebService.plan(
            DebPackageRequest(
                metadata: metadata(architecture: "iphoneos-arm64e"),
                layout: .roothide,
                dylibs: [],
                extraResources: [framework]
            )
        )

        XCTAssertTrue(plan.entries.contains {
            $0.relativePath == "Library/Frameworks/ProtobufLite3.framework"
        })
        XCTAssertFalse(plan.entries.contains { $0.relativePath.hasPrefix("var/jb/") })
        XCTAssertEqual(DebPackageLayout.roothide.defaultArchitecture, "iphoneos-arm64e")
    }

    func testRoothidePlanRequiresAnArm64eDylib() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-roothide-arch")
        defer { try? FileManager.default.removeItem(at: root) }
        let dylib = root.appendingPathComponent("Fixture.dylib")
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: dylib)

        XCTAssertThrowsError(
            try DebService.plan(
                DebPackageRequest(
                    metadata: metadata(architecture: "iphoneos-arm64e"),
                    layout: .roothide,
                    dylibs: [dylib]
                )
            )
        )
    }

    func testFilterPlistAndMaintainerScriptPermissions() throws {
        let filterData = try DebService.renderFilterPlist(
            TweakFilter(
                bundles: ["com.apple.springboard"],
                executables: ["SpringBoard"],
                classes: ["SBIconController"],
                coreFoundationVersion: [1854.0, 3000.0]
            )
        )
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: filterData, format: nil) as? [String: Any]
        )
        let values = try XCTUnwrap(plist["Filter"] as? [String: Any])
        XCTAssertEqual(values["Executables"] as? [String], ["SpringBoard"])

        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-stage")
        defer { try? FileManager.default.removeItem(at: root) }
        let dylib = root.appendingPathComponent("Fixture.dylib")
        try Data([1, 2, 3]).write(to: dylib)
        let stage = root.appendingPathComponent("package")
        _ = try DebService.stage(
            DebPackageRequest(
                metadata: metadata(),
                layout: .rootless,
                dylibs: [dylib],
                generatedFilter: TweakFilter(executables: ["SpringBoard"]),
                scripts: [.postinst: "echo installed"]
            ),
            at: stage
        )
        let postinst = stage.appendingPathComponent("DEBIAN/postinst")
        let attributes = try FileManager.default.attributesOfItem(atPath: postinst.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertTrue(try String(contentsOf: postinst).hasPrefix("#!/bin/sh\n"))
    }

    func testWizardBuildAndDpkgVerification() throws {
        guard ExternalTool.dpkgDeb.isAvailable else {
            throw XCTSkip("缺少 dpkg-deb")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-wizard-e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let dylib = root.appendingPathComponent("Fixture.dylib")
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: dylib)
        let output = root.appendingPathComponent("fixture.deb")

        let result = try DebService.build(
            DebPackageRequest(
                metadata: metadata(),
                layout: .rootless,
                dylibs: [dylib],
                generatedFilter: TweakFilter(executables: ["SpringBoard"]),
                scripts: [.postinst: "#!/bin/sh\nexit 0\n"]
            ),
            to: output
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(result.infoOutput.contains("com.example.fixture"))
        XCTAssertTrue(result.contentsOutput.contains("var/jb/Library/MobileSubstrate/DynamicLibraries/Fixture.dylib"))
    }

    func testConvertsExistingRootlessDebToRootfulCopy() throws {
        guard ExternalTool.dpkgDeb.isAvailable else { throw XCTSkip("缺少 dpkg-deb") }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-convert")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package")
        let debian = package.appendingPathComponent("DEBIAN")
        let payload = package.appendingPathComponent("var/jb/Library/Test")
        try FileManager.default.createDirectory(at: debian, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try """
        Package: com.example.convert
        Version: 1.0
        Architecture: iphoneos-arm64
        Maintainer: Tester
        Description: fixture

        """.write(to: debian.appendingPathComponent("control"), atomically: true, encoding: .utf8)
        try "fixture".write(to: payload.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("source.deb")
        let output = root.appendingPathComponent("rootful.deb")
        _ = try DebService.repack(directory: package, to: source)
        let sourceHash = try DylibService.sha256(fileAt: source)

        let result = try DebService.convert(
            debAt: source,
            from: .rootless,
            to: .rootful,
            output: output
        )

        XCTAssertEqual(try DylibService.sha256(fileAt: source), sourceHash)
        XCTAssertEqual(result.verification.control.architecture, "iphoneos-arm")
        XCTAssertTrue(result.verification.entries.contains { $0.path.hasSuffix("Library/Test/data.txt") })
        XCTAssertFalse(result.verification.entries.contains { $0.path.contains("var/jb/Library/Test") })
    }

    func testDependencySuggestionsOnlyWriteExplicitlyConfirmedPackageIDs() {
        let suggestions = [
            DebDependencySuggestion(
                installName: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                suggestedPackageID: "mobilesubstrate",
                confidence: .candidate,
                reason: "candidate"
            ),
            DebDependencySuggestion(
                installName: "/Library/Frameworks/Unknown.framework/Unknown",
                suggestedPackageID: nil,
                confidence: .unresolved,
                reason: "unresolved"
            )
        ]
        XCTAssertEqual(
            DebDependencyAdvisor.confirmedPackageIDs(
                from: suggestions,
                confirmedInstallNames: []
            ),
            []
        )
        XCTAssertEqual(
            DebDependencyAdvisor.confirmedPackageIDs(
                from: suggestions,
                confirmedInstallNames: [suggestions[0].installName]
            ),
            ["mobilesubstrate"]
        )
    }
}
