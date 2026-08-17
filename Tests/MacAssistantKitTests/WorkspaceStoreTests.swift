import XCTest
@testable import MacAssistantKit

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func testDebEntryNavigatesToDylibAndBackToDebDraft() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "workspace-test")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Fixture.dylib")
        let plist = root.appendingPathComponent("Fixture.plist")
        try Data([1, 2, 3]).write(to: source)
        try Data("plist".utf8).write(to: plist)

        let store = WorkspaceStore()
        let itemID = try store.importForDylib(
            fileURL: source,
            companionURLs: [plist],
            origin: WorkspaceOrigin(
                archiveID: UUID(),
                archiveURL: root.appendingPathComponent("fixture.deb"),
                relativePath: "Library/Foo/Fixture.dylib"
            )
        )
        XCTAssertEqual(store.requestedDestination, .dylib)
        XCTAssertEqual(store.pendingDylibItemID, itemID)

        let item = try XCTUnwrap(store.consumePendingDylib())
        XCTAssertEqual(item.origin?.relativePath, "Library/Foo/Fixture.dylib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL.path))
        XCTAssertEqual(item.companionURLs.map(\.lastPathComponent), ["Fixture.plist"])

        store.createDebDraft(from: [itemID])
        XCTAssertEqual(store.requestedDestination, .deb)
        XCTAssertEqual(store.consumePendingDebDraft().map(\.id), [itemID])
    }

    func testManagedCopySurvivesOriginalRemoval() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "workspace-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Payload.dylib")
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: source)

        let store = WorkspaceStore()
        let id = try store.importForDylib(fileURL: source)
        let copy = try XCTUnwrap(store.item(id: id)?.fileURL)
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }
}
