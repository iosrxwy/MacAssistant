import Combine
import Foundation

public enum WorkspaceItemKind: String, Codable, Sendable {
    case debArchive
    case debEntry
    case machO
    case dylib
    case framework
    case resource
}

public enum WorkspaceItemState: String, Codable, Sendable {
    case scanned
    case extracted
    case modified
    case verified
    case failed
}

public struct WorkspaceOrigin: Codable, Hashable, Sendable {
    public let archiveID: UUID?
    public let archiveURL: URL?
    public let relativePath: String?

    public init(archiveID: UUID? = nil, archiveURL: URL? = nil, relativePath: String? = nil) {
        self.archiveID = archiveID
        self.archiveURL = archiveURL
        self.relativePath = relativePath
    }
}

public struct WorkspaceItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var kind: WorkspaceItemKind
    public var displayName: String
    public var fileURL: URL
    public var companionURLs: [URL]
    public var origin: WorkspaceOrigin?
    public var state: WorkspaceItemState

    public init(
        id: UUID = UUID(),
        kind: WorkspaceItemKind,
        displayName: String,
        fileURL: URL,
        companionURLs: [URL] = [],
        origin: WorkspaceOrigin? = nil,
        state: WorkspaceItemState
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.fileURL = fileURL
        self.companionURLs = companionURLs
        self.origin = origin
        self.state = state
    }
}

public struct DebDraft: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let itemIDs: [WorkspaceItem.ID]

    public init(id: UUID = UUID(), itemIDs: [WorkspaceItem.ID]) {
        self.id = id
        self.itemIDs = itemIDs
    }
}

/// App 范围内的类型安全工作区。页面只交换 item ID，不通过通知字符串传裸路径。
@MainActor
public final class WorkspaceStore: ObservableObject {
    @Published public private(set) var items: [WorkspaceItem.ID: WorkspaceItem] = [:]
    @Published public private(set) var requestedDestination: AppDestination?
    @Published public private(set) var pendingDylibItemID: WorkspaceItem.ID?
    @Published public private(set) var pendingDebDraft: DebDraft?
    private var managedRoots: [URL] = []

    public init() {}

    deinit {
        for root in managedRoots { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    public func add(_ item: WorkspaceItem) -> WorkspaceItem.ID {
        items[item.id] = item
        return item.id
    }

    public func item(id: WorkspaceItem.ID) -> WorkspaceItem? {
        items[id]
    }

    @discardableResult
    public func openInDylib(
        fileURL: URL,
        companionURLs: [URL] = [],
        origin: WorkspaceOrigin? = nil
    ) -> WorkspaceItem.ID {
        let item = WorkspaceItem(
            kind: fileURL.pathExtension.lowercased() == "dylib" ? .dylib : .machO,
            displayName: fileURL.lastPathComponent,
            fileURL: fileURL,
            companionURLs: companionURLs,
            origin: origin,
            state: .extracted
        )
        add(item)
        pendingDylibItemID = item.id
        requestedDestination = .dylib
        return item.id
    }

    /// 把归档临时条目复制到 Store 自己持有的 0700 工作区，跨页后来源 session 可安全释放。
    @discardableResult
    public func importForDylib(
        fileURL: URL,
        companionURLs: [URL] = [],
        origin: WorkspaceOrigin? = nil
    ) throws -> WorkspaceItem.ID {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "workspace-dylib")
        do {
            let copiedFile = root.appendingPathComponent(fileURL.lastPathComponent)
            try FileManager.default.copyItem(at: fileURL, to: copiedFile)
            var copiedCompanions: [URL] = []
            for companion in companionURLs {
                let output = root.appendingPathComponent(companion.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: output.path) else { continue }
                try FileManager.default.copyItem(at: companion, to: output)
                copiedCompanions.append(output)
            }
            managedRoots.append(root)
            return openInDylib(
                fileURL: copiedFile,
                companionURLs: copiedCompanions,
                origin: origin
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    public func openInDylib(itemID: WorkspaceItem.ID) {
        guard items[itemID] != nil else { return }
        pendingDylibItemID = itemID
        requestedDestination = .dylib
    }

    public func createDebDraft(from itemIDs: [WorkspaceItem.ID]) {
        let valid = itemIDs.filter { items[$0] != nil }
        guard !valid.isEmpty else { return }
        pendingDebDraft = DebDraft(itemIDs: valid)
        requestedDestination = .deb
    }

    public func createDebDraft(fileURL: URL, companionURLs: [URL] = []) {
        let kind: WorkspaceItemKind = switch fileURL.pathExtension.lowercased() {
        case "framework": .framework
        case "bundle": .resource
        default: .dylib
        }
        let item = WorkspaceItem(
            kind: kind,
            displayName: fileURL.lastPathComponent,
            fileURL: fileURL,
            companionURLs: companionURLs,
            state: .extracted
        )
        createDebDraft(from: [add(item)])
    }

    public func createDebDraft(fileURLs: [URL]) {
        let ids = fileURLs.map { url in
            let kind: WorkspaceItemKind = switch url.pathExtension.lowercased() {
            case "framework": .framework
            case "bundle": .resource
            default: .dylib
            }
            return add(WorkspaceItem(
                kind: kind,
                displayName: url.lastPathComponent,
                fileURL: url,
                state: .extracted
            ))
        }
        createDebDraft(from: ids)
    }

    public func acknowledgeNavigation() {
        requestedDestination = nil
    }

    public func consumePendingDylib() -> WorkspaceItem? {
        defer { pendingDylibItemID = nil }
        guard let id = pendingDylibItemID else { return nil }
        return items[id]
    }

    public func consumePendingDebDraft() -> [WorkspaceItem] {
        defer { pendingDebDraft = nil }
        guard let draft = pendingDebDraft else { return [] }
        return draft.itemIDs.compactMap { items[$0] }
    }
}
