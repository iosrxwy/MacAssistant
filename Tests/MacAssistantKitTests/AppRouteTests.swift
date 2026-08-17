import XCTest
@testable import MacAssistantKit

final class AppRouteTests: XCTestCase {
    func testEverySidebarItemRoutesToItsMatchingDetail() {
        let expected: [(SidebarItem, AppDestination)] = [
            (.dashboard, .dashboard),
            (.repair, .repair),
            (.cleanup, .cleanup),
            (.memory, .memory),
            (.network, .network),
            (.cheatsheet, .cheatsheet),
            (.recipes, .recipes),
            (.deb, .deb),
            (.dylib, .dylib),
            (.ipa, .ipa),
            (.macApp, .macApp),
            (.binary, .binary),
            (.environment, .environment),
            (.about, .about),
        ]

        XCTAssertEqual(SidebarItem.allCases.count, expected.count)
        for (item, destination) in expected {
            XCTAssertEqual(item.destination, destination, "\(item) 应路由到 \(destination)")
            XCTAssertEqual(destination.sidebarItem, item, "\(destination) 应返回同一侧栏项")
        }
    }

    func testSidebarIdentityIsUniqueAndStable() {
        let ids = SidebarItem.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, SidebarItem.allCases.map(\.rawValue))
    }
}
