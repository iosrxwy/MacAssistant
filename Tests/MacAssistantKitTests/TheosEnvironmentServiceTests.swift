import XCTest
@testable import MacAssistantKit

final class TheosEnvironmentServiceTests: XCTestCase {
    func testMissingLdidBlocksTheosBuildReadiness() {
        let snapshot = TheosEnvironmentSnapshot(
            root: URL(fileURLWithPath: "/tmp/theos"),
            hasNIC: true,
            hasTemplates: true,
            availableSDKs: ["iPhoneOS17.0.sdk"],
            hasMake: true,
            hasGit: true,
            hasPerl: true,
            hasXcodeTools: true,
            hasDpkgDeb: true,
            hasLdid: false
        )

        XCTAssertFalse(snapshot.isReadyToBuild)
        XCTAssertTrue(snapshot.missingRequirements.contains("ldid"))
    }

    func testDetectsUserSelectedTheosDirectoryAndSDK() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "theos-environment")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["bin", "makefiles", "templates", "sdks/iPhoneOS17.0.sdk"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }
        try Data().write(to: root.appendingPathComponent("bin/nic.pl"))

        let snapshot = TheosEnvironmentService.inspect(
            preferredRoot: root,
            environment: ["THEOS": root.path],
            homeDirectory: root
        )

        XCTAssertEqual(snapshot.root, root)
        XCTAssertTrue(snapshot.hasNIC)
        XCTAssertTrue(snapshot.hasTemplates)
        XCTAssertTrue(snapshot.availableSDKs.contains("iPhoneOS17.0.sdk"))
        XCTAssertTrue(snapshot.isInstalled)
    }

    func testManagedInstallAndUpdateUseStructuredGitArguments() throws {
        guard Shell.which("git") != nil else { throw XCTSkip("缺少 git") }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "theos-command")
        defer { try? FileManager.default.removeItem(at: root) }
        let installRoot = root.appendingPathComponent("managed/theos")

        let install = try XCTUnwrap(TheosEnvironmentService.managedCommands(root: installRoot).first)
        XCTAssertEqual(
            install.arguments,
            ["clone", "--recursive", TheosEnvironmentService.officialRepositoryURL, installRoot.path]
        )

        try FileManager.default.createDirectory(
            at: installRoot.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let update = try TheosEnvironmentService.managedCommands(root: installRoot)
        XCTAssertEqual(update[0].arguments, ["-C", installRoot.path, "pull", "--ff-only"])
        XCTAssertEqual(
            update[1].arguments,
            ["-C", installRoot.path, "submodule", "update", "--init", "--recursive"]
        )
    }

    func testManagedInstallRejectsOccupiedDestination() throws {
        guard Shell.which("git") != nil else { throw XCTSkip("缺少 git") }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "theos-occupied")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try TheosEnvironmentService.managedCommands(root: root))
    }
}
