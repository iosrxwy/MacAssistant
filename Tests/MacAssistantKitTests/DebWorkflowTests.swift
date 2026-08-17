import XCTest
@testable import MacAssistantKit

final class DebWorkflowTests: XCTestCase {
    private func requireTools() throws {
        for tool in [ExternalTool.dpkgDeb, .clang, .otool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
    }

    private func buildFixture(in root: URL) throws -> (deb: URL, replacement: URL) {
        let package = root.appendingPathComponent("package")
        let debian = package.appendingPathComponent("DEBIAN")
        let rootful = package.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries")
        let rootless = package.appendingPathComponent("var/jb/usr/lib/duplicate")
        let framework = package.appendingPathComponent("Library/Frameworks/Sample.framework")
        let miscellaneous = package.appendingPathComponent("usr/lib/misc")
        try FileManager.default.createDirectory(at: debian, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootful, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootless, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: miscellaneous, withIntermediateDirectories: true)
        try """
        Package: com.example.workflow
        Name: Workflow Fixture
        Version: 1.0
        Architecture: iphoneos-arm64
        Maintainer: Tester <test@example.com>
        Description: fixture

        """.write(
            to: debian.appendingPathComponent("control"),
            atomically: true,
            encoding: .utf8
        )
        let postinst = debian.appendingPathComponent("postinst")
        try "#!/bin/sh\nexit 0\n".write(to: postinst, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: postinst.path)

        let source = root.appendingPathComponent("fixture.c")
        try "int fixture(void) { return 1; }\n".write(to: source, atomically: true, encoding: .utf8)
        let dylib = root.appendingPathComponent("Foo.dylib")
        let built = try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", dylib.path, source.path]
        )
        XCTAssertTrue(built.succeeded, built.combinedOutput)
        try FileManager.default.copyItem(at: dylib, to: rootful.appendingPathComponent("Foo.dylib"))
        try FileManager.default.copyItem(at: dylib, to: rootless.appendingPathComponent("Foo.dylib"))
        try FileManager.default.copyItem(at: dylib, to: framework.appendingPathComponent("Sample"))
        try FileManager.default.copyItem(at: dylib, to: miscellaneous.appendingPathComponent("NativeLibrary"))

        let executableSource = root.appendingPathComponent("executable.c")
        try "int main(void) { return 0; }\n".write(
            to: executableSource,
            atomically: true,
            encoding: .utf8
        )
        let misleadingDylib = miscellaneous.appendingPathComponent("Misleading.dylib")
        let executableBuild = try Shell.run(
            ExternalTool.clang.path!,
            ["-o", misleadingDylib.path, executableSource.path]
        )
        XCTAssertTrue(executableBuild.succeeded, executableBuild.combinedOutput)

        let filter: [String: Any] = [
            "Filter": [
                "Bundles": ["com.apple.springboard"],
                "Executables": ["SpringBoard"]
            ]
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: filter,
            format: .xml,
            options: 0
        )
        try plist.write(to: rootful.appendingPathComponent("Foo.plist"))
        try plist.write(to: rootless.appendingPathComponent("Foo.plist"))

        let replacementSource = root.appendingPathComponent("replacement.c")
        try "int fixture(void) { return 2; }\n".write(
            to: replacementSource,
            atomically: true,
            encoding: .utf8
        )
        let replacement = root.appendingPathComponent("Replacement.dylib")
        let replacementBuild = try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", replacement.path, replacementSource.path]
        )
        XCTAssertTrue(replacementBuild.succeeded, replacementBuild.combinedOutput)

        let deb = root.appendingPathComponent("fixture.deb")
        _ = try DebService.repack(directory: package, to: deb)
        return (deb, replacement)
    }

    private func buildDylibFreeFixture(in root: URL) throws -> URL {
        let package = root.appendingPathComponent("empty-package")
        let debian = package.appendingPathComponent("DEBIAN")
        let resources = package.appendingPathComponent("usr/share/empty")
        try FileManager.default.createDirectory(at: debian, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try """
        Package: com.example.empty
        Name: Empty Fixture
        Version: 1.0
        Architecture: iphoneos-arm64
        Maintainer: Tester <test@example.com>
        Description: fixture without dylibs

        """.write(
            to: debian.appendingPathComponent("control"),
            atomically: true,
            encoding: .utf8
        )
        try "not a Mach-O\n".write(
            to: resources.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )
        let deb = root.appendingPathComponent("empty.deb")
        _ = try DebService.repack(directory: package, to: deb)
        return deb
    }

    func testSummarizeDylibsFlattensDeepPathsPairsFiltersAndWritesStableManifest() throws {
        try requireTools()
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-workflow")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try buildFixture(in: root)
        let session = try DebArchiveWorkflow.scan(debAt: fixture.deb)
        XCTAssertEqual(session.result.info.control.package, "com.example.workflow")
        XCTAssertEqual(
            DebArchiveWorkflow.dylibArtifacts(in: session, includeFrameworks: false).count,
            3
        )
        XCTAssertEqual(
            DebArchiveWorkflow.dylibArtifacts(in: session, includeFrameworks: true).count,
            4
        )
        XCTAssertTrue(session.result.artifacts.filter { $0.localURL.lastPathComponent == "Foo.dylib" }
            .allSatisfy { $0.companionPlistURL != nil })
        XCTAssertTrue(session.result.artifacts.allSatisfy { !$0.analysis.architectures.isEmpty })
        XCTAssertEqual(
            session.result.artifacts.first {
                $0.localURL.lastPathComponent == "Misleading.dylib"
            }?.kind,
            .executable
        )

        let output = root.appendingPathComponent("flat-output")
        let result = try DebArchiveWorkflow.summarizeDylibs(
            from: session,
            includeFrameworks: false,
            to: output
        )
        XCTAssertEqual(result.manifest.mode, .flat)
        let artifactEntries = result.manifest.entries.filter { $0.companionForArtifactID == nil }
        let plistEntries = result.manifest.entries.filter { $0.companionForArtifactID != nil }
        XCTAssertEqual(artifactEntries.count, 3)
        XCTAssertEqual(plistEntries.count, 2)
        XCTAssertTrue(result.manifest.entries.allSatisfy { !$0.outputRelativePath.contains("/") })
        XCTAssertTrue(artifactEntries.contains {
            $0.sourceRelativePath.hasPrefix("Library/MobileSubstrate/")
        })
        XCTAssertTrue(artifactEntries.contains {
            $0.sourceRelativePath.hasPrefix("var/jb/")
        })
        XCTAssertFalse(artifactEntries.contains {
            $0.sourceRelativePath.contains(".framework/")
                || $0.sourceRelativePath.hasSuffix("Misleading.dylib")
        })

        let duplicateOutputs = artifactEntries.filter {
            $0.sourceRelativePath.hasSuffix("/Foo.dylib")
        }.map(\.outputRelativePath)
        XCTAssertEqual(duplicateOutputs.count, 2)
        XCTAssertEqual(Set(duplicateOutputs).count, 2)
        XCTAssertTrue(duplicateOutputs.allSatisfy { $0.contains("__") })

        for plistEntry in plistEntries {
            let dylibEntry = try XCTUnwrap(artifactEntries.first {
                $0.artifactID == plistEntry.companionForArtifactID
            })
            let artifact = try XCTUnwrap(session.result.artifacts.first {
                $0.id == dylibEntry.artifactID
            })
            let sourcePlist = try XCTUnwrap(artifact.companionPlistURL)
            XCTAssertEqual(
                (plistEntry.outputRelativePath as NSString).deletingPathExtension,
                (dylibEntry.outputRelativePath as NSString).deletingPathExtension
            )
            XCTAssertEqual(plistEntry.sourceRelativePath, artifact.companionPlistRelativePath)
            XCTAssertEqual(plistEntry.sha256, try DylibService.sha256(fileAt: sourcePlist))
            XCTAssertEqual(
                plistEntry.sha256,
                try DylibService.sha256(
                    fileAt: result.outputDirectory.appendingPathComponent(plistEntry.outputRelativePath)
                )
            )
        }

        for entry in artifactEntries {
            let artifact = try XCTUnwrap(session.result.artifacts.first {
                $0.id == entry.artifactID
            })
            XCTAssertEqual(entry.sourceRelativePath, artifact.relativePath)
            XCTAssertEqual(entry.sha256, artifact.analysis.sha256)
            XCTAssertEqual(
                entry.sha256,
                try DylibService.sha256(
                    fileAt: result.outputDirectory.appendingPathComponent(entry.outputRelativePath)
                )
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.manifestURL.path))

        let rootContents = try FileManager.default.contentsOfDirectory(
            at: result.outputDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        XCTAssertEqual(rootContents.count, 6)
        XCTAssertFalse(try rootContents.contains {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        })

        let repeated = try DebArchiveWorkflow.summarizeDylibs(
            from: session,
            includeFrameworks: false,
            to: root.appendingPathComponent("flat-output-repeat")
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: artifactEntries.map {
                ($0.sourceRelativePath, $0.outputRelativePath)
            }),
            Dictionary(uniqueKeysWithValues: repeated.manifest.entries
                .filter { $0.companionForArtifactID == nil }
                .map { ($0.sourceRelativePath, $0.outputRelativePath) })
        )

        let rootlessFoo = try XCTUnwrap(session.result.artifacts.first {
            $0.relativePath.hasPrefix("var/jb/") && $0.localURL.lastPathComponent == "Foo.dylib"
        })
        let preserved = try DebArchiveWorkflow.extract(
            from: session,
            artifactIDs: [rootlessFoo.id],
            mode: .preserveRelativePaths,
            to: root.appendingPathComponent("preserved-output")
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: preserved.outputDirectory.appendingPathComponent(rootlessFoo.relativePath).path
        ))

        let blocked = root.appendingPathComponent("not-empty")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data([1]).write(to: blocked.appendingPathComponent("existing"))
        XCTAssertThrowsError(try DebArchiveWorkflow.extract(
            from: session,
            artifactIDs: Set(session.result.artifacts.map(\.id)),
            mode: .preserveRelativePaths,
            to: blocked
        ))
    }

    func testSummarizeDylibsRejectsArchiveWithoutDylibsAndCreatesNoOutput() throws {
        try requireTools()
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-no-dylibs")
        defer { try? FileManager.default.removeItem(at: root) }
        let deb = try buildDylibFreeFixture(in: root)
        let session = try DebArchiveWorkflow.scan(debAt: deb)
        let output = root.appendingPathComponent("must-not-exist")

        XCTAssertTrue(DebArchiveWorkflow.dylibArtifacts(in: session).isEmpty)
        XCTAssertThrowsError(try DebArchiveWorkflow.summarizeDylibs(
            from: session,
            to: output
        )) { error in
            guard case DebArchiveWorkflowError.noDylibsFound = error else {
                return XCTFail("预期 noDylibsFound，实际为 \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCandidateSessionExposesFilterTargetsAndKeepsURLsAlive() throws {
        try requireTools()
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-candidates")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try buildFixture(in: root)

        let session = try TweakInjectService.candidateSession(inDebAt: fixture.deb)
        XCTAssertEqual(session.candidates.count, 2)
        XCTAssertTrue(session.candidates.allSatisfy {
            $0.filterTargets.executables == ["SpringBoard"]
        })
        XCTAssertTrue(session.candidates.allSatisfy {
            FileManager.default.fileExists(atPath: $0.dylibURL.path)
        })
    }

    func testEditableWorkspaceDiffPreservesScriptModeAndRepackagesWithoutOverwrite() throws {
        try requireTools()
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-edit")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try buildFixture(in: root)
        let workspace = try DebEditableWorkspaceService.create(from: fixture.deb)
        let postinst = workspace.stage.appendingPathComponent("DEBIAN/postinst")
        let mode = (try FileManager.default.attributesOfItem(atPath: postinst.path)[.posixPermissions] as? NSNumber)?
            .intValue
        XCTAssertEqual(mode, 0o755)

        try DebEditableWorkspaceService.replaceDylib(
            in: workspace,
            at: try ValidatedRelativePath("Library/MobileSubstrate/DynamicLibraries/Foo.dylib"),
            with: fixture.replacement
        )
        let changes = try DebEditableWorkspaceService.diff(workspace)
        XCTAssertEqual(changes.filter { $0.kind == .modified }.count, 1)

        let output = root.appendingPathComponent("modified.deb")
        let result = try DebEditableWorkspaceService.repack(workspace, to: output)
        XCTAssertEqual(result.verification.control.package, "com.example.workflow")
        XCTAssertFalse(result.sha256.isEmpty)
        XCTAssertTrue(result.fidelityLimitations.contains { $0.contains("uid/gid") })
        XCTAssertThrowsError(try DebEditableWorkspaceService.repack(workspace, to: output))
    }
}
