import XCTest
@testable import MacAssistantKit

final class CommandLibraryTests: XCTestCase {

    func testHasEnoughEntries() {
        XCTAssertEqual(CommandLibrary.all.count, 262,
                       "应为原有 135 + 去重后的新增 127，实际 \(CommandLibrary.all.count)")
    }

    func testAllFieldsNonEmpty() {
        for entry in CommandLibrary.all {
            XCTAssertFalse(entry.id.trimmingCharacters(in: .whitespaces).isEmpty, "id 不能为空")
            XCTAssertFalse(entry.title.trimmingCharacters(in: .whitespaces).isEmpty, "title 不能为空: \(entry.id)")
            XCTAssertFalse(entry.command.trimmingCharacters(in: .whitespaces).isEmpty, "command 不能为空: \(entry.id)")
            XCTAssertFalse(entry.detail.trimmingCharacters(in: .whitespaces).isEmpty, "detail 不能为空: \(entry.id)")
            XCTAssertFalse(entry.category.trimmingCharacters(in: .whitespaces).isEmpty, "category 不能为空: \(entry.id)")
            if let note = entry.versionNote {
                XCTAssertFalse(note.trimmingCharacters(in: .whitespaces).isEmpty, "versionNote 存在则不能为空: \(entry.id)")
            }
        }
    }

    func testUniqueIDs() {
        let ids = CommandLibrary.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "命令 id 必须唯一")
    }

    func testCategoriesAreLegal() {
        let legal = Set(CommandLibrary.categories)
        for entry in CommandLibrary.all {
            XCTAssertTrue(legal.contains(entry.category), "非法分类: \(entry.category) (\(entry.id))")
        }
    }

    func testEveryCategoryHasEntries() {
        for category in CommandLibrary.categories {
            let count = CommandLibrary.all.filter { $0.category == category }.count
            XCTAssertGreaterThan(count, 0, "分类应至少有 1 条: \(category)")
        }
    }

    func testCoversAllRiskLevels() {
        for risk in RiskLevel.allCases {
            XCTAssertGreaterThan(CommandLibrary.count(of: risk), 0, "应包含风险等级 \(risk.rawValue)")
        }
    }

    func testSearchByKeyword() {
        XCTAssertFalse(CommandLibrary.search("quarantine").isEmpty, "应能搜到去隔离相关命令")
        XCTAssertFalse(CommandLibrary.search("codesign").isEmpty, "应能搜到签名相关命令")
        XCTAssertTrue(CommandLibrary.search("绝不可能出现的关键字zzz").isEmpty)
    }

    func testSearchFilters() {
        let danger = CommandLibrary.search("", risk: .danger)
        XCTAssertTrue(danger.allSatisfy { $0.risk == .danger })

        let network = CommandLibrary.search("", category: "网络")
        XCTAssertTrue(network.allSatisfy { $0.category == "网络" })
        XCTAssertFalse(network.isEmpty)
    }

    func testKeyPainPointsPresent() {
        let commands = CommandLibrary.all.map(\.command).joined(separator: "\n")
        XCTAssertTrue(commands.contains("com.apple.provenance"), "应包含 Sequoia+ provenance 去隔离")
        XCTAssertFalse(commands.contains("spctl --master-disable"), "不得提供全局关闭 Gatekeeper")
        XCTAssertFalse(commands.contains("spctl --global-disable"), "不得提供全局关闭 Gatekeeper")
        XCTAssertTrue(commands.contains("spctl --assess"), "应提供只读 Gatekeeper 评估")
        XCTAssertTrue(commands.contains("dscacheutil -flushcache"), "应包含刷新 DNS")
    }

    func testExpandedScenariosAndDangerClassification() {
        for keyword in ["networkQuality", "screencapture -v", "diskutil eraseDisk", "git reset --hard", "WindowServer", "disablesleep"] {
            XCTAssertFalse(CommandLibrary.search(keyword).isEmpty, "新增场景应可搜索：\(keyword)")
        }
        let dangerousKeywords = ["eraseDisk", "sudo dd", "reset --hard", "WindowServer", "add-trusted-cert", "disablesleep"]
        for keyword in dangerousKeywords {
            let matches = CommandLibrary.search(keyword)
            XCTAssertFalse(matches.isEmpty, "应收录危险参考：\(keyword)")
            XCTAssertTrue(matches.allSatisfy { $0.risk == .danger }, "\(keyword) 必须标红")
        }
    }

    func testUnverifiedDefaultsAreCommentOnly() {
        let unverified = CommandLibrary.all.filter {
            ($0.versionNote ?? "").contains("需验证") || $0.detail.contains("需验证")
        }
        XCTAssertFalse(unverified.isEmpty)
        XCTAssertTrue(unverified.allSatisfy { $0.command.hasPrefix("# 需目标系统验证") })
    }
}
