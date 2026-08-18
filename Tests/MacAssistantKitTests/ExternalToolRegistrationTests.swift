import XCTest
@testable import MacAssistantKit

final class ExternalToolRegistrationTests: XCTestCase {
    /// 断言里写死了中文文案,不固定语言的话在英文系统上会失败。
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }


    func testNewSystemToolsRegistered() {
        // 系统自带,路径固定,应可解析。
        XCTAssertTrue(ExternalTool.strip.isAvailable, "strip 应随 CLT 存在")
        XCTAssertTrue(ExternalTool.security.isAvailable, "security 系统自带")
        XCTAssertTrue(ExternalTool.plistBuddy.isAvailable, "PlistBuddy 系统自带")
    }

    func testInstallHintsForOptionalTools() {
        let avails = Environment.toolAvailabilities()
        func hint(_ t: ExternalTool) -> String? { avails.first { $0.tool == t }?.installHint }
        XCTAssertNotNil(hint(.classDump))
        XCTAssertNotNil(hint(.dsdump))
        XCTAssertNotNil(hint(.zsign))
        XCTAssertEqual(hint(.ipatool), "brew install ipatool")
    }

    func testCommandNames() {
        XCTAssertEqual(ExternalTool.classDump.commandName, "class-dump")
        XCTAssertEqual(ExternalTool.plistBuddy.commandName, "PlistBuddy")
        XCTAssertEqual(ExternalTool.brew.commandName, "brew")
        XCTAssertEqual(ExternalTool.ideviceID.commandName, "idevice_id")
        XCTAssertEqual(ExternalTool.ideviceInfo.commandName, "ideviceinfo")
        XCTAssertEqual(ExternalTool.ideviceInstaller.commandName, "ideviceinstaller")
        XCTAssertEqual(ExternalTool.xtool.commandName, "xtool")
        XCTAssertEqual(ExternalTool.ipatool.commandName, "ipatool")
    }

    func testHomebrewFormulaCommandUsesFixedArguments() throws {
        let command = try EnvironmentInstaller.makeCommand(
            for: .homebrewFormula("dpkg"),
            brewPath: "/opt/homebrew/bin/brew"
        )
        XCTAssertEqual(command.executable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(command.arguments, ["install", "dpkg"])
        XCTAssertEqual(command.preview, "'/opt/homebrew/bin/brew' install 'dpkg'")

        let ipatool = try EnvironmentInstaller.makeCommand(
            for: .homebrewFormula("ipatool"),
            brewPath: "/opt/homebrew/bin/brew"
        )
        XCTAssertEqual(ipatool.arguments, ["install", "ipatool"])
    }

    func testFormulaValidationRejectsShellInjection() {
        XCTAssertThrowsError(
            try EnvironmentInstaller.makeCommand(
                for: .homebrewFormula("dpkg; touch /tmp/pwned"),
                brewPath: "/opt/homebrew/bin/brew"
            )
        )
    }

    func testMissingHomebrewOnlyOpensOfficialInstructions() {
        guard case let .openProjectPage(url) = ExternalTool.brew.installStrategy else {
            return XCTFail("缺少 Homebrew 时不得生成 curl | bash")
        }
        XCTAssertEqual(url.absoluteString, "https://brew.sh/")
        XCTAssertThrowsError(
            try EnvironmentInstaller.makeCommand(
                for: ExternalTool.brew.installStrategy,
                brewPath: nil
            )
        )
        XCTAssertFalse(EnvironmentInstaller.homebrewGuidance(macOSMajorVersion: 13).contains("支持 macOS 13"))
        XCTAssertTrue(EnvironmentInstaller.homebrewGuidance(macOSMajorVersion: 13).contains("不承诺"))
    }

    func testInstallStrategiesDoNotPretendClassDumpHasFormula() {
        if case let .builtInFallback(description, projectURL) = ExternalTool.classDump.installStrategy {
            XCTAssertTrue(description.contains("内置"))
            XCTAssertEqual(projectURL?.host, "github.com")
        } else {
            XCTFail("class-dump 应使用内置回退策略")
        }

        XCTAssertEqual(ExternalTool.dpkgDeb.installStrategy, .homebrewFormula("dpkg"))
        XCTAssertEqual(ExternalTool.ldid.installStrategy, .homebrewFormula("ldid"))
        XCTAssertEqual(ExternalTool.zsign.installStrategy, .homebrewFormula("zsign"))
        XCTAssertEqual(ExternalTool.ipatool.installStrategy, .homebrewFormula("ipatool"))
    }

    func testFormulaAllowlistRejectsUnregisteredButSyntacticallyValidFormula() {
        XCTAssertThrowsError(
            try EnvironmentInstaller.makeCommand(
                for: .homebrewFormula("unknown-tool"),
                brewPath: "/opt/homebrew/bin/brew"
            )
        )
        XCTAssertThrowsError(
            try EnvironmentInstaller.makeCommand(
                for: .homebrewFormula("dpkg"),
                brewPath: "brew"
            )
        )
    }

    func testEveryExternalToolHasExplicitSupplyChainStrategy() {
        XCTAssertEqual(Set(EnvironmentInstaller.allowedFormulae), Set(["dpkg", "ldid", "zsign", "ipatool"]))
        for tool in ExternalTool.allCases {
            switch tool.installStrategy {
            case let .homebrewFormula(formula):
                XCTAssertTrue(EnvironmentInstaller.allowedFormulae.contains(formula), "\(tool)")
            case .xcodeCommandLineTools, .systemProvided, .openProjectPage, .builtInFallback:
                break
            }
        }
    }

    func testEnvironmentRefreshCreatesCurrentSnapshot() {
        let first = Environment.toolAvailabilities()
        let second = Environment.toolAvailabilities()
        XCTAssertEqual(first.map(\.tool), second.map(\.tool))
        XCTAssertEqual(first.map(\.isAvailable), second.map(\.isAvailable))
    }
}
