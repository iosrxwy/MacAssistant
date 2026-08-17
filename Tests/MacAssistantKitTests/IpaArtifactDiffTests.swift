import XCTest
@testable import MacAssistantKit

final class IpaArtifactDiffTests: XCTestCase {

    private func snapshot(
        _ path: String,
        sha: String,
        loads: [MachOLoadCommandSnapshot],
        rpaths: [String] = [],
        signature: DylibSignatureState = .unsigned
    ) -> MachOArtifactSnapshot {
        MachOArtifactSnapshot(
            relativePath: path,
            sha256: sha,
            architectures: ["arm64"],
            slices: [MachOSliceSnapshot(index: 0, loadCommands: loads)],
            dependencies: loads.map(\.path).sorted(),
            rpaths: rpaths,
            signature: signature
        )
    }

    func testDiffDetectsAddedLoadCommandAndAddedFile() {
        let before = [
            snapshot("Payload/App.app/App", sha: "aaa", loads: [
                MachOLoadCommandSnapshot(path: "/usr/lib/libSystem.B.dylib", weak: false)
            ])
        ]
        let after = [
            snapshot("Payload/App.app/App", sha: "bbb", loads: [
                MachOLoadCommandSnapshot(path: "/usr/lib/libSystem.B.dylib", weak: false),
                MachOLoadCommandSnapshot(path: "@rpath/Tweak.dylib", weak: true)
            ]),
            snapshot("Payload/App.app/Frameworks/Tweak.dylib", sha: "ccc", loads: [])
        ]
        let report = IpaInjectionWorkflow.diff(before: before, after: after)

        let main = report.diffs.first { $0.relativePath == "Payload/App.app/App" }
        XCTAssertEqual(main?.change, .modified)
        XCTAssertEqual(main?.addedLoadCommands, ["weak @rpath/Tweak.dylib"])
        XCTAssertTrue(main?.removedLoadCommands.isEmpty ?? false)
        XCTAssertEqual(main?.sha256Changed, true)

        let added = report.diffs.first { $0.relativePath == "Payload/App.app/Frameworks/Tweak.dylib" }
        XCTAssertEqual(added?.change, .added)
        XCTAssertNil(added?.before)
        XCTAssertNotNil(added?.after)

        XCTAssertTrue(report.hasChanges)
        XCTAssertEqual(report.changedPaths.sorted(),
                       ["Payload/App.app/App", "Payload/App.app/Frameworks/Tweak.dylib"])
    }

    func testUnchangedArtifactReportsNoChange() {
        let snap = snapshot("Payload/App.app/App", sha: "aaa", loads: [
            MachOLoadCommandSnapshot(path: "/usr/lib/libSystem.B.dylib", weak: false)
        ])
        let report = IpaInjectionWorkflow.diff(before: [snap], after: [snap])
        XCTAssertEqual(report.diffs.first?.change, .unchanged)
        XCTAssertFalse(report.hasChanges)
        XCTAssertEqual(report.diffs.first?.sha256Changed, false)
    }

    func testRemovedArtifactDetected() {
        let before = [snapshot("Payload/App.app/PlugIns/Ext.appex/Ext", sha: "x", loads: [])]
        let report = IpaInjectionWorkflow.diff(before: before, after: [])
        XCTAssertEqual(report.diffs.first?.change, .removed)
        XCTAssertNotNil(report.diffs.first?.before)
        XCTAssertNil(report.diffs.first?.after)
    }

    /// 端到端:真正注入后,用「重新读取产物」得到的 diff 必须能看到主二进制新增的加载命令,
    /// 以及新增的内嵌 dylib——证明 after 来自产物而非计划值。
    func testAuditDiffFromReReadArtifacts() throws {
        for tool in [ExternalTool.clang, .otool, .zip, .unzip] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "diff-e2e")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("fixture.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let dylib = root.appendingPathComponent("Fixture.dylib")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", dylib.path, source.path]
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
        _ = try TweakInjectService.injectTweaks(
            ipaAt: ipa,
            options: TweakInjectOptions(tweaks: [dylib], signMethod: .none),
            outputURL: output
        )

        let report = try IpaInjectionWorkflow.auditDiff(
            original: .ipa(ipa),
            produced: .ipa(output)
        )

        // 相对路径以 .app 为根,主二进制即 "Fixture"。
        let main = report.diffs.first { $0.relativePath == "Fixture" }
        XCTAssertNotNil(main, "应能定位主二进制的前后对照")
        XCTAssertEqual(main?.change, .modified)
        XCTAssertTrue(
            main?.addedLoadCommands.contains { $0.contains("Fixture.dylib") } ?? false,
            "重读产物应看到新增的 Fixture.dylib 加载命令"
        )
        XCTAssertEqual(main?.sha256Changed, true)

        XCTAssertTrue(
            report.diffs.contains {
                $0.change == .added && $0.relativePath.hasSuffix("Fixture.dylib")
            },
            "内嵌的 Fixture.dylib 应作为新增产物出现在 diff 中"
        )
    }
}
