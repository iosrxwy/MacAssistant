import XCTest
@testable import MacAssistantKit

final class MacAppCloneServiceTests: XCTestCase {
    func testCloneCopiesAppAndRewritesBundleIDGraph() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "macapp-clone")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        let helper = app.appendingPathComponent("Contents/Helpers/Helper.app")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)

        try writeInfo(app, name: "Demo", bundleID: "com.example.demo")
        try writeInfo(helper, name: "Helper", bundleID: "com.example.demo.helper")
        try Data("main".utf8).write(to: app.appendingPathComponent("Demo"))

        let output = try MacAppCloneService.clone(
            appAt: app,
            options: MacAppCloneOptions(
                displayName: "Demo Copy",
                bundleID: "com.example.demo.copy",
                signMethod: .none
            )
        )
        XCTAssertEqual(output.lastPathComponent, "Demo Copy.app")
        let rootInfo = try IpaService.infoPlist(appBundle: output)
        XCTAssertEqual(rootInfo["CFBundleDisplayName"] as? String, "Demo Copy")
        XCTAssertEqual(rootInfo["CFBundleIdentifier"] as? String, "com.example.demo.copy")
        let helperInfo = try IpaService.infoPlist(appBundle: output.appendingPathComponent("Contents/Helpers/Helper.app"))
        XCTAssertEqual(helperInfo["CFBundleIdentifier"] as? String, "com.example.demo.copy.helper")
    }

    private func writeInfo(_ app: URL, name: String, bundleID: String) throws {
        let plist: [String: Any] = [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": bundleID
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
    }
}
