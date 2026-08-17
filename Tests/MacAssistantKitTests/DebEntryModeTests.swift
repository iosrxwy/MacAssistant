import XCTest
@testable import MacAssistantKit

final class DebEntryModeTests: XCTestCase {

    func testDpkgContentsPreservesModeString() {
        let listing = """
        -rwsr-xr-x root/root      1234 2020-01-01 00:00 ./usr/bin/su-helper
        drwxr-xr-x root/root         0 2020-01-01 00:00 ./usr/bin/
        """
        let entries = DebService.parseDpkgContents(listing)
        let tool = entries.first { $0.path == "./usr/bin/su-helper" }
        XCTAssertEqual(tool?.mode, "-rwsr-xr-x")

        // 解析出的 mode 必须能驱动设备级判定(setuid + 命令行工具)。
        let eligibility = DebPluginEligibilityClassifier.classify(entries: entries)
        XCTAssertFalse(eligibility.isEligibleAsIpaPlugin)
        XCTAssertTrue(eligibility.factors.contains { $0.reason == .setuidBinary })
        XCTAssertTrue(eligibility.factors.contains { $0.reason == .commandLineTool })
    }
}
