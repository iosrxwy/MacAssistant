import XCTest
@testable import MacAssistantKit

private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class InjectionPlanTests: XCTestCase {
    private func putU32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xff)
        bytes[offset + 1] = UInt8((value >> 8) & 0xff)
        bytes[offset + 2] = UInt8((value >> 16) & 0xff)
        bytes[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private func putU64(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        for index in 0..<8 {
            bytes[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff)
        }
    }

    private func syntheticInjectableMachO(fileType: UInt32 = 2) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x500)
        putU32(0xfeedfacf, into: &bytes, at: 0)
        putU32(0x0100_000c, into: &bytes, at: 4)
        putU32(0, into: &bytes, at: 8)
        putU32(fileType, into: &bytes, at: 12)
        putU32(1, into: &bytes, at: 16)
        putU32(152, into: &bytes, at: 20)
        putU32(0x19, into: &bytes, at: 32)
        putU32(152, into: &bytes, at: 36)
        Array("__TEXT".utf8).enumerated().forEach { bytes[40 + $0.offset] = $0.element }
        putU64(0x1_0000_0000, into: &bytes, at: 56)
        putU64(0x500, into: &bytes, at: 64)
        putU64(0, into: &bytes, at: 72)
        putU64(0x500, into: &bytes, at: 80)
        putU32(7, into: &bytes, at: 88)
        putU32(5, into: &bytes, at: 92)
        putU32(1, into: &bytes, at: 96)
        Array("__text".utf8).enumerated().forEach { bytes[104 + $0.offset] = $0.element }
        Array("__TEXT".utf8).enumerated().forEach { bytes[120 + $0.offset] = $0.element }
        putU64(0x1_0000_0300, into: &bytes, at: 136)
        putU64(0x20, into: &bytes, at: 144)
        putU32(0x300, into: &bytes, at: 152)
        return bytes
    }

    private func thinMachO(fileType: UInt32, commands: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] = []
        func appendU32(_ value: UInt32) {
            for index in 0..<4 {
                bytes.append(UInt8((value >> UInt32(index * 8)) & 0xff))
            }
        }
        appendU32(0xfeedfacf)
        appendU32(0x0100_000c)
        appendU32(0)
        appendU32(fileType)
        appendU32(UInt32(commands.count))
        appendU32(UInt32(commands.reduce(0) { $0 + $1.count }))
        appendU32(0)
        appendU32(0)
        commands.forEach { bytes.append(contentsOf: $0) }
        return bytes
    }

    private func dylibCommand(_ path: String, weak: Bool = false) -> [UInt8] {
        let rawSize = 24 + path.utf8.count + 1
        let size = (rawSize + 7) & ~7
        var bytes = [UInt8](repeating: 0, count: size)
        putU32(weak ? 0x8000_0018 : 0x0c, into: &bytes, at: 0)
        putU32(UInt32(size), into: &bytes, at: 4)
        putU32(24, into: &bytes, at: 8)
        for (index, byte) in path.utf8.enumerated() { bytes[24 + index] = byte }
        return bytes
    }

    private func encryptionCommand() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 24)
        putU32(0x2c, into: &bytes, at: 0)
        putU32(24, into: &bytes, at: 4)
        putU32(1, into: &bytes, at: 16)
        return bytes
    }

    private func writePlist(to app: URL, executable: String = "Demo") throws {
        let plist: [String: Any] = [
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleName": "Demo",
            "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
    }

    func testInjectionPlanCodableValidationAndDangerousRemoval() throws {
        let input = URL(fileURLWithPath: "/tmp/Demo.ipa")
        let dylib = URL(fileURLWithPath: "/tmp/Foo.dylib")
        let plan = InjectionPlan(
            input: .ipa(input),
            items: [InjectionItem(dylibURL: dylib, loadKind: .weak)],
            resources: [
                InjectionResource(
                    sourceURL: URL(fileURLWithPath: "/tmp/resource"),
                    destination: try ValidatedRelativePath("Resources/resource")
                )
            ],
            customOutputName: "Demo-custom.ipa"
        )
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(InjectionPlan.self, from: data), plan)
        XCTAssertNoThrow(try plan.validated())
        XCTAssertThrowsError(try ValidatedRelativePath("../escape"))

        var dangerous = plan
        dangerous.components.watch = .remove
        XCTAssertThrowsError(try dangerous.validated())
        dangerous.components.destructiveRemovalConfirmed = true
        XCTAssertNoThrow(try dangerous.validated())
    }

    func testExtractComponentsPreservesRelativePluginPath() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "extract-components")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        let plugin = app.appendingPathComponent("PlugIns/Share.appex")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        let appInfo: [String: Any] = ["CFBundleIdentifier": "com.example.demo"]
        let pluginInfo: [String: Any] = ["CFBundleIdentifier": "com.example.demo.share"]
        for (bundle, info) in [(app, appInfo), (plugin, pluginInfo)] {
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Info.plist"))
        }
        try Data("fixture".utf8).write(to: plugin.appendingPathComponent("payload"))

        let output = try InjectionTargetDiscovery.extractComponents(from: .app(app), to: root)
        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(output[0].path.hasSuffix("Demo-components/PlugIns/Share.appex"))
        XCTAssertEqual(try String(contentsOf: output[0].appendingPathComponent("payload")), "fixture")
    }

    func testTransactionalMultiInjectionWeakAndReplace() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "inject-multi")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("Target")
        try Data(syntheticInjectableMachO()).write(to: executable)

        let report = try DylibInjector.inject(
            requests: [
                DylibInjectionRequest(dylibPath: "@rpath/One.dylib", weak: false),
                DylibInjectionRequest(dylibPath: "@rpath/Two.dylib", weak: true)
            ],
            intoFileAt: executable
        )
        XCTAssertEqual(report.injectedSliceCount, 2)
        var commands = try XCTUnwrap(DylibInjector.inspectLoadCommands(fileAt: executable).first).commands
        XCTAssertEqual(commands.first(where: { $0.path.hasSuffix("One.dylib") })?.weak, false)
        XCTAssertEqual(commands.first(where: { $0.path.hasSuffix("Two.dylib") })?.weak, true)

        _ = try DylibInjector.inject(
            requests: [
                DylibInjectionRequest(
                    dylibPath: "@rpath/One.dylib",
                    weak: true,
                    existingPolicy: .replace
                )
            ],
            intoFileAt: executable
        )
        commands = try XCTUnwrap(DylibInjector.inspectLoadCommands(fileAt: executable).first).commands
        XCTAssertEqual(commands.first(where: { $0.path.hasSuffix("One.dylib") })?.weak, true)
        XCTAssertThrowsError(try DylibInjector.inject(
            requests: [
                DylibInjectionRequest(
                    dylibPath: "@rpath/One.dylib",
                    weak: false,
                    existingPolicy: .skip
                )
            ],
            intoFileAt: executable
        ))
    }

    func testPreflightRejectsCryptidResourceConflictAndMissingDependency() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "preflight-blockers")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writePlist(to: app)
        try Data(thinMachO(fileType: 2, commands: [encryptionCommand()]))
            .write(to: app.appendingPathComponent("Demo"))
        try Data([1]).write(to: app.appendingPathComponent("Existing.dat"))

        let dylib = root.appendingPathComponent("Foo.dylib")
        try Data(thinMachO(
            fileType: 6,
            commands: [dylibCommand("/Library/Frameworks/Missing.framework/Missing")]
        )).write(to: dylib)
        let resource = root.appendingPathComponent("resource.dat")
        try Data([2]).write(to: resource)

        let plan = InjectionPlan(
            input: .app(app),
            items: [InjectionItem(dylibURL: dylib)],
            resources: [
                InjectionResource(
                    sourceURL: resource,
                    destination: try ValidatedRelativePath("Existing.dat")
                )
            ],
            signing: .none
        )
        let report = try IpaInjectionWorkflow.preflight(plan)
        XCTAssertTrue(report.hasBlockers)
        XCTAssertTrue(report.findings.contains { $0.code == "target.cryptid" })
        XCTAssertTrue(report.findings.contains { $0.code == "resource.conflict" })
        XCTAssertTrue(report.findings.contains { $0.code == "dependency.unresolved" })
    }

    func testMultiTargetAppExecutionAndFinalAudit() throws {
        for tool in [ExternalTool.clang, .otool, .zip, .unzip] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "plan-e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        let framework = app.appendingPathComponent("Frameworks/Target.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try writePlist(to: app)
        var info = try IpaService.infoPlist(appBundle: app)
        info["UIBackgroundModes"] = ["audio", "voip"]
        info["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["demo"]]]
        info["CFBundleIcons"] = [
            "CFBundlePrimaryIcon": [
                "CFBundleIconName": "AppIcon",
                "CFBundleIconFiles": ["AppIcon60x60"]
            ]
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))

        let source = root.appendingPathComponent("source.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let main = app.appendingPathComponent("Demo")
        let target = framework.appendingPathComponent("Target")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", main.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", target.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)

        let one = root.appendingPathComponent("One.dylib")
        let two = root.appendingPathComponent("Two.dylib")
        XCTAssertTrue(try Shell.run(ExternalTool.clang.path!, ["-dynamiclib", "-o", one.path, source.path]).succeeded)
        XCTAssertTrue(try Shell.run(ExternalTool.clang.path!, ["-dynamiclib", "-o", two.path, source.path]).succeeded)

        let plan = InjectionPlan(
            input: .app(app),
            items: [
                InjectionItem(dylibURL: one),
                InjectionItem(
                    dylibURL: two,
                    target: .relativeMachO(
                        try ValidatedRelativePath("Frameworks/Target.framework/Target")
                    ),
                    loadKind: .weak
                )
            ],
            metadata: InjectionMetadataChanges(
                enableFileSharing: true,
                repairWhiteIcon: true,
                removeVOIPBackgroundMode: true,
                removeURLSchemes: true
            ),
            signing: .none,
            customOutputName: "Audited.app"
        )
        let output = root.appendingPathComponent("Result.app")
        let streamed = LogCollector()
        let result = try IpaInjectionWorkflow.execute(
            plan,
            outputURL: output,
            progress: { streamed.append($0) }
        )
        XCTAssertEqual(streamed.snapshot, result.log)
        XCTAssertTrue(result.audit.passed)
        XCTAssertEqual(result.audit.entries.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Frameworks/One.dylib").path
        ))
        let outputInfo = try IpaService.infoPlist(appBundle: output)
        XCTAssertEqual(outputInfo["UIFileSharingEnabled"] as? Bool, true)
        XCTAssertEqual(outputInfo["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)
        XCTAssertEqual(outputInfo["UIBackgroundModes"] as? [String], ["audio"])
        XCTAssertNil(outputInfo["CFBundleURLTypes"])
        XCTAssertEqual(outputInfo["CFBundleIconFiles"] as? [String], ["AppIcon60x60"])
        let primaryIcon = (outputInfo["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"]
            as? [String: Any]
        XCTAssertNil(primaryIcon?["CFBundleIconName"])
        let frameworkCommands = try DylibInjector.inspectLoadCommands(
            fileAt: output.appendingPathComponent("Frameworks/Target.framework/Target")
        )
        XCTAssertTrue(frameworkCommands.allSatisfy {
            $0.commands.contains { $0.path.hasSuffix("/Two.dylib") && $0.weak }
        })
    }

    func testReplaceVersionedDylibKeepsOneLoadCommand() throws {
        for tool in [ExternalTool.clang, .otool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "replace-versioned-dylib")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writePlist(to: app)

        let source = root.appendingPathComponent("main.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let main = app.appendingPathComponent("Demo")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", main.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)

        let old = root.appendingPathComponent("WCRefine1.2-3.dylib")
        let newDirectory = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        let new = newDirectory.appendingPathComponent("WCRefine1.2-5.dylib")
        let oldSource = root.appendingPathComponent("old.c")
        let newSource = root.appendingPathComponent("new.c")
        try "int refine(void) { return 3; }\n".write(to: oldSource, atomically: true, encoding: .utf8)
        try "int refine(void) { return 5; }\n".write(to: newSource, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!, ["-dynamiclib", "-o", old.path, oldSource.path]
        ).succeeded)
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!, ["-dynamiclib", "-o", new.path, newSource.path]
        ).succeeded)

        let first = root.appendingPathComponent("First.app")
        _ = try IpaInjectionWorkflow.execute(
            InjectionPlan(input: .app(app), items: [InjectionItem(dylibURL: old)], signing: .none),
            outputURL: first
        )
        let second = root.appendingPathComponent("Second.app")
        _ = try IpaInjectionWorkflow.execute(
            InjectionPlan(
                input: .app(first),
                items: [InjectionItem(dylibURL: new, existingCommandPolicy: .replace)],
                signing: .none
            ),
            outputURL: second
        )

        let oldEmbedded = second.appendingPathComponent("Frameworks/WCRefine1.2-3.dylib")
        let newEmbedded = second.appendingPathComponent("Frameworks/WCRefine1.2-5.dylib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldEmbedded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newEmbedded.path))
        XCTAssertEqual(
            try DylibService.sha256(fileAt: oldEmbedded),
            try DylibService.sha256(fileAt: new)
        )
        let loads = try DylibInjector.loadedDylibPaths(fileAt: second.appendingPathComponent("Demo"))
        XCTAssertEqual(loads.filter { $0.contains("WCRefine") }.count, 1)
        XCTAssertTrue(loads.contains("@executable_path/Frameworks/WCRefine1.2-3.dylib"))
    }

    func testPPQBundleIDIsDeterministicWithFixedSuffix() {
        let changes = InjectionMetadataChanges(
            bundleID: "com.demo.app",
            randomizeBundleIDForPPQ: true,
            ppqBundleSuffix: "ab12cd"
        )
        let resolved = changes.resolvingBundleID(current: "com.other")
        XCTAssertEqual(resolved.bundleID, "com.demo.app.ab12cd")
        XCTAssertEqual(resolved.resolvingBundleID(current: "com.other").bundleID, "com.demo.app.ab12cd")
    }

    func testPPQUsesCurrentBundleIDWhenOverrideMissing() {
        let changes = InjectionMetadataChanges(randomizeBundleIDForPPQ: true, ppqBundleSuffix: "zz99")
        XCTAssertEqual(changes.resolvingBundleID(current: "com.demo.app").bundleID, "com.demo.app.zz99")
    }

    func testInfoPlistMetadataApplierWritesVersionAndMinimumOS() {
        var plist: [String: Any] = [
            "CFBundleIdentifier": "com.demo.app",
            "UIBackgroundModes": ["audio", "voip"]
        ]
        let applied = InfoPlistMetadataApplier.apply(
            InjectionMetadataChanges(
                shortVersion: "2.1",
                buildVersion: "99",
                minimumOSVersion: "16.0",
                enableFileSharing: true,
                removeVOIPBackgroundMode: true
            ),
            to: &plist
        )
        XCTAssertEqual(Set(applied), Set(["shortVersion", "buildVersion", "minimumOSVersion", "fileSharing", "voip"]))
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "2.1")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "99")
        XCTAssertEqual(plist["MinimumOSVersion"] as? String, "16.0")
        XCTAssertEqual(plist["UIFileSharingEnabled"] as? Bool, true)
        XCTAssertEqual(plist["UIBackgroundModes"] as? [String], ["audio"])
    }

    func testLegacyMetadataJSONStillDecodes() throws {
        let json = """
        {"enableFileSharing":true,"repairWhiteIcon":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(InjectionMetadataChanges.self, from: json)
        XCTAssertTrue(decoded.enableFileSharing)
        XCTAssertFalse(decoded.randomizeBundleIDForPPQ)
        XCTAssertNil(decoded.shortVersion)
    }
}
