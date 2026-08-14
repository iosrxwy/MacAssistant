import Foundation

public enum CleanupPhase: String, Equatable, Sendable {
    case idle
    case scanning
    case ready
    case cleaning
    case finished
    case cancelled
}

/// 清理页的纯状态机。选择集合是按钮、全选和行勾选的唯一真相源。
public struct CleanupSessionState: Equatable, Sendable {
    public private(set) var phase: CleanupPhase = .idle
    public private(set) var selectedIDs: Set<String>
    public private(set) var requiresRescan = false

    private let targetIDs: Set<String>
    private let defaultSelectedIDs: Set<String>

    public init(targetIDs: Set<String>, defaultSelectedIDs: Set<String>) {
        self.targetIDs = targetIDs
        self.defaultSelectedIDs = defaultSelectedIDs.intersection(targetIDs)
        selectedIDs = self.defaultSelectedIDs
    }

    public var selectedCount: Int { selectedIDs.count }
    public var isBusy: Bool { phase == .scanning || phase == .cleaning }
    public var canScan: Bool { !isBusy }
    public var canClean: Bool { phase == .ready && !selectedIDs.isEmpty }

    @discardableResult
    public mutating func startScanning() -> Bool {
        guard canScan else { return false }
        phase = .scanning
        requiresRescan = false
        return true
    }

    public mutating func finishScanning(cancelled: Bool) {
        guard phase == .scanning else { return }
        phase = cancelled ? .cancelled : .ready
    }

    public mutating func setSelected(_ id: String, _ selected: Bool) {
        guard targetIDs.contains(id), !isBusy else { return }
        if selected {
            selectedIDs.insert(id)
        } else {
            selectedIDs.remove(id)
        }
    }

    public mutating func selectAll() {
        guard !isBusy else { return }
        selectedIDs = targetIDs
    }

    public mutating func selectNone() {
        guard !isBusy else { return }
        selectedIDs.removeAll()
    }

    /// 用给定集合替换当前选择（自动裁剪到已知目标；忙碌时忽略）。
    public mutating func replaceSelection(with ids: Set<String>) {
        guard !isBusy else { return }
        selectedIDs = ids.intersection(targetIDs)
    }

    public mutating func restoreSafeDefaults() {
        guard !isBusy else { return }
        selectedIDs = defaultSelectedIDs
    }

    @discardableResult
    public mutating func startCleaning() -> Bool {
        guard canClean else { return false }
        phase = .cleaning
        requiresRescan = false
        return true
    }

    public mutating func finishCleaning(cancelled: Bool) {
        guard phase == .cleaning else { return }
        phase = cancelled ? .cancelled : .finished
        requiresRescan = true
    }

    @discardableResult
    public mutating func startRequiredRescan() -> Bool {
        guard requiresRescan, !isBusy else { return false }
        phase = .scanning
        requiresRescan = false
        return true
    }
}

public enum CleanupRisk: String, Equatable, Sendable {
    case safe
    case caution
    case permanent
    case viewOnly
    case external

    public var label: String {
        switch self {
        case .safe: return L("cleanup.risk.safe")
        case .caution: return L("cleanup.risk.caution")
        case .permanent: return L("cleanup.risk.permanent")
        case .viewOnly: return L("cleanup.risk.view-only")
        case .external: return L("cleanup.risk.external")
        }
    }
}

/// 清理目标的归类，只影响界面分组呈现，不参与任何路径校验或执行逻辑。
public enum CleanupCategory: String, Equatable, Sendable, CaseIterable {
    case system
    case xcode
    case packageManager

    public var label: String {
        switch self {
        case .system: return L("cleanup.category.system")
        case .xcode: return L("cleanup.category.xcode")
        case .packageManager: return L("cleanup.category.package-manager")
        }
    }

    public var systemImage: String {
        switch self {
        case .system: return "macwindow"
        case .xcode: return "hammer"
        case .packageManager: return "shippingbox"
        }
    }
}

public enum CleanupAction: Equatable, Sendable {
    case moveContentsToTrash
    case emptyTrashPermanently
    case viewOnly
    case externalTool
}

public struct CleanupTargetDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let paths: [URL]
    public let risk: CleanupRisk
    public let action: CleanupAction
    public let defaultSelected: Bool
    public let category: CleanupCategory
    public let systemImage: String

    public init(
        id: String,
        name: String,
        detail: String,
        paths: [URL],
        risk: CleanupRisk,
        action: CleanupAction,
        defaultSelected: Bool,
        category: CleanupCategory = .system,
        systemImage: String = "folder"
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.paths = paths
        self.risk = risk
        self.action = action
        self.defaultSelected = defaultSelected
        self.category = category
        self.systemImage = systemImage
    }

    public var isSelectable: Bool {
        action == .moveContentsToTrash || action == .emptyTrashPermanently
    }
}

public enum CleanupScanStatus: Equatable, Sendable {
    case notScanned
    case measured(Int64)
    case missing
    case permissionDenied(String)
    case partial(Int64, [String])
    case excluded(String)
    case cancelled

    public var measuredBytes: Int64? {
        switch self {
        case let .measured(bytes), let .partial(bytes, _):
            return bytes
        default:
            return nil
        }
    }

    /// 是否存在可实际清理的内容（不存在/无权限/被排除的项目勾选了也没有意义）。
    public var isActionable: Bool {
        switch self {
        case .measured, .partial:
            return true
        default:
            return false
        }
    }
}

/// 扫描/清理过程中逐项上报的进度事件。
public struct CleanupProgress: Equatable, Sendable {
    public let targetID: String
    public let targetName: String
    /// 1-based 序号。
    public let index: Int
    public let total: Int

    public init(targetID: String, targetName: String, index: Int, total: Int) {
        self.targetID = targetID
        self.targetName = targetName
        self.index = index
        self.total = total
    }
}

public struct CleanupFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct CleanupValidatedPath: Equatable, Sendable {
    public let requestedURL: URL
    public let canonicalURL: URL
    public let identity: CleanupFileIdentity
    public let isDirectory: Bool

    public init(
        requestedURL: URL,
        canonicalURL: URL,
        identity: CleanupFileIdentity,
        isDirectory: Bool
    ) {
        self.requestedURL = requestedURL
        self.canonicalURL = canonicalURL
        self.identity = identity
        self.isDirectory = isDirectory
    }
}

public struct CleanupScanItem: Identifiable, Equatable, Sendable {
    public let definition: CleanupTargetDefinition
    public let status: CleanupScanStatus
    public let validatedPaths: [CleanupValidatedPath]

    public var id: String { definition.id }

    public init(
        definition: CleanupTargetDefinition,
        status: CleanupScanStatus,
        validatedPaths: [CleanupValidatedPath]
    ) {
        self.definition = definition
        self.status = status
        self.validatedPaths = validatedPaths
    }
}

public struct CleanupScanReport: Equatable, Sendable {
    public let items: [CleanupScanItem]
    public let cancelled: Bool
    public let scannedAt: Date

    public init(items: [CleanupScanItem], cancelled: Bool, scannedAt: Date = Date()) {
        self.items = items
        self.cancelled = cancelled
        self.scannedAt = scannedAt
    }
}

public enum CleanupItemOutcome: String, Codable, Equatable, Sendable {
    case success
    case partial
    case skipped
    case failed
    case cancelled
}

public struct CleanupHistoryEntry: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let targetID: String
        public let targetName: String
        public let outcome: CleanupItemOutcome
        public let processedBytes: Int64
        public let messages: [String]
    }

    public let completedAt: Date
    public let processedBytes: Int64
    public let successCount: Int
    public let skippedCount: Int
    public let failureCount: Int
    public let cancelled: Bool
    public let items: [Item]

    public init(summary: CleanupExecutionSummary, completedAt: Date = Date()) {
        self.completedAt = completedAt
        processedBytes = summary.processedBytes
        successCount = summary.successCount
        skippedCount = summary.skippedCount
        failureCount = summary.failureCount
        cancelled = summary.cancelled
        items = summary.results.map {
            Item(
                targetID: $0.targetID,
                targetName: $0.targetName,
                outcome: $0.outcome,
                processedBytes: $0.processedBytes,
                messages: $0.messages
            )
        }
    }
}

public struct CleanupItemResult: Identifiable, Equatable, Sendable {
    public let targetID: String
    public let targetName: String
    public let outcome: CleanupItemOutcome
    public let processedBytes: Int64
    public let messages: [String]

    public var id: String { targetID }

    public init(
        targetID: String,
        targetName: String,
        outcome: CleanupItemOutcome,
        processedBytes: Int64,
        messages: [String] = []
    ) {
        self.targetID = targetID
        self.targetName = targetName
        self.outcome = outcome
        self.processedBytes = processedBytes
        self.messages = messages
    }
}

public struct CleanupExecutionSummary: Equatable, Sendable {
    public let results: [CleanupItemResult]
    public let cancelled: Bool

    public init(results: [CleanupItemResult], cancelled: Bool) {
        self.results = results
        self.cancelled = cancelled
    }

    public var processedBytes: Int64 {
        results.reduce(0) { $0 + $1.processedBytes }
    }

    public var successCount: Int {
        results.filter { $0.outcome == .success }.count
    }

    public var skippedCount: Int {
        results.filter { $0.outcome == .skipped || $0.outcome == .cancelled }.count
    }

    public var failureCount: Int {
        results.filter { $0.outcome == .failed || $0.outcome == .partial }.count
    }

    public var isCompleteSuccess: Bool {
        !cancelled && !results.isEmpty && failureCount == 0 && skippedCount == 0
    }
}
