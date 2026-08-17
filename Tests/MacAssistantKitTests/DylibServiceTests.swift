import XCTest
@testable import MacAssistantKit

final class DylibServiceTests: XCTestCase {
    func testExtractPayloadsCopiesFrameworkBundleAndResourcePackage() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "dylib-extract")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makePayloadFixture(in: root)

        let destination = root.appendingPathComponent("out", isDirectory: true)
        let result = try DylibService.extractPayloads(from: fixture, to: destination)

        XCTAssertEqual(Set(result.items.map(\.kind)), [.dylib, .framework, .bundle, .resourcePackage, .resource])
        XCTAssertTrue(result.items.contains { $0.kind == .dylib && $0.outputURL.lastPathComponent == "Foo.dylib" })
        XCTAssertTrue(result.items.contains { $0.kind == .resource && $0.outputURL.lastPathComponent == "Foo.plist" })
        XCTAssertTrue(result.items.contains {
            $0.kind == .framework && $0.outputURL.lastPathComponent == "Sample.framework"
        })
        XCTAssertTrue(result.items.contains {
            $0.kind == .bundle && $0.outputURL.lastPathComponent == "Prefs.bundle"
        })
        XCTAssertTrue(result.items.contains {
            $0.kind == .resourcePackage && $0.outputURL.lastPathComponent == "TweakAssets"
        })

        let names = Set(result.items.map(\.outputURL.lastPathComponent))
        XCTAssertFalse(names.contains("Sample"), "framework 内部二进制不应被拆出来")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Sample.framework/Sample").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("TweakAssets/icon.png").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Prefs.bundle/Root.plist").path
            )
        )
    }

    func testExtractPayloadsBatchWritesOneFolderPerSource() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "dylib-extract-batch")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try makePayloadFixture(in: root.appendingPathComponent("one", isDirectory: true))
        let second = root.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try machoData().write(to: second.appendingPathComponent("Bar.dylib"))

        let results = DylibService.extractPayloads(from: [first, second])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].destination.lastPathComponent, "one.extracted")
        XCTAssertEqual(results[1].destination.lastPathComponent, "two.extracted")
        XCTAssertTrue(results[0].items.contains { $0.kind == .framework })
        XCTAssertEqual(results[1].items.map(\.kind), [.dylib])
    }

    func testExtractPayloadsCopiesADroppedFrameworkWhole() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "dylib-extract-fw")
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = root.appendingPathComponent("Alone.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try machoData().write(to: framework.appendingPathComponent("Alone"))
        try Data("plist".utf8).write(to: framework.appendingPathComponent("Info.plist"))

        let destination = root.appendingPathComponent("out", isDirectory: true)
        let result = try DylibService.extractPayloads(from: framework, to: destination)
        XCTAssertEqual(result.items.map(\.kind), [.framework])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Alone.framework/Info.plist").path
            )
        )
        XCTAssertEqual(result.items.count, 1)
    }

    func testExtractPayloadsFromDebKeepsPackages() throws {
        guard ExternalTool.dpkgDeb.isAvailable else {
            throw XCTSkip("缺少 dpkg-deb,跳过 deb 提取测试")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "dylib-extract-deb")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makePayloadFixture(in: root.appendingPathComponent("pkg", isDirectory: true))
        let dylib = fixture.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries/Foo.dylib")
        let framework = fixture.appendingPathComponent("Library/Frameworks/Sample.framework")
        let bundle = fixture.appendingPathComponent("Library/PreferenceBundles/Prefs.bundle")
        let assets = fixture.appendingPathComponent("Library/Application Support/TweakAssets")

        let deb = root.appendingPathComponent("fixture.deb")
        _ = try DebService.build(
            DebPackageRequest(
                metadata: DebPackageMetadata(
                    packageID: "com.example.extract",
                    name: "Extract Fixture",
                    version: "1.0",
                    architecture: "iphoneos-arm64",
                    description: "fixture",
                    maintainer: "Tester <test@example.com>",
                    author: "Tester",
                    depends: "",
                    section: "Tweaks"
                ),
                layout: .rootful,
                dylibs: [dylib],
                extraResources: [framework, bundle, assets]
            ),
            to: deb
        )

        let destination = root.appendingPathComponent("out", isDirectory: true)
        let result = try DylibService.extractPayloads(from: deb, to: destination)
        XCTAssertTrue(result.items.contains { $0.kind == .dylib })
        XCTAssertTrue(result.items.contains { $0.kind == .framework && $0.outputURL.lastPathComponent == "Sample.framework" })
        XCTAssertTrue(result.items.contains { $0.kind == .bundle && $0.outputURL.lastPathComponent == "Prefs.bundle" })
        XCTAssertTrue(result.items.contains { $0.kind == .resourcePackage && $0.outputURL.lastPathComponent == "TweakAssets" })
    }

    func testExtractPayloadsRemovesEmptyDestination() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "dylib-extract-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)

        let result = try DylibService.extractPayloads(from: empty, to: destination)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertNil(result.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExtractPayloadsWalksIntoAppInsteadOfCopyingItWhole() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "dylib-extract-app")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        let frameworks = app.appendingPathComponent("Frameworks/Kit.framework")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try machoData().write(to: app.appendingPathComponent("Demo"))
        try machoData().write(to: frameworks.appendingPathComponent("Kit"))
        try Data("plist".utf8).write(to: frameworks.appendingPathComponent("Info.plist"))

        let destination = root.appendingPathComponent("out", isDirectory: true)
        let result = try DylibService.extractPayloads(from: app, to: destination)
        XCTAssertFalse(result.items.contains { $0.outputURL.lastPathComponent == "Demo.app" })
        XCTAssertTrue(result.items.contains { $0.kind == .framework && $0.outputURL.lastPathComponent == "Kit.framework" })
        XCTAssertTrue(result.items.contains { $0.kind == .machO && $0.outputURL.lastPathComponent == "Demo" })
    }

    func testExtractPayloadsCopiesPreferenceLoaderAndTheme() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "dylib-extract-prefs")
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = root.appendingPathComponent("Library/PreferenceLoader/Preferences")
        let theme = root.appendingPathComponent("Library/Themes/Dark.theme")
        try FileManager.default.createDirectory(at: loader, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: theme, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: loader.appendingPathComponent("Foo.plist"))
        try Data("theme".utf8).write(to: theme.appendingPathComponent("Info.plist"))

        let destination = root.appendingPathComponent("out", isDirectory: true)
        let result = try DylibService.extractPayloads(from: root, to: destination)
        XCTAssertTrue(result.items.contains {
            $0.kind == .resourcePackage && $0.outputURL.lastPathComponent == "PreferenceLoader"
        })
        XCTAssertTrue(result.items.contains {
            $0.kind == .resourcePackage && $0.outputURL.lastPathComponent == "Dark.theme"
        })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("PreferenceLoader/Preferences/Foo.plist").path
            )
        )
    }

    func testExtractPayloadsBatchContinuesAfterAFailedSource() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "dylib-extract-partial")
        defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appendingPathComponent("good", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try machoData().write(to: good.appendingPathComponent("Ok.dylib"))
        let badDeb = root.appendingPathComponent("broken.deb")
        try Data("not a debian package".utf8).write(to: badDeb)

        let results = DylibService.extractPayloads(from: [good, badDeb])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].items.map(\.kind), [.dylib])
        XCTAssertNil(results[0].error)
        XCTAssertTrue(results[1].items.isEmpty)
        XCTAssertNotNil(results[1].error)
    }

    func testExtractPayloadsDisambiguatesDuplicateNames() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "dylib-extract-dup")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a")
        let second = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try machoData().write(to: first.appendingPathComponent("Foo.dylib"))
        try machoData().write(to: second.appendingPathComponent("Foo.dylib"))

        let destination = root.appendingPathComponent("out", isDirectory: true)
        let result = try DylibService.extractPayloads(from: root, to: destination)
        let names = result.items.map(\.outputURL.lastPathComponent).sorted()
        XCTAssertEqual(names, ["Foo-1.dylib", "Foo.dylib"].sorted())
    }

    private func makePayloadFixture(in root: URL) throws -> URL {
        let dylibDir = root.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries")
        let framework = root.appendingPathComponent("Library/Frameworks/Sample.framework")
        let bundle = root.appendingPathComponent("Library/PreferenceBundles/Prefs.bundle")
        let assets = root.appendingPathComponent("Library/Application Support/TweakAssets")
        for directory in [dylibDir, framework, bundle, assets] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try machoData().write(to: dylibDir.appendingPathComponent("Foo.dylib"))
        try Data("filter".utf8).write(to: dylibDir.appendingPathComponent("Foo.plist"))
        try machoData().write(to: framework.appendingPathComponent("Sample"))
        try Data("fw".utf8).write(to: framework.appendingPathComponent("Info.plist"))
        try Data("bundle".utf8).write(to: bundle.appendingPathComponent("Info.plist"))
        try Data("root".utf8).write(to: bundle.appendingPathComponent("Root.plist"))
        try Data("png".utf8).write(to: assets.appendingPathComponent("icon.png"))
        return root
    }

    private func machoData() -> Data {
        Data([0xCF, 0xFA, 0xED, 0xFE])
    }
}
