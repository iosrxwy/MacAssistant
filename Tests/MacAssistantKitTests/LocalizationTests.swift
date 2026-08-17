import XCTest
@testable import MacAssistantKit

final class LocalizationTests: XCTestCase {
    private var savedOverride: AppLanguage?

    override func setUp() {
        super.setUp()
        savedOverride = LocalizationSettings.override
    }

    override func tearDown() {
        LocalizationSettings.override = savedOverride
        super.tearDown()
    }

    func testExplicitLanguageSelectsMatchingTable() {
        LocalizationSettings.override = .simplifiedChinese
        XCTAssertEqual(SidebarItem.dashboard.title, "系统概览")
        XCTAssertEqual(RiskLevel.danger.label, "危险")

        LocalizationSettings.override = .english
        XCTAssertEqual(SidebarItem.dashboard.title, "Overview")
        XCTAssertEqual(RiskLevel.danger.label, "Danger")
    }

    func testNoLanguageLeaksRawKeys() throws {
        for language in AppLanguage.allCases {
            LocalizationSettings.override = language
            for item in SidebarItem.allCases {
                XCTAssertFalse(
                    item.title.hasPrefix("sidebar."),
                    "\(language.rawValue) 缺少 sidebar.\(item.rawValue)"
                )
            }
        }
    }

    /// 新增语言时最容易漏掉词条,这里逐表比对 key 集合,缺一个就红。
    func testEveryLanguageHasTheSameKeys() throws {
        for target in ["MacAssistantKit", "MacAssistant"] {
            let directory = Self.sourceRoot
                .appendingPathComponent("Sources/\(target)/Localization")
            let reference = try Self.keys(in: directory, language: "zh-Hans")
            XCTAssertFalse(reference.isEmpty, "\(target) 的 zh-Hans 表为空")

            for language in AppLanguage.translations where language != .simplifiedChinese {
                let translated = try Self.keys(in: directory, language: language.rawValue)
                XCTAssertEqual(
                    reference.subtracting(translated).sorted(),
                    [],
                    "\(target)/\(language.rawValue) 缺少词条"
                )
                XCTAssertEqual(
                    translated.subtracting(reference).sorted(),
                    [],
                    "\(target)/\(language.rawValue) 有多余词条"
                )
            }
        }
    }

    /// 词条缺失时 `MALocalizedString` 会把 key 原样返回给用户，而 key 集合比对只能发现
    /// 「某一门语言漏了」，两边一起漏就查不出来。这里反向扫源码里写死的 key，逐个确认有词条。
    func testEveryKeyUsedInSourceHasATranslation() throws {
        for target in ["MacAssistantKit", "MacAssistant"] {
            let directory = Self.sourceRoot
                .appendingPathComponent("Sources/\(target)/Localization")
            var tables: [String: Set<String>] = [:]
            for language in AppLanguage.translations {
                tables[language.rawValue] = try Self.keys(in: directory, language: language.rawValue)
            }

            for (file, key) in try Self.literalKeys(in: target) {
                for (language, table) in tables {
                    XCTAssertTrue(
                        table.contains(key),
                        "\(target)/\(language) 缺少 \"\(key)\"，会把 key 原样显示给用户 (\(file))"
                    )
                }
            }
        }
    }

    /// 只收集写死的 key；`L("risk.\(rawValue)")` 这类拼接的靠 key 集合比对和其它测试兜底。
    private static func literalKeys(in target: String) throws -> [(file: String, key: String)] {
        let root = sourceRoot.appendingPathComponent("Sources/\(target)")
        let pattern = try NSRegularExpression(
            pattern: #"(?:MALocalizedString\(|\bL\()\s*"([^"\\]+)""#
        )
        var found: [(file: String, key: String)] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        for case let url as URL in enumerator ?? .init() where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                found.append((url.lastPathComponent, String(source[keyRange])))
            }
        }
        XCTAssertFalse(found.isEmpty, "\(target) 里没扫到任何本地化调用，扫描逻辑可能失效了")
        return found
    }

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func keys(in directory: URL, language: String) throws -> Set<String> {
        let url = directory
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        let table = try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "无法解析 \(url.path)"
        )
        return Set(table.keys)
    }
}
