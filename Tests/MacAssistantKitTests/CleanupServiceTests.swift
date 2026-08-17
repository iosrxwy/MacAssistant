import XCTest
@testable import MacAssistantKit

final class CleanupServiceTests: XCTestCase {
    func testCleanupHistoryRoundTripAndRetentionLimit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("operations.jsonl")
        let summary = CleanupExecutionSummary(
            results: [
                CleanupItemResult(
                    targetID: "cache",
                    targetName: "缓存",
                    outcome: .success,
                    processedBytes: 4_096,
                    messages: ["moved"]
                )
            ],
            cancelled: false
        )

        for offset in 0..<205 {
            try CleanupService.appendHistory(
                summary,
                to: url,
                completedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            )
        }

        let history = try CleanupService.loadHistory(from: url)
        XCTAssertEqual(history.count, 200)
        XCTAssertEqual(history.first?.completedAt, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(history.last?.processedBytes, 4_096)
        XCTAssertEqual(history.last?.items.first?.outcome, .success)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testDefinitionsCoverBrowserAndDeveloperCachesWithoutLeavingHome() {
        let home = URL(fileURLWithPath: "/tmp/fixture-home", isDirectory: true)
        let definitions = CleanupService.definitions(homeDirectory: home)
        let ids = Set(definitions.map(\.id))

        XCTAssertTrue(ids.isSuperset(of: ["browser-caches", "developer-caches"]))
        XCTAssertTrue(definitions.allSatisfy { !$0.defaultSelected })
        for definition in definitions {
            for path in definition.paths {
                XCTAssertTrue(path.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path + "/"))
            }
        }
    }

    func testSelectingUnknownSizeTargetImmediatelyEnablesCleaning() {
        var session = CleanupSessionState(
            targetIDs: ["unknown-size"],
            defaultSelectedIDs: []
        )

        XCTAssertTrue(session.startScanning())
        session.finishScanning(cancelled: false)
        XCTAssertFalse(session.canClean)

        session.setSelected("unknown-size", true)

        XCTAssertTrue(session.canClean, "清理按钮必须由选择数量驱动，不能依赖未知或零字节大小")
    }

    func testSelectAllSelectNoneAndBusyPhasesAreMutuallyExclusive() {
        var session = CleanupSessionState(
            targetIDs: ["a", "b"],
            defaultSelectedIDs: ["a"]
        )

        XCTAssertTrue(session.startScanning())
        session.selectAll()
        XCTAssertEqual(session.selectedIDs, ["a"], "扫描中不能修改选择")
        XCTAssertFalse(session.startCleaning())

        session.finishScanning(cancelled: false)
        session.selectAll()
        XCTAssertEqual(session.selectedIDs, ["a", "b"])
        session.selectNone()
        XCTAssertTrue(session.selectedIDs.isEmpty)
        XCTAssertFalse(session.canClean)

        session.setSelected("b", true)
        XCTAssertTrue(session.startCleaning())
        XCTAssertFalse(session.startScanning(), "清理和扫描必须互斥")
        session.finishCleaning(cancelled: false)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertTrue(session.requiresRescan)
        XCTAssertTrue(session.startRequiredRescan())
        XCTAssertEqual(session.phase, .scanning)
    }

    func testMissingAndPermissionFailuresRemainStructured() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let missing = home.appendingPathComponent("missing")
        let locked = home.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }

        let definitions = [
            definition(id: "missing", path: missing),
            definition(id: "locked", path: locked)
        ]
        let policy = CleanupService.makePolicy(definitions: definitions, homeDirectory: home)
        let report = CleanupService.scan(definitions: definitions, policy: policy)

        XCTAssertEqual(report.items[0].status, .missing)
        let summary = CleanupService.execute(
            report: report,
            selectedIDs: ["missing", "locked"],
            policy: policy,
            allowPermanentTrash: false,
            actions: testingActions()
        )
        XCTAssertEqual(summary.results.first { $0.targetID == "missing" }?.outcome, .skipped)
        XCTAssertEqual(summary.results.first { $0.targetID == "locked" }?.outcome, .failed)
        XCTAssertFalse(summary.isCompleteSuccess)
    }

    func testSymlinkRootIsRejectedEvenWhenItPointsInsideAllowedHome() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let real = home.appendingPathComponent("real", isDirectory: true)
        let link = home.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let policy = CleanupPathPolicy(homeDirectory: home, allowedRoots: [link])

        XCTAssertThrowsError(try policy.validate(link)) { error in
            XCTAssertEqual(error as? CleanupPathError, .symbolicLink)
        }
    }

    func testRevalidationRejectsPathReplacedAfterScan() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let candidate = home.appendingPathComponent("candidate")
        let original = home.appendingPathComponent("original")
        try Data("before".utf8).write(to: candidate)
        let policy = CleanupPathPolicy(homeDirectory: home, allowedRoots: [candidate])
        let scanned = try policy.validate(candidate)

        try FileManager.default.moveItem(at: candidate, to: original)
        try Data("after".utf8).write(to: candidate)

        XCTAssertThrowsError(try policy.revalidate(scanned)) { error in
            XCTAssertEqual(error as? CleanupPathError, .changedSinceScan)
        }
    }

    func testCancellationMarksUnstartedItemsWithoutClaimingSuccess() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = definition(id: "first", path: home.appendingPathComponent("first"))
        let second = definition(id: "second", path: home.appendingPathComponent("second"))
        let definitions = [first, second]
        let policy = CleanupService.makePolicy(definitions: definitions, homeDirectory: home)
        let report = CleanupService.scan(definitions: definitions, policy: policy)

        let summary = CleanupService.execute(
            report: report,
            selectedIDs: ["first", "second"],
            policy: policy,
            allowPermanentTrash: false,
            actions: testingActions(),
            cancellation: { true }
        )

        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.results.map(\.outcome), [.cancelled, .cancelled])
        XCTAssertFalse(summary.isCompleteSuccess)
    }

    func testPartialFailureReportsSuccessFailureAndActualProcessedSize() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: cache.appendingPathComponent("ok"))
        try Data(repeating: 2, count: 4_096).write(to: cache.appendingPathComponent("fail"))

        let target = definition(id: "cache", path: cache)
        let policy = CleanupService.makePolicy(definitions: [target], homeDirectory: home)
        let report = CleanupService.scan(definitions: [target], policy: policy)
        let actions = CleanupFileActions(
            moveToTrash: { url in
                if url.lastPathComponent == "fail" {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileWriteNoPermissionError,
                        userInfo: [NSLocalizedDescriptionKey: "fixture denied"]
                    )
                }
                try FileManager.default.removeItem(at: url)
                return url
            },
            removePermanently: { try FileManager.default.removeItem(at: $0) }
        )

        let summary = CleanupService.execute(
            report: report,
            selectedIDs: ["cache"],
            policy: policy,
            allowPermanentTrash: false,
            actions: actions
        )

        XCTAssertEqual(summary.results.first?.outcome, .partial)
        XCTAssertGreaterThan(summary.processedBytes, 0)
        XCTAssertEqual(summary.failureCount, 1)
        XCTAssertFalse(summary.isCompleteSuccess)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("fail").path))
    }

    func testOverlappingTargetsAreProcessedOnce() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let parent = home.appendingPathComponent("Caches", isDirectory: true)
        let child = parent.appendingPathComponent("Browser", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: child.appendingPathComponent("item"))

        let definitions = [
            definition(id: "parent", path: parent),
            definition(id: "child", path: child)
        ]
        let policy = CleanupService.makePolicy(definitions: definitions, homeDirectory: home)
        let report = CleanupService.scan(definitions: definitions, policy: policy)
        let summary = CleanupService.execute(
            report: report,
            selectedIDs: ["parent", "child"],
            policy: policy,
            allowPermanentTrash: false,
            actions: testingActions()
        )

        XCTAssertEqual(summary.failureCount, 0)
        XCTAssertEqual(summary.processedBytes, 4_096)
        XCTAssertTrue(summary.results.contains { $0.messages.contains { $0.contains("更大范围") } })
    }

    func testPermanentTrashRequiresIndependentConfirmation() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("recoverable".utf8).write(to: trash.appendingPathComponent("item"))
        let target = CleanupTargetDefinition(
            id: "trash",
            name: "废纸篓",
            detail: "fixture",
            paths: [trash],
            risk: .permanent,
            action: .emptyTrashPermanently,
            defaultSelected: false
        )
        let policy = CleanupService.makePolicy(definitions: [target], homeDirectory: home)
        let report = CleanupService.scan(definitions: [target], policy: policy)

        let blocked = CleanupService.execute(
            report: report,
            selectedIDs: ["trash"],
            policy: policy,
            allowPermanentTrash: false,
            actions: testingActions()
        )
        XCTAssertEqual(blocked.results.first?.outcome, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("item").path))

        let confirmed = CleanupService.execute(
            report: report,
            selectedIDs: ["trash"],
            policy: policy,
            allowPermanentTrash: true,
            actions: testingActions()
        )
        XCTAssertEqual(confirmed.results.first?.outcome, .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.appendingPathComponent("item").path))
    }

    func testScanTreatsSymlinksAndMissingSiblingPathsAsNormal() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: cache.appendingPathComponent("real"))
        try FileManager.default.createSymbolicLink(
            at: cache.appendingPathComponent("link"),
            withDestinationURL: home
        )
        let missingSibling = home.appendingPathComponent("not-installed")

        let target = CleanupTargetDefinition(
            id: "cache",
            name: "cache",
            detail: "fixture",
            paths: [cache, missingSibling],
            risk: .safe,
            action: .moveContentsToTrash,
            defaultSelected: false
        )
        let policy = CleanupService.makePolicy(definitions: [target], homeDirectory: home)
        let report = CleanupService.scan(definitions: [target], policy: policy)

        guard case let .measured(bytes) = report.items[0].status else {
            return XCTFail("符号链接与缺失的兄弟路径不应把状态降级：\(report.items[0].status)")
        }
        XCTAssertGreaterThan(bytes, 0)
    }

    func testScanReportsPartialWithAggregatedErrorsForUnreadableSubdirectory() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("cache", isDirectory: true)
        let locked = cache.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: cache.appendingPathComponent("ok"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }

        let target = definition(id: "cache", path: cache)
        let policy = CleanupService.makePolicy(definitions: [target], homeDirectory: home)
        let report = CleanupService.scan(definitions: [target], policy: policy)

        guard case let .partial(bytes, messages) = report.items[0].status else {
            return XCTFail("无法读取的子目录应产生 partial：\(report.items[0].status)")
        }
        XCTAssertGreaterThan(bytes, 0, "可读部分仍应计入大小")
        XCTAssertFalse(messages.isEmpty)
        XCTAssertLessThanOrEqual(messages.count, 4, "错误信息应聚合而不是逐条罗列")
    }

    func testExecuteReportsSuccessWhenOnlyNormalSkipsOccur() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("cache", isDirectory: true)
        let payload = cache.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: payload.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(
            at: cache.appendingPathComponent("link"),
            withDestinationURL: home
        )

        let target = definition(id: "cache", path: cache)
        let policy = CleanupService.makePolicy(definitions: [target], homeDirectory: home)
        let report = CleanupService.scan(definitions: [target], policy: policy)
        let summary = CleanupService.execute(
            report: report,
            selectedIDs: ["cache"],
            policy: policy,
            allowPermanentTrash: false,
            actions: testingActions()
        )

        XCTAssertEqual(
            summary.results.first?.outcome, .success,
            "符号链接跳过属于正常情况，不应把结果降级为部分成功"
        )
        XCTAssertGreaterThan(summary.processedBytes, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: payload.path),
            "真实内容应被处理"
        )
        XCTAssertNotNil(
            try? FileManager.default.attributesOfItem(
                atPath: cache.appendingPathComponent("link").path
            ),
            "符号链接本身应保留（仅跳过）"
        )
    }

    func testScanAndExecuteReportPerItemProgress() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = home.appendingPathComponent("first", isDirectory: true)
        let second = home.appendingPathComponent("second", isDirectory: true)
        for dir in [first, second] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("file"))
        }

        let definitions = [
            definition(id: "first", path: first),
            definition(id: "second", path: second)
        ]
        let policy = CleanupService.makePolicy(definitions: definitions, homeDirectory: home)

        final class EventBox: @unchecked Sendable {
            var events: [CleanupProgress] = []
        }
        let scanBox = EventBox()
        let report = CleanupService.scan(
            definitions: definitions,
            policy: policy,
            progress: { scanBox.events.append($0) }
        )
        XCTAssertEqual(scanBox.events.map(\.targetID), ["first", "second"])
        XCTAssertEqual(scanBox.events.map(\.index), [1, 2])
        XCTAssertEqual(scanBox.events.map(\.total), [2, 2])

        let executeBox = EventBox()
        _ = CleanupService.execute(
            report: report,
            selectedIDs: ["first", "second"],
            policy: policy,
            allowPermanentTrash: false,
            actions: testingActions(),
            progress: { executeBox.events.append($0) }
        )
        XCTAssertEqual(executeBox.events.map(\.targetID), ["first", "second"])
    }

    func testReplaceSelectionClampsToKnownTargetsAndRespectsBusyPhase() {
        var session = CleanupSessionState(
            targetIDs: ["a", "b"],
            defaultSelectedIDs: ["a", "b"]
        )

        session.replaceSelection(with: ["a", "ghost"])
        XCTAssertEqual(session.selectedIDs, ["a"], "未知目标应被裁剪")

        session.startScanning()
        session.replaceSelection(with: ["b"])
        XCTAssertEqual(session.selectedIDs, ["a"], "忙碌阶段不允许改选择")
    }

    private func definition(id: String, path: URL) -> CleanupTargetDefinition {
        CleanupTargetDefinition(
            id: id,
            name: id,
            detail: "fixture",
            paths: [path],
            risk: .safe,
            action: .moveContentsToTrash,
            defaultSelected: false
        )
    }

    private func testingActions() -> CleanupFileActions {
        CleanupFileActions(
            moveToTrash: {
                try FileManager.default.removeItem(at: $0)
                return $0
            },
            removePermanently: { try FileManager.default.removeItem(at: $0) }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
