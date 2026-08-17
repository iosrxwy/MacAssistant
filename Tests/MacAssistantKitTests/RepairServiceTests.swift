import XCTest
@testable import MacAssistantKit

final class RepairServiceTests: XCTestCase {
    /// 断言里写死了中文文案,不固定语言的话在英文系统上会失败。
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }


    // MARK: AdminRunner 转义

    func testAppleScriptEscape() {
        XCTAssertEqual(AdminRunner.appleScriptEscape("echo hi"), "echo hi")
        XCTAssertEqual(AdminRunner.appleScriptEscape(#"say "hi""#), #"say \"hi\""#)
        XCTAssertEqual(AdminRunner.appleScriptEscape(#"a\b"#), #"a\\b"#)
    }

    func testMakeScriptWraps() {
        let script = AdminRunner.makeScript(for: "purge")
        XCTAssertTrue(script.hasPrefix("do shell script \""))
        XCTAssertTrue(script.hasSuffix("\" with administrator privileges"))
        XCTAssertTrue(script.contains("purge"))
    }

    func testAdminRunnerQuotesArgumentsAndRejectsUnknownExecutables() throws {
        let command = try AdminRunner.PrivilegedCommand(
            executable: "/usr/bin/xattr",
            arguments: ["-rd", "com.apple.quarantine", "/tmp/a'; touch /tmp/pwned; echo '.app"]
        )
        XCTAssertTrue(command.shellCommand.contains("'\\''"))
        XCTAssertFalse(command.shellCommand.contains("; touch /tmp/pwned;") && !command.shellCommand.contains("'"))
        XCTAssertThrowsError(
            try AdminRunner.PrivilegedCommand(executable: "/bin/sh", arguments: ["-c", "id"])
        )
    }

    // MARK: shellQuote

    func testShellQuoteWrapsPaths() {
        XCTAssertEqual(RepairService.shellQuote("/Applications/App.app"), "'/Applications/App.app'")
        XCTAssertEqual(RepairService.shellQuote("/tmp/a b.app"), "'/tmp/a b.app'")
    }

    func testShellQuoteEscapesSingleQuote() {
        XCTAssertEqual(RepairService.shellQuote("/tmp/it's.app"), "'/tmp/it'\\''s.app'")
    }

    // MARK: 去隔离命令构造

    func testDequarantineCommandDefault() {
        let cmd = RepairService.dequarantineCommand(appPath: "/Applications/X.app", fullReset: false)
        XCTAssertTrue(cmd.contains("com.apple.quarantine"))
        XCTAssertTrue(cmd.contains("com.apple.provenance"), "默认应同时去除 provenance(Sequoia+)")
        XCTAssertTrue(cmd.contains("'/Applications/X.app'"))
    }

    func testDequarantineCommandFullReset() {
        let cmd = RepairService.dequarantineCommand(appPath: "/Applications/X.app", fullReset: true)
        XCTAssertTrue(cmd.hasPrefix("xattr -cr"))
        XCTAssertFalse(cmd.contains("com.apple.provenance"))
    }

    func testGatekeeperPlanNeverDisablesGlobalPolicy() {
        for major in [13, 14, 15, 26] {
            let plan = RepairService.gatekeeperPlan(
                appPath: "/Applications/X.app",
                macOSMajorVersion: major
            )
            let allText = ([plan.commandPreview, plan.guidance] + plan.diagnosticArguments.flatMap { $0 })
                .joined(separator: " ")
            XCTAssertFalse(allText.contains("master-disable"))
            XCTAssertFalse(allText.contains("global-disable"))
            XCTAssertEqual(plan.settingsURL, RepairService.privacySecurityURL)
            XCTAssertTrue(plan.guidance.contains("仍要打开"))
        }
    }

    func testGatekeeperPlanUsesTypedReadOnlyDiagnostics() {
        let plan = RepairService.gatekeeperPlan(
            appPath: "/Applications/Bad ' Name.app",
            macOSMajorVersion: 26
        )
        XCTAssertEqual(plan.diagnosticExecutables, [
            "/usr/bin/codesign", "/usr/sbin/spctl", "/usr/bin/xattr"
        ])
        XCTAssertEqual(plan.diagnosticArguments[0].last, "/Applications/Bad ' Name.app")
        XCTAssertEqual(plan.diagnosticArguments[1], [
            "--assess", "--type", "execute", "--verbose=4", "/Applications/Bad ' Name.app"
        ])
        XCTAssertTrue(plan.guidance.contains("一小时"))
    }

    // MARK: 重签名预览

    func testResignPreviewIncludesRemoveWhenRequested() {
        let with = RepairService.resignCommandPreview(appPath: "/A.app", removeSignatureFirst: true)
        XCTAssertTrue(with.contains("--remove-signature"))
        XCTAssertFalse(with.contains("--deep"))
        XCTAssertTrue(with.contains("由内向外"))

        let without = RepairService.resignCommandPreview(appPath: "/A.app", removeSignatureFirst: false)
        XCTAssertFalse(without.contains("--remove-signature"))
    }

    // MARK: kill 命令

    func testKillCommand() {
        XCTAssertEqual(RepairService.killCommand(pids: ["123", "456"], force: false), "kill -15 123 456")
        XCTAssertEqual(RepairService.killCommand(pids: ["123"], force: true), "kill -9 123")
        XCTAssertThrowsError(try RepairService.kill(pids: ["123; touch /tmp/pwned"], force: false))
    }

    // MARK: 快照日期解析

    func testParseSnapshotDate() {
        XCTAssertEqual(
            RepairService.parseSnapshotDate("com.apple.TimeMachine.2026-01-07-221601.local"),
            "2026-01-07-221601"
        )
        XCTAssertNil(RepairService.parseSnapshotDate("com.apple.TimeMachine.local"))
    }

    // MARK: 端口范围保护

    func testProcessesRejectsInvalidPort() {
        XCTAssertTrue(RepairService.processes(onPort: 0).isEmpty)
        XCTAssertTrue(RepairService.processes(onPort: 70000).isEmpty)
    }

    // MARK: Rosetta 架构守卫

    func testInstallRosettaRejectedOnIntelHost() throws {
        try XCTSkipIf(
            HostArchitecture.isAppleSiliconHardware,
            "Apple Silicon 上会真实弹出系统授权框,不在单元测试中执行"
        )
        XCTAssertThrowsError(try RepairService.installRosetta()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Apple Silicon"))
        }
    }

    // MARK: 开发缓存目标

    func testDevCacheTargetsNonEmpty() {
        let targets = RepairService.devCacheTargets()
        XCTAssertFalse(targets.isEmpty)
        XCTAssertTrue(targets.contains { $0.id == "xcode-derived" })
        XCTAssertTrue(targets.contains { $0.id == "homebrew" })
    }
}
