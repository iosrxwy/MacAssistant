import XCTest
@testable import MacAssistantKit

final class DebPluginEligibilityTests: XCTestCase {

    private func entry(_ path: String, mode: String? = nil, isDirectory: Bool = false) -> DebEntry {
        DebEntry(path: path, size: 0, isDirectory: isDirectory, link: nil, mode: mode)
    }

    func testPlainTweakDylibIsEligible() {
        let entries = [
            entry("./Library/MobileSubstrate/DynamicLibraries/MyTweak.dylib", mode: "-rw-r--r--"),
            entry("./Library/MobileSubstrate/DynamicLibraries/MyTweak.plist", mode: "-rw-r--r--")
        ]
        let result = DebPluginEligibilityClassifier.classify(entries: entries)
        XCTAssertTrue(result.isEligibleAsIpaPlugin)
        XCTAssertTrue(result.factors.isEmpty)
    }

    func testLaunchDaemonBlocks() {
        let entries = [entry("./Library/LaunchDaemons/com.foo.daemon.plist")]
        let result = DebPluginEligibilityClassifier.classify(entries: entries)
        XCTAssertFalse(result.isEligibleAsIpaPlugin)
        XCTAssertTrue(result.factors.contains { $0.reason == .launchDaemon })
    }

    func testCommandLineToolBlocks() {
        let entries = [entry("./usr/bin/mytool", mode: "-rwxr-xr-x")]
        let result = DebPluginEligibilityClassifier.classify(entries: entries)
        XCTAssertFalse(result.isEligibleAsIpaPlugin)
        XCTAssertTrue(result.factors.contains { $0.reason == .commandLineTool })
    }

    func testRootlessPrefixNormalizedForToolDetection() {
        let entries = [entry("./var/jb/usr/sbin/daemonctl", mode: "-rwxr-xr-x")]
        let result = DebPluginEligibilityClassifier.classify(entries: entries)
        XCTAssertTrue(result.factors.contains { $0.reason == .commandLineTool })
    }

    func testSetuidBinaryBlocks() {
        let entries = [entry("./usr/local/bin/su-helper", mode: "-rwsr-xr-x")]
        let result = DebPluginEligibilityClassifier.classify(entries: entries)
        XCTAssertTrue(result.factors.contains { $0.reason == .setuidBinary })
    }

    func testSetgidBinaryBlocks() {
        let entries = [entry("./Library/Helper/tool", mode: "-rwxr-sr-x")]
        let result = DebPluginEligibilityClassifier.classify(entries: entries)
        XCTAssertTrue(result.factors.contains { $0.reason == .setgidBinary })
    }

    func testKernelExtensionBlocks() {
        let entries = [entry("./Library/Extensions/Foo.kext/Foo")]
        let result = DebPluginEligibilityClassifier.classify(entries: entries)
        XCTAssertTrue(result.factors.contains { $0.reason == .kernelOrDeviceLevel })
    }

    func testMaintainerScriptExistenceIsASignal() {
        let entries = [entry("./Library/MobileSubstrate/DynamicLibraries/MyTweak.dylib")]
        let result = DebPluginEligibilityClassifier.classify(
            entries: entries,
            maintainerScripts: [.postinst]
        )
        XCTAssertFalse(result.isEligibleAsIpaPlugin)
        XCTAssertTrue(result.factors.contains { $0.reason == .maintainerScript })
    }

    func testFindingsAreBlockers() {
        let entries = [entry("./usr/bin/mytool", mode: "-rwxr-xr-x")]
        let result = DebPluginEligibilityClassifier.classify(entries: entries)
        XCTAssertFalse(result.findings.isEmpty)
        XCTAssertTrue(result.findings.allSatisfy { $0.severity == .blocker })
    }
}
