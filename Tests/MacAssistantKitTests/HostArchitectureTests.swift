import XCTest
@testable import MacAssistantKit

final class HostArchitectureTests: XCTestCase {

    func testCurrentFollowsHardwareFlag() {
        XCTAssertEqual(
            HostArchitecture.current,
            HostArchitecture.isAppleSiliconHardware ? .appleSilicon : .intel
        )
    }

    /// Rosetta 只存在于 Apple Silicon,Intel 机器上不允许得出「本进程被转译」的结论。
    func testIntelHostIsNeverTranslated() {
        guard HostArchitecture.current == .intel else { return }
        XCTAssertFalse(HostArchitecture.isTranslated)
    }

    func testHomebrewPrefixPerArchitecture() {
        XCTAssertEqual(HostArchitecture.appleSilicon.homebrewPrefix, "/opt/homebrew")
        XCTAssertEqual(HostArchitecture.intel.homebrewPrefix, "/usr/local")
    }

    func testHomebrewPathsPreferHostPrefixButKeepBoth() {
        let paths = HostArchitecture.homebrewBinaryPaths("ldid")
        XCTAssertEqual(paths.count, HostArchitecture.allCases.count)
        XCTAssertEqual(paths.first, "\(HostArchitecture.current.homebrewPrefix)/bin/ldid")
        XCTAssertEqual(Set(paths), ["/opt/homebrew/bin/ldid", "/usr/local/bin/ldid"])
    }

    /// 任何 Homebrew 工具都必须同时覆盖两种前缀,否则另一类机器上会「装了却找不到」。
    func testHomebrewToolsCoverBothPrefixes() {
        let homebrewTools: [ExternalTool] = [.brew, .dpkgDeb, .ldid, .classDump, .dsdump, .zsign]
        for tool in homebrewTools {
            for arch in HostArchitecture.allCases {
                XCTAssertTrue(
                    tool.preferredPaths.contains { $0.hasPrefix(arch.homebrewPrefix + "/") },
                    "\(tool.rawValue) 缺少 \(arch.homebrewPrefix) 候选路径"
                )
            }
        }
    }

    /// 系统自带工具走 /usr/bin 等固定路径,不应混入 Homebrew 前缀。
    func testSystemToolsDoNotUseHomebrewPaths() {
        for tool in [ExternalTool.otool, .lipo, .codesign, .plistBuddy] {
            XCTAssertTrue(tool.preferredPaths.allSatisfy { $0.hasPrefix("/usr/") }, "\(tool.rawValue)")
        }
    }

    func testSummaryMentionsRosettaOnlyWhenTranslated() {
        let summary = HostArchitecture.summary
        XCTAssertTrue(summary.hasPrefix(HostArchitecture.current.displayName))
        XCTAssertEqual(summary.contains("Rosetta"), HostArchitecture.isTranslated)
    }
}
