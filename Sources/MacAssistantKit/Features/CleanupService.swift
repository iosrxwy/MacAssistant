import Foundation

/// 一个可清理目标(将删除其中每个目录的“内容”,保留目录本身)。
public final class CleanupTarget: Identifiable, ObservableObject, @unchecked Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let paths: [URL]
    @Published public var size: Int64 = 0
    @Published public var selected: Bool = false

    public init(id: String, name: String, detail: String, paths: [URL]) {
        self.id = id
        self.name = name
        self.detail = detail
        self.paths = paths
    }

    public var existingPaths: [URL] {
        paths.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public struct CleanupFileActions: @unchecked Sendable {
    public var moveToTrash: (URL) throws -> URL
    public var removePermanently: (URL) throws -> Void

    public init(
        moveToTrash: @escaping (URL) throws -> URL,
        removePermanently: @escaping (URL) throws -> Void
    ) {
        self.moveToTrash = moveToTrash
        self.removePermanently = removePermanently
    }

    public static let live = CleanupFileActions(
        moveToTrash: { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return (resultingURL as URL?) ?? url
        },
        removePermanently: { url in
            try FileManager.default.removeItem(at: url)
        }
    )
}

/// 用户级清理服务。普通项目只移入废纸篓；永久与外部工具动作必须走独立确认。
public enum CleanupService {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacAssistant/Cleanup/operations.jsonl")
    }

    /// 每行一个 JSON 记录；保留最近 200 次，便于审计又避免日志无限增长。
    @discardableResult
    public static func appendHistory(
        _ summary: CleanupExecutionSummary,
        to url: URL = historyURL,
        completedAt: Date = Date()
    ) throws -> URL {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(CleanupHistoryEntry(summary: summary, completedAt: completedAt))
        let oldLines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(199) ?? []
        var data = Data(oldLines.joined(separator: "\n").utf8)
        if !data.isEmpty { data.append(0x0A) }
        data.append(encoded)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public static func loadHistory(from url: URL = historyURL) throws -> [CleanupHistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(CleanupHistoryEntry.self, from: Data($0.utf8)) }
    }

    public static func definitions(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [CleanupTargetDefinition] {
        func h(_ path: String) -> URL { homeDirectory.appendingPathComponent(path) }
        return [
            CleanupTargetDefinition(
                id: "user-caches",
                name: L("cleanup.user-caches.name"),
                detail: L("cleanup.user-caches.detail"),
                paths: [h("Library/Caches")],
                risk: .caution,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .system,
                systemImage: "internaldrive"
            ),
            CleanupTargetDefinition(
                id: "browser-caches",
                name: L("cleanup.browser-caches.name"),
                detail: L("cleanup.browser-caches.detail"),
                paths: [
                    h("Library/Caches/Google/Chrome"),
                    h("Library/Caches/Microsoft Edge"),
                    h("Library/Caches/BraveSoftware/Brave-Browser"),
                    h("Library/Caches/Firefox"),
                    h("Library/Caches/com.apple.Safari"),
                    h("Library/Containers/com.apple.Safari/Data/Library/Caches")
                ],
                risk: .safe,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .system,
                systemImage: "safari"
            ),
            CleanupTargetDefinition(
                id: "developer-caches",
                name: L("cleanup.developer-caches.name"),
                detail: L("cleanup.developer-caches.detail"),
                paths: [
                    h("Library/Caches/com.apple.dt.Xcode"),
                    h("Library/Caches/org.swift.swiftpm"),
                    h("Library/Developer/Xcode/SourcePackages/artifacts"),
                    h("Library/Caches/go-build"),
                    h("Library/Caches/pnpm"),
                    h(".cargo/registry/cache")
                ],
                risk: .safe,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .packageManager,
                systemImage: "hammer"
            ),
            CleanupTargetDefinition(
                id: "xcode-derived",
                name: L("cleanup.xcode-derived.name"),
                detail: L("cleanup.xcode-derived.detail"),
                paths: [h("Library/Developer/Xcode/DerivedData")],
                risk: .safe,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .xcode,
                systemImage: "hammer"
            ),
            CleanupTargetDefinition(
                id: "xcode-devicesupport",
                name: L("cleanup.xcode-devicesupport.name"),
                detail: L("cleanup.xcode-devicesupport.detail"),
                paths: [
                    h("Library/Developer/Xcode/iOS DeviceSupport"),
                    h("Library/Developer/Xcode/watchOS DeviceSupport"),
                    h("Library/Developer/Xcode/tvOS DeviceSupport")
                ],
                risk: .caution,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .xcode,
                systemImage: "iphone"
            ),
            CleanupTargetDefinition(
                id: "xcode-archives",
                name: L("cleanup.xcode-archives.name"),
                detail: L("cleanup.xcode-archives.detail"),
                paths: [h("Library/Developer/Xcode/Archives")],
                risk: .viewOnly,
                action: .viewOnly,
                defaultSelected: false,
                category: .xcode,
                systemImage: "archivebox"
            ),
            CleanupTargetDefinition(
                id: "simulator-caches",
                name: L("cleanup.simulator-caches.name"),
                detail: L("cleanup.simulator-caches.detail"),
                paths: [h("Library/Developer/CoreSimulator/Caches")],
                risk: .safe,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .xcode,
                systemImage: "square.stack.3d.up"
            ),
            CleanupTargetDefinition(
                id: "logs",
                name: L("cleanup.logs.name"),
                detail: L("cleanup.logs.detail"),
                paths: [h("Library/Logs")],
                risk: .caution,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .system,
                systemImage: "doc.text"
            ),
            CleanupTargetDefinition(
                id: "trash",
                name: L("cleanup.trash.name"),
                detail: L("cleanup.trash.detail"),
                paths: [h(".Trash")],
                risk: .permanent,
                action: .emptyTrashPermanently,
                defaultSelected: false,
                category: .system,
                systemImage: "trash"
            ),
            CleanupTargetDefinition(
                id: "npm",
                name: L("cleanup.npm.name"),
                detail: "~/.npm/_cacache",
                paths: [h(".npm/_cacache")],
                risk: .safe,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .packageManager,
                systemImage: "cube.box"
            ),
            CleanupTargetDefinition(
                id: "yarn",
                name: L("cleanup.yarn.name"),
                detail: "~/Library/Caches/Yarn",
                paths: [h("Library/Caches/Yarn")],
                risk: .safe,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .packageManager,
                systemImage: "cube.box"
            ),
            CleanupTargetDefinition(
                id: "pip",
                name: L("cleanup.pip.name"),
                detail: "~/Library/Caches/pip",
                paths: [h("Library/Caches/pip")],
                risk: .safe,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .packageManager,
                systemImage: "cube.box"
            ),
            CleanupTargetDefinition(
                id: "homebrew",
                name: L("cleanup.homebrew.name"),
                detail: L("cleanup.homebrew.detail"),
                paths: [h("Library/Caches/Homebrew")],
                risk: .external,
                action: .externalTool,
                defaultSelected: false,
                category: .packageManager,
                systemImage: "terminal"
            ),
            CleanupTargetDefinition(
                id: "cocoapods",
                name: L("cleanup.cocoapods.name"),
                detail: "~/Library/Caches/CocoaPods",
                paths: [h("Library/Caches/CocoaPods")],
                risk: .safe,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .packageManager,
                systemImage: "cube.box"
            ),
            CleanupTargetDefinition(
                id: "gradle",
                name: L("cleanup.gradle.name"),
                detail: "~/.gradle/caches",
                paths: [h(".gradle/caches")],
                risk: .safe,
                action: .moveContentsToTrash,
                defaultSelected: false,
                category: .packageManager,
                systemImage: "cube.box"
            )
        ]
    }

    /// 兼容修复页现有接口；系统清理页使用不可变 definition + scan report。
    public static func makeTargets() -> [CleanupTarget] {
        definitions().map {
            CleanupTarget(id: $0.id, name: $0.name, detail: $0.detail, paths: $0.paths)
        }
    }

    public static func makePolicy(
        definitions: [CleanupTargetDefinition],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CleanupPathPolicy {
        CleanupPathPolicy(
            homeDirectory: homeDirectory,
            allowedRoots: definitions.flatMap(\.paths)
        )
    }

    public static func scan(
        definitions: [CleanupTargetDefinition],
        policy: CleanupPathPolicy,
        cancellation: @Sendable () -> Bool = { false },
        progress: @Sendable (CleanupProgress) -> Void = { _ in }
    ) -> CleanupScanReport {
        var items: [CleanupScanItem] = []
        var wasCancelled = false

        for (index, definition) in definitions.enumerated() {
            if cancellation() {
                wasCancelled = true
                items.append(
                    contentsOf: definitions[index...].map {
                        CleanupScanItem(definition: $0, status: .cancelled, validatedPaths: [])
                    }
                )
                break
            }

            progress(
                CleanupProgress(
                    targetID: definition.id,
                    targetName: definition.name,
                    index: index + 1,
                    total: definitions.count
                )
            )

            if definition.action == .externalTool {
                items.append(
                    CleanupScanItem(
                        definition: definition,
                        status: .excluded(L("cleanup.status.external-excluded")),
                        validatedPaths: []
                    )
                )
                continue
            }

            items.append(scan(definition: definition, policy: policy, cancellation: cancellation))
        }

        return CleanupScanReport(items: items, cancelled: wasCancelled)
    }

    public static func execute(
        report: CleanupScanReport,
        selectedIDs: Set<String>,
        policy: CleanupPathPolicy,
        allowPermanentTrash: Bool,
        actions: CleanupFileActions = .live,
        cancellation: @Sendable () -> Bool = { false },
        progress: @Sendable (CleanupProgress) -> Void = { _ in }
    ) -> CleanupExecutionSummary {
        let selectedItems = report.items.filter { selectedIDs.contains($0.id) }
        var results: [CleanupItemResult] = []
        var wasCancelled = false
        var processedRoots: [CleanupValidatedPath] = []

        for (index, item) in selectedItems.enumerated() {
            if cancellation() {
                wasCancelled = true
                results.append(
                    contentsOf: selectedItems[index...].map {
                        CleanupItemResult(
                            targetID: $0.id,
                            targetName: $0.definition.name,
                            outcome: .cancelled,
                            processedBytes: 0,
                            messages: [L("cleanup.message.cancelled-before-start")]
                        )
                    }
                )
                break
            }

            progress(
                CleanupProgress(
                    targetID: item.id,
                    targetName: item.definition.name,
                    index: index + 1,
                    total: selectedItems.count
                )
            )

            results.append(
                execute(
                    item: item,
                    policy: policy,
                    allowPermanentTrash: allowPermanentTrash,
                    actions: actions,
                    cancellation: cancellation,
                    processedRoots: &processedRoots
                )
            )
            if results.last?.outcome == .cancelled {
                wasCancelled = true
            }
        }

        return CleanupExecutionSummary(results: results, cancelled: wasCancelled)
    }

    /// 计算目标占用的总字节数（兼容修复页）。
    public static func computeSize(_ target: CleanupTarget) -> Int64 {
        size(ofPaths: target.paths)
    }

    /// 计算一组路径的总占用（兼容修复页，错误按 0 处理）。
    public static func size(ofPaths paths: [URL]) -> Int64 {
        paths.filter { FileManager.default.fileExists(atPath: $0.path) }
            .reduce(0) { $0 + FileSystemHelper.size(at: $1) }
    }

    /// 兼容修复页：普通路径统一移入废纸篓，不再静默永久删除。
    @discardableResult
    public static func cleanPaths(_ paths: [URL]) -> Int64 {
        let definition = CleanupTargetDefinition(
            id: "legacy",
            name: L("cleanup.legacy.name"),
            detail: L("cleanup.legacy.detail"),
            paths: paths,
            risk: .caution,
            action: .moveContentsToTrash,
            defaultSelected: false
        )
        let policy = CleanupPathPolicy(homeDirectory: home, allowedRoots: paths)
        let report = scan(definitions: [definition], policy: policy)
        return execute(
            report: report,
            selectedIDs: [definition.id],
            policy: policy,
            allowPermanentTrash: false
        ).processedBytes
    }

    @discardableResult
    public static func clean(_ target: CleanupTarget) -> Int64 {
        cleanPaths(target.paths)
    }

    private static func scan(
        definition: CleanupTargetDefinition,
        policy: CleanupPathPolicy,
        cancellation: @Sendable () -> Bool
    ) -> CleanupScanItem {
        var total: Int64 = 0
        var validated: [CleanupValidatedPath] = []
        var errors: [String] = []
        var missingCount = 0
        var permissionCount = 0

        for path in definition.paths {
            if cancellation() {
                return CleanupScanItem(
                    definition: definition,
                    status: .cancelled,
                    validatedPaths: validated
                )
            }

            do {
                let root = try policy.validate(path)
                guard policy.isReadable(root) else {
                    permissionCount += 1
                    errors.append(L("cleanup.message.no-read-permission", path.lastPathComponent))
                    continue
                }
                validated.append(root)
                let measured = measure(root: root, cancellation: cancellation)
                total += measured.bytes
                errors.append(contentsOf: measured.errors)
                if measured.cancelled {
                    return CleanupScanItem(
                        definition: definition,
                        status: .cancelled,
                        validatedPaths: validated
                    )
                }
            } catch CleanupPathError.missing {
                missingCount += 1
            } catch CleanupPathError.permissionDenied {
                permissionCount += 1
                errors.append(L("cleanup.message.no-read-permission", path.lastPathComponent))
            } catch {
                errors.append(L("cleanup.message.detail", path.lastPathComponent, error.localizedDescription))
            }
        }

        // 多路径目标中部分路径不存在属于正常情况（例如没有 watchOS 设备支持），
        // 只有真实错误才降级为 partial。
        let status: CleanupScanStatus
        if missingCount == definition.paths.count {
            status = .missing
        } else if permissionCount + missingCount == definition.paths.count && permissionCount > 0 {
            status = .permissionDenied(errors.first ?? L("cleanup.message.no-read-permission.generic"))
        } else if !errors.isEmpty {
            status = .partial(total, aggregate(errors))
        } else {
            status = .measured(total)
        }
        return CleanupScanItem(definition: definition, status: status, validatedPaths: validated)
    }

    /// 轻量测量：只统计大小，不做逐文件策略校验。
    /// 安全性由删除边界保证——真正被移动的只有经过完整校验的顶层条目，
    /// 枚举器不跟随符号链接，因此这里无需再对每个后代做 realpath 检查。
    private static func measure(
        root: CleanupValidatedPath,
        cancellation: @Sendable () -> Bool
    ) -> (bytes: Int64, errors: [String], cancelled: Bool) {
        if !root.isDirectory {
            guard let bytes = allocatedSize(at: root.canonicalURL) else {
                return (0, [L("cleanup.message.size-unreadable", root.canonicalURL.lastPathComponent)], false)
            }
            return (bytes, [], false)
        }

        var total: Int64 = 0
        var errors: [String] = []
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root.canonicalURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                errors.append(L("cleanup.message.detail", url.lastPathComponent, error.localizedDescription))
                return true
            }
        ) else {
            return (0, [L("cleanup.message.enumeration-failed")], false)
        }

        let keySet = Set(keys)
        for case let url as URL in enumerator {
            if cancellation() { return (total, errors, true) }
            guard let values = try? url.resourceValues(forKeys: keySet) else {
                errors.append(L("cleanup.message.attributes-unreadable", url.lastPathComponent))
                continue
            }
            if values.isSymbolicLink == true {
                // 符号链接随其父目录一并处理；枚举器本身不会跟随链接，大小不计入，也不算错误。
                continue
            }
            if values.isRegularFile == true {
                total += Int64(
                    values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize
                        ?? values.fileSize
                        ?? 0
                )
            }
        }
        return (total, errors, false)
    }

    /// 把可能上千条的逐文件错误压缩成前几条 + 总数，避免撑爆 UI 与内存。
    private static func aggregate(_ errors: [String], limit: Int = 3) -> [String] {
        guard errors.count > limit else { return errors }
        return Array(errors.prefix(limit)) + [L("cleanup.message.more-read-errors", errors.count - limit)]
    }

    private static func execute(
        item: CleanupScanItem,
        policy: CleanupPathPolicy,
        allowPermanentTrash: Bool,
        actions: CleanupFileActions,
        cancellation: @Sendable () -> Bool,
        processedRoots: inout [CleanupValidatedPath]
    ) -> CleanupItemResult {
        let definition = item.definition
        guard definition.isSelectable else {
            return CleanupItemResult(
                targetID: item.id,
                targetName: definition.name,
                outcome: .skipped,
                processedBytes: 0,
                messages: [L("cleanup.message.not-file-cleanup")]
            )
        }
        if definition.action == .emptyTrashPermanently && !allowPermanentTrash {
            return CleanupItemResult(
                targetID: item.id,
                targetName: definition.name,
                outcome: .skipped,
                processedBytes: 0,
                messages: [L("cleanup.message.trash-needs-confirmation")]
            )
        }

        var processed: Int64 = 0
        var successes = 0
        var failures = 0
        var messages: [String] = []

        for requestedRoot in definition.paths {
            if cancellation() {
                return CleanupItemResult(
                    targetID: item.id,
                    targetName: definition.name,
                    outcome: .cancelled,
                    processedBytes: processed,
                    messages: messages + [L("cleanup.message.cancelled-no-rollback")]
                )
            }

            if processedRoots.contains(where: {
                let claimed = $0.requestedURL.standardizedFileURL.path
                let requested = requestedRoot.standardizedFileURL.path
                return requested == claimed || requested.hasPrefix(claimed + "/")
            }) {
                messages.append(L("cleanup.message.overlap-skipped", requestedRoot.lastPathComponent))
                continue
            }

            do {
                let root = try policy.validate(requestedRoot)
                guard policy.isReadable(root), policy.isWritable(root) else {
                    failures += 1
                    messages.append(L("cleanup.message.no-write-permission", requestedRoot.lastPathComponent))
                    continue
                }
                try policy.revalidate(root)

                if processedRoots.contains(where: {
                    $0.canonicalURL == root.canonicalURL || policy.contains(root, within: $0)
                }) {
                    continue
                }
                processedRoots.append(root)

                let candidates: [URL]
                if root.isDirectory {
                    candidates = try FileManager.default.contentsOfDirectory(
                        at: root.canonicalURL,
                        includingPropertiesForKeys: nil,
                        options: []
                    )
                } else {
                    candidates = [root.canonicalURL]
                }

                if candidates.isEmpty {
                    messages.append(L("cleanup.message.empty-directory", requestedRoot.lastPathComponent))
                }

                for candidateURL in candidates {
                    if cancellation() {
                        return CleanupItemResult(
                            targetID: item.id,
                            targetName: definition.name,
                            outcome: .cancelled,
                            processedBytes: processed,
                            messages: messages + [L("cleanup.message.cancelled-no-rollback")]
                        )
                    }

                    do {
                        try policy.revalidate(root)
                        let candidate = try policy.validate(candidateURL)
                        if root.isDirectory && !policy.contains(candidate, within: root) {
                            throw CleanupPathError.outsideAllowedRoots
                        }
                        try policy.revalidate(candidate)
                        let measurement = measure(root: candidate, cancellation: cancellation)
                        if measurement.cancelled {
                            return CleanupItemResult(
                                targetID: item.id,
                                targetName: definition.name,
                                outcome: .cancelled,
                                processedBytes: processed,
                                messages: messages + [L("cleanup.message.cancelled-no-rollback")]
                            )
                        }
                        let bytes = measurement.bytes
                        if !measurement.errors.isEmpty {
                            messages.append(
                                L("cleanup.message.size-incomplete", candidateURL.lastPathComponent)
                            )
                        }
                        try policy.revalidate(root)
                        try policy.revalidate(candidate)

                        if definition.action == .emptyTrashPermanently {
                            try actions.removePermanently(candidate.canonicalURL)
                        } else {
                            _ = try actions.moveToTrash(candidate.canonicalURL)
                        }
                        processed += bytes
                        successes += 1
                    } catch CleanupPathError.missing {
                        messages.append(L("cleanup.message.gone-before-processing", candidateURL.lastPathComponent))
                    } catch CleanupPathError.symbolicLink {
                        messages.append(L("cleanup.message.symlink-skipped", candidateURL.lastPathComponent))
                    } catch {
                        failures += 1
                        messages.append(L("cleanup.message.detail", candidateURL.lastPathComponent, error.localizedDescription))
                    }
                }
            } catch CleanupPathError.missing {
                messages.append(L("cleanup.message.path-missing", requestedRoot.lastPathComponent))
            } catch {
                failures += 1
                messages.append(L("cleanup.message.detail", requestedRoot.lastPathComponent, error.localizedDescription))
            }
        }

        // 空目录、路径不存在、符号链接跳过都是正常情况，不应把结果降级；
        // 只有真实失败才影响结论。
        let outcome: CleanupItemOutcome
        if failures > 0 && successes > 0 {
            outcome = .partial
        } else if failures > 0 {
            outcome = .failed
        } else if successes > 0 {
            outcome = .success
        } else {
            outcome = .skipped
        }
        return CleanupItemResult(
            targetID: item.id,
            targetName: definition.name,
            outcome: outcome,
            processedBytes: processed,
            messages: messages
        )
    }

    private static func allocatedSize(at url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
            )
            return Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            )
        } catch {
            return nil
        }
    }
}
