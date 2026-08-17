import XCTest
@testable import MacAssistantKit

final class TweakFilterEvaluationTests: XCTestCase {

    // MARK: 解析

    func testParseFullFilterKeepsAllFieldsAndUnknowns() {
        let dict: [String: Any] = [
            "Filter": [
                "Bundles": ["com.apple.springboard"],
                "Executables": ["SpringBoard"],
                "Classes": ["SBIconView"],
                "CoreFoundationVersion": [NSNumber(value: 1600.0), NSNumber(value: 1700.0)],
                "Mode": "Any",
                "SomeVendorKey": "x"
            ],
            "ExtraTopLevel": true
        ]
        let filter = TweakInjectService.parseFilter(from: dict)
        XCTAssertEqual(filter.bundles, ["com.apple.springboard"])
        XCTAssertEqual(filter.executables, ["SpringBoard"])
        XCTAssertEqual(filter.classes, ["SBIconView"])
        XCTAssertEqual(filter.coreFoundationVersion, [1600.0, 1700.0])
        XCTAssertEqual(filter.mode, .any)
        XCTAssertEqual(filter.unknownFilterKeys, ["SomeVendorKey"])
        XCTAssertEqual(filter.unknownTopLevelKeys, ["ExtraTopLevel"])
        XCTAssertTrue(filter.hasUnknownFields)
    }

    func testParseUnreadableCoreFoundationVersionIsReportedAsUnknown() {
        let dict: [String: Any] = ["Filter": ["CoreFoundationVersion": "not-a-number"]]
        let filter = TweakInjectService.parseFilter(from: dict)
        XCTAssertTrue(filter.coreFoundationVersion.isEmpty)
        XCTAssertTrue(filter.unknownFilterKeys.contains("CoreFoundationVersion"))
    }

    func testEmptyFilterDefaultsToAllMode() {
        let filter = TweakInjectService.parseFilter(from: [:])
        XCTAssertTrue(filter.isEmpty)
        XCTAssertNil(filter.mode)
        XCTAssertTrue(filter.effectiveMode.isAll)
    }

    // MARK: 比对

    private let identity = TweakFilterTargetIdentity(
        mainBundleID: "com.example.app",
        mainExecutableName: "Example",
        extensionBundleIDs: ["com.example.app.ext"]
    )

    func testBundleMatchProducesMatchNoBlocker() {
        let filter = TweakFilterTargets(bundles: ["com.example.app"])
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .match)
        XCTAssertFalse(eval.isBlocked)
    }

    func testExtensionBundleAlsoCountsAsMatch() {
        let filter = TweakFilterTargets(bundles: ["com.example.app.ext"])
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .match)
    }

    func testBundleMismatchBlocksByDefault() {
        let filter = TweakFilterTargets(bundles: ["com.other.app"])
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .mismatch)
        XCTAssertTrue(eval.isBlocked)
        XCTAssertTrue(eval.findings.contains { $0.code == "filter.mismatch" && $0.severity == .blocker })
    }

    func testMismatchDowngradedWhenAcknowledged() {
        let filter = TweakFilterTargets(bundles: ["com.other.app"])
        let eval = TweakFilterService.evaluate(filter, against: identity, userAcknowledgedMismatch: true)
        XCTAssertEqual(eval.overall, .mismatch)
        XCTAssertFalse(eval.isBlocked)
        XCTAssertTrue(eval.findings.contains { $0.code == "filter.mismatch-overridden" && $0.severity == .warning })
    }

    func testEmptyFilterMatchesEverything() {
        let eval = TweakFilterService.evaluate(TweakFilterTargets(), against: identity)
        XCTAssertEqual(eval.overall, .match)
        XCTAssertFalse(eval.isBlocked)
        XCTAssertTrue(eval.findings.contains { $0.code == "filter.empty" && $0.severity == .info })
    }

    func testClassesOnlyIsIndeterminateNotBlocked() {
        let filter = TweakFilterTargets(classes: ["SBIconView"])
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .indeterminate)
        XCTAssertFalse(eval.isBlocked)
        XCTAssertTrue(eval.findings.contains { $0.code == "filter.classes-indeterminate" })
        let classes = eval.condition(.classes)
        XCTAssertEqual(classes?.result, .indeterminate)
        XCTAssertFalse(classes?.locallyDecidable ?? true)
    }

    func testCoreFoundationVersionIsIndeterminate() {
        let filter = TweakFilterTargets(coreFoundationVersion: [1600])
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .indeterminate)
        XCTAssertTrue(eval.findings.contains { $0.code == "filter.cfversion-indeterminate" })
    }

    func testAnyModeMatchesWhenOneDecidableConditionMatches() {
        // Any: executables 匹配即可,即便 bundles 不匹配。
        let filter = TweakFilterTargets(
            bundles: ["com.other.app"],
            executables: ["Example"],
            mode: .any
        )
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .match)
        XCTAssertFalse(eval.isBlocked)
    }

    func testAllModeIndeterminateWhenDecidableMatchesButIndeterminatePresent() {
        // All: bundles 匹配,但还有无法判定的 classes → 整体无法判定。
        let filter = TweakFilterTargets(
            bundles: ["com.example.app"],
            classes: ["SBIconView"]
        )
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .indeterminate)
    }

    func testAllModeMismatchWhenDecidableConditionFails() {
        let filter = TweakFilterTargets(
            bundles: ["com.other.app"],
            classes: ["SBIconView"]
        )
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .mismatch)
        XCTAssertTrue(eval.isBlocked)
    }

    func testUnknownModeReportedAndTreatedAsAll() {
        let filter = TweakFilterTargets(
            bundles: ["com.example.app"],
            executables: ["Other"],
            mode: TweakFilterMode(rawValue: "Weird")
        )
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertFalse(eval.modeRecognized)
        XCTAssertTrue(eval.findings.contains { $0.code == "filter.mode-unknown" })
        // 按 All 处理:executables 不匹配 → mismatch。
        XCTAssertEqual(eval.overall, .mismatch)
    }

    // MARK: Bundles 三态(问题 1)

    private let identityWithEmbedded = TweakFilterTargetIdentity(
        mainBundleID: "com.example.app",
        mainExecutableName: "Example",
        extensionBundleIDs: ["com.example.app.ext"],
        embeddedBundleIDs: ["com.example.app.CoolFramework", "com.example.res.bundle"]
    )

    func testEmbeddedFrameworkBundleIDCountsAsMatch() {
        // 命中内嵌 framework 的 bundle ID → 可判定匹配,无 blocker。
        let filter = TweakFilterTargets(bundles: ["com.example.app.CoolFramework"])
        let eval = TweakFilterService.evaluate(filter, against: identityWithEmbedded)
        XCTAssertEqual(eval.overall, .match)
        XCTAssertFalse(eval.isBlocked)
        XCTAssertEqual(eval.condition(.bundles)?.result, .match)
        XCTAssertEqual(eval.condition(.bundles)?.matchedValues, ["com.example.app.CoolFramework"])
    }

    func testSystemBundleIsIndeterminateNotBlocker() {
        // com.apple.UIKit 这类系统框架本机无法确认目标是否加载 → indeterminate,绝不产 blocker。
        let filter = TweakFilterTargets(bundles: ["com.apple.UIKit"])
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .indeterminate)
        XCTAssertFalse(eval.isBlocked)
        XCTAssertFalse(eval.findings.contains { $0.severity == .blocker })
        XCTAssertTrue(eval.findings.contains { $0.code == "filter.bundles-indeterminate" })
        let bundles = eval.condition(.bundles)
        XCTAssertEqual(bundles?.result, .indeterminate)
        XCTAssertFalse(bundles?.locallyDecidable ?? true)
    }

    func testSpringBoardBundleIsAlsoIndeterminate() {
        // 本机无可靠手段区分「人人加载的 UIKit」与「独立进程 SpringBoard」,一律 indeterminate。
        let filter = TweakFilterTargets(bundles: ["com.apple.springboard"])
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .indeterminate)
        XCTAssertFalse(eval.isBlocked)
    }

    func testOtherAppBundleStaysMismatchBlocker() {
        // 另一个第三方 App 的 bundle ID:既非本 App 相关又非系统 → 可判定 mismatch,保持 blocker。
        let filter = TweakFilterTargets(bundles: ["com.thirdparty.other"])
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .mismatch)
        XCTAssertTrue(eval.isBlocked)
        XCTAssertEqual(eval.condition(.bundles)?.result, .mismatch)
    }

    func testAppMatchWinsOverSystemBundleInSameList() {
        // 列表里既有系统 bundle 又命中 App 自身 → 命中即可判定匹配。
        let filter = TweakFilterTargets(bundles: ["com.apple.UIKit", "com.example.app"])
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .match)
        XCTAssertFalse(eval.isBlocked)
    }

    func testSystemPlusThirdPartyBundlesAreIndeterminate() {
        // OR 语义:只要还有一个系统 bundle 可能被加载,就不能判成 mismatch。
        let filter = TweakFilterTargets(bundles: ["com.apple.UIKit", "com.thirdparty.other"])
        let eval = TweakFilterService.evaluate(filter, against: identity)
        XCTAssertEqual(eval.overall, .indeterminate)
        XCTAssertFalse(eval.isBlocked)
    }

    func testTargetIdentityReadsEmbeddedBundleIDsFromDisk() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "embedded-bundle-ids")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writeInfoPlist(["CFBundleIdentifier": "com.example.app"], to: app)

        let framework = app.appendingPathComponent("Frameworks/Cool.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try writeInfoPlist(["CFBundleIdentifier": "com.example.app.CoolFramework"], to: framework)

        let bundle = app.appendingPathComponent("Assets.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try writeInfoPlist(["CFBundleIdentifier": "com.example.res.bundle"], to: bundle)

        let ids = TweakFilterService.embeddedBundleIDs(in: app)
        XCTAssertTrue(ids.contains("com.example.app.CoolFramework"))
        XCTAssertTrue(ids.contains("com.example.res.bundle"))

        // excluding 应把主体/已计入项排除,避免重复。
        let deduped = TweakFilterService.embeddedBundleIDs(
            in: app,
            excluding: ["com.example.app.CoolFramework"]
        )
        XCTAssertFalse(deduped.contains("com.example.app.CoolFramework"))
        XCTAssertTrue(deduped.contains("com.example.res.bundle"))
    }

    private func writeInfoPlist(_ dict: [String: Any], to bundle: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"))
    }
}
