import XCTest
@testable import MacAssistantKit

final class IpaPackageTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }

    private func requireTools(_ tools: [ExternalTool]) throws {
        for tool in tools where !tool.isAvailable {
            throw XCTSkip("缺少工具 \(tool.commandName)")
        }
    }

    private func u32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> UInt32($0 * 8)) & 0xff) }
    }

    private func thinMachO(encrypted: Bool = false) -> Data {
        var bytes = u32(0xFEED_FACF) + u32(0x0100_000C) + u32(0)
        bytes += u32(2) + u32(encrypted ? 1 : 0) + u32(encrypted ? 24 : 0) + u32(0) + u32(0)
        if encrypted {
            bytes += u32(0x2C) + u32(24) + u32(0) + u32(0) + u32(1) + u32(0)
        }
        return Data(bytes)
    }

    private func writeIOSApp(
        at app: URL,
        executable: String = "Demo",
        bundleID: String = "com.example.demo",
        encrypted: Bool = false,
        shortVersion: String = "1.0",
        buildVersion: String = "1"
    ) throws {
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": bundleID,
            "CFBundleName": app.deletingPathExtension().lastPathComponent,
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": buildVersion
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try thinMachO(encrypted: encrypted).write(to: app.appendingPathComponent(executable))
    }

    func testPackageAppBundleProducesPayloadIPA() throws {
        try requireTools([.zip, .unzip])
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-package")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        try writeIOSApp(at: app)

        let result = try IpaService.package(source: app)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputIPA.path))
        XCTAssertEqual(result.bundleIdentifier, "com.example.demo")
        XCTAssertFalse(result.isEncrypted)

        let verify = root.appendingPathComponent("verify")
        try IpaService.unzip(result.outputIPA, to: verify)
        try IpaService.validatePayloadStructure(in: verify)
        XCTAssertEqual(try IpaService.locateApp(in: verify).lastPathComponent, "Demo.app")
    }

    func testPackageReportsFairPlayWithoutDecrypting() throws {
        try requireTools([.zip, .unzip])
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-encrypted")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Store.app")
        try writeIOSApp(at: app, encrypted: true)

        let result = try IpaService.package(source: app)
        XCTAssertTrue(result.isEncrypted)
        XCTAssertTrue(result.log.contains { $0.contains("cryptid=1") })

        let verify = root.appendingPathComponent("verify")
        try IpaService.unzip(result.outputIPA, to: verify)
        let exec = try IpaService.locateApp(in: verify).appendingPathComponent("Demo")
        XCTAssertEqual(MachOInspector.facts(fileAt: exec)?.isEncrypted, true)
    }

    func testPackageXcarchive() throws {
        try requireTools([.zip, .unzip])
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-xcarchive")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Demo.xcarchive")
        let app = archive.appendingPathComponent("Products/Applications/Demo.app")
        try writeIOSApp(at: app)

        let result = try IpaService.package(source: archive)
        XCTAssertEqual(result.appName, "Demo.app")
        try IpaService.unzip(result.outputIPA, to: root.appendingPathComponent("verify"))
        try IpaService.validatePayloadStructure(in: root.appendingPathComponent("verify"))
    }

    func testPackagePayloadDirectory() throws {
        try requireTools([.zip, .unzip])
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-payload")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Payload/Demo.app")
        try writeIOSApp(at: app)

        let result = try IpaService.package(source: root.appendingPathComponent("Payload"))
        XCTAssertEqual(result.bundleIdentifier, "com.example.demo")
    }

    func testRejectsMacAppAndExistingIPA() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-reject")
        defer { try? FileManager.default.removeItem(at: root) }
        let mac = root.appendingPathComponent("Mac.app")
        try FileManager.default.createDirectory(
            at: mac.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try Data().write(to: mac.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try IpaService.package(source: mac)) { error in
            XCTAssertTrue((error as? IpaError) != nil || error.localizedDescription.contains("macOS"))
        }

        let ipa = root.appendingPathComponent("already.ipa")
        try Data("not-a-zip".utf8).write(to: ipa)
        XCTAssertThrowsError(try IpaService.package(source: ipa))
    }

    func testAdoptDeviceArchiveWrapsBareAppZip() throws {
        try requireTools([.zip, .unzip])
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-adopt")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        try writeIOSApp(at: app)
        let zipURL = root.appendingPathComponent("archive.zip")
        let zip = try ExternalTool.zip.run(["-qry", zipURL.path, "Demo.app"], currentDirectory: root)
        XCTAssertTrue(zip.succeeded, zip.combinedOutput)

        let output = root.appendingPathComponent("Demo.ipa")
        let result = try IpaService.adoptDeviceArchive(zipURL, outputURL: output)
        XCTAssertEqual(result.appName, "Demo.app")
        let verify = root.appendingPathComponent("verify")
        try IpaService.unzip(result.outputIPA, to: verify)
        try IpaService.validatePayloadStructure(in: verify)
    }

    func testKeepDataDowngradeRaisesBuildAndKeepsMarketingVersion() throws {
        try requireTools([.zip, .unzip])
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-keep-downgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        try writeIOSApp(at: app, shortVersion: "1.0", buildVersion: "8")
        let ipa = try IpaService.package(source: app).outputIPA

        let prepared = try IpaService.prepareKeepDataDowngrade(
            ipaAt: ipa,
            installedBuild: "20",
            signMethod: .none
        )
        let verify = root.appendingPathComponent("verify")
        try IpaService.unzip(prepared.outputIPA, to: verify)
        let plist = try IpaService.infoPlist(appBundle: try IpaService.locateApp(in: verify))
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "1.0")
        let build = plist["CFBundleVersion"] as? String ?? ""
        XCTAssertEqual(AppVersionOrdering.compare(build, "20"), .orderedDescending)
        XCTAssertEqual(AppVersionOrdering.compare(build, "8"), .orderedDescending)
        XCTAssertTrue(prepared.log.contains { $0.contains("20") || $0.contains("CFBundleVersion") })
    }

    func testKeepDataDowngradeRejectsEncryptedIPA() throws {
        try requireTools([.zip, .unzip])
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-keep-enc")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Store.app")
        try writeIOSApp(at: app, encrypted: true, buildVersion: "1")
        let ipa = try IpaService.package(source: app).outputIPA
        XCTAssertThrowsError(
            try IpaService.prepareKeepDataDowngrade(ipaAt: ipa, installedBuild: "2", signMethod: .none)
        )
    }
}

final class DeviceAppListTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }

    func testParseQuotedAndUnquotedAppLines() {
        let output = """
        Total: 3 apps:
        com.apple.TestFlight - TestFlight
        com.example.myapp - "My App" CFBundleVersion=12 CFBundleShortVersionString=1.2
        com.example.spaces - Cool App CFBundleVersion=3
        ERROR: skip me
        """
        let apps = ConnectedDeviceService.parseInstalledAppsList(output)
        XCTAssertEqual(apps.map(\.bundleIdentifier), [
            "com.apple.TestFlight",
            "com.example.myapp",
            "com.example.spaces"
        ])
        XCTAssertEqual(apps[0].name, "TestFlight")
        XCTAssertEqual(apps[1].name, "My App")
        XCTAssertEqual(apps[1].version, "12")
        XCTAssertEqual(apps[1].shortVersion, "1.2")
        XCTAssertEqual(apps[2].name, "Cool App")
        XCTAssertEqual(apps[2].version, "3")
    }

    func testParseInstalledAppsPlistArray() throws {
        let plist: [[String: Any]] = [
            [
                "CFBundleIdentifier": "com.example.one",
                "CFBundleDisplayName": "One",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "10"
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let apps = try ConnectedDeviceService.parseInstalledAppsPlist(data)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].name, "One")
        XCTAssertEqual(apps[0].shortVersion, "1.0")
    }
}
