import XCTest
@testable import MacAssistantKit

final class AppInstallPlanTests: XCTestCase {
    func testBuildNumberBumpsAboveInstalled() {
        XCTAssertEqual(AppVersionOrdering.buildNumberAbove("9"), "10")
        XCTAssertEqual(AppVersionOrdering.buildNumberAbove("1.2.3"), "1.2.4")
        XCTAssertEqual(
            AppVersionOrdering.compare(
                AppVersionOrdering.buildNumberForInPlaceDowngrade(ipaBuild: "8", installedBuild: "20"),
                "20"
            ),
            .orderedDescending
        )
        XCTAssertEqual(
            AppVersionOrdering.compare(
                AppVersionOrdering.buildNumberForInPlaceDowngrade(ipaBuild: "1.0.0", installedBuild: "1.2.0"),
                "1.2.0"
            ),
            .orderedDescending
        )
    }

    func testNumericVersionOrdering() {
        XCTAssertEqual(AppVersionOrdering.compare("1.0.0", "1.0.1"), .orderedAscending)
        XCTAssertEqual(AppVersionOrdering.compare("1.2", "1.10"), .orderedAscending)
        XCTAssertEqual(AppVersionOrdering.compare("12", "9"), .orderedDescending)
        XCTAssertEqual(AppVersionOrdering.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(AppVersionOrdering.compare("2.0.0", "1.9.9"), .orderedDescending)
    }

    func testRelationPrefersBuildNumber() {
        let older = InstalledApp(
            bundleIdentifier: "com.example.app",
            name: "Example",
            version: "10",
            shortVersion: "2.0"
        )
        XCTAssertEqual(
            AppVersionOrdering.relation(ipaShort: "1.0", ipaBuild: "11", installed: older),
            .upgrade
        )
        XCTAssertEqual(
            AppVersionOrdering.relation(ipaShort: "3.0", ipaBuild: "9", installed: older),
            .downgrade
        )
        XCTAssertEqual(
            AppVersionOrdering.relation(ipaShort: "2.0", ipaBuild: "10", installed: older),
            .same
        )
        XCTAssertEqual(
            AppVersionOrdering.relation(ipaShort: "1.0", ipaBuild: "1", installed: nil),
            .fresh
        )
    }

    func testPlanRequiresConfirmationOnlyForDowngrade() {
        let identity = IpaIdentity(
            appName: "Demo.app",
            bundleIdentifier: "com.example.demo",
            executableName: "Demo",
            shortVersion: "1.0",
            buildVersion: "1"
        )
        let installed = InstalledApp(
            bundleIdentifier: "com.example.demo",
            name: "Demo",
            version: "5",
            shortVersion: "1.2"
        )
        let downgrade = AppInstallPlan.make(identity: identity, installed: installed)
        XCTAssertEqual(downgrade.relation, .downgrade)
        XCTAssertTrue(downgrade.requiresReplaceConfirmation)

        let fresh = AppInstallPlan.make(identity: identity, installed: nil)
        XCTAssertEqual(fresh.relation, .fresh)
        XCTAssertFalse(fresh.requiresReplaceConfirmation)
    }
}
