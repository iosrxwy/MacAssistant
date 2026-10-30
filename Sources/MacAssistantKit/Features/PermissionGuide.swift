import Foundation

/// 某一页实际会碰到的 macOS 权限：写清谁在用、没有会怎样，可选的不装成必需。
public struct PermissionNeed: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: PermissionKind
    public let title: String
    public let usedBy: String
    public let withoutIt: String
    public let settingsAnchor: String?
    public let isOptional: Bool

    public init(
        id: String,
        kind: PermissionKind,
        title: String,
        usedBy: String,
        withoutIt: String,
        settingsAnchor: String? = nil,
        isOptional: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.usedBy = usedBy
        self.withoutIt = withoutIt
        self.settingsAnchor = settingsAnchor
        self.isOptional = isOptional
    }

    public var settingsURLs: [URL] {
        PermissionGuide.settingsURLs(anchor: settingsAnchor)
    }
}

public enum PermissionKind: String, Sendable, Hashable, CaseIterable {
    case filesAndFolders
    case fullDiskAccess
    case xcodeCommandLineTools
    case deviceTrust
    case network
    case keychain
    case appManagement
}

public enum PermissionGrantStatus: String, Sendable, Equatable {
    case granted
    case missing
    case unknown
}

public struct PermissionStatusSnapshot: Sendable, Equatable {
    public var statuses: [PermissionKind: PermissionGrantStatus]

    public init(_ statuses: [PermissionKind: PermissionGrantStatus] = [:]) {
        self.statuses = statuses
    }

    public func status(for kind: PermissionKind) -> PermissionGrantStatus {
        statuses[kind] ?? .unknown
    }
}

/// 只做真读/真路径探测，不弹 TCC 申请框：桌面/文稿/下载一律不碰。
public struct PermissionStatusProbe: Sendable {
    public var fullDiskAccess: @Sendable () -> CleanupFullDiskAccessStatus
    public var developerDirectory: @Sendable () -> String?
    public var pathExists: @Sendable (String) -> Bool
    public var hasBundledCloneHelpers: @Sendable () -> Bool

    public init(
        fullDiskAccess: @escaping @Sendable () -> CleanupFullDiskAccessStatus,
        developerDirectory: @escaping @Sendable () -> String?,
        pathExists: @escaping @Sendable (String) -> Bool,
        hasBundledCloneHelpers: @escaping @Sendable () -> Bool
    ) {
        self.fullDiskAccess = fullDiskAccess
        self.developerDirectory = developerDirectory
        self.pathExists = pathExists
        self.hasBundledCloneHelpers = hasBundledCloneHelpers
    }

    public static let live = PermissionStatusProbe(
        fullDiskAccess: {
            CleanupFullDiskAccessProbe.live.probe(
                homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            )
        },
        developerDirectory: {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcode-select") else { return nil }
            guard let result = try? Shell.run("/usr/bin/xcode-select", ["-p"]), result.succeeded else {
                return nil
            }
            let path = result.trimmedOutput
            return path.isEmpty ? nil : path
        },
        pathExists: { FileManager.default.fileExists(atPath: $0) },
        hasBundledCloneHelpers: { AppCloneService.hasBundledCloneHelpers }
    )

    public func snapshot() -> PermissionStatusSnapshot {
        let fda: PermissionGrantStatus
        switch fullDiskAccess() {
        case .granted: fda = .granted
        case .denied: fda = .missing
        case .unknown: fda = .unknown
        }

        // 完全磁盘访问已经覆盖桌面/文稿/下载。没有 FDA 时不要去列这些目录，否则会弹出 TCC。
        let files: PermissionGrantStatus = fda == .granted ? .granted : .unknown

        let tools: PermissionGrantStatus
        if hasBundledCloneHelpers() {
            tools = .granted
        } else if let directory = developerDirectory(), pathExists(directory) {
            tools = .granted
        } else {
            tools = .missing
        }

        return PermissionStatusSnapshot([
            .fullDiskAccess: fda,
            .filesAndFolders: files,
            .xcodeCommandLineTools: tools
        ])
    }
}

public enum PermissionGuide {
    public static let filesAndFoldersAnchor = "Privacy_FilesAndFolders"
    public static let fullDiskAccessAnchor = "Privacy_AllFiles"

    public static var repair: [PermissionNeed] {
        [
            PermissionNeed(
                id: "repair-files",
                kind: .filesAndFolders,
                title: L("permission.repair-files.title"),
                usedBy: L("permission.repair-files.usedBy"),
                withoutIt: L("permission.repair-files.withoutIt"),
                settingsAnchor: filesAndFoldersAnchor
            )
        ]
    }

    public static var ipaTransfer: [PermissionNeed] {
        [
            PermissionNeed(
                id: "transfer-files",
                kind: .filesAndFolders,
                title: L("permission.transfer-files.title"),
                usedBy: L("permission.transfer-files.usedBy"),
                withoutIt: L("permission.transfer-files.withoutIt"),
                settingsAnchor: filesAndFoldersAnchor
            ),
            PermissionNeed(
                id: "transfer-device",
                kind: .deviceTrust,
                title: L("permission.transfer-device.title"),
                usedBy: L("permission.transfer-device.usedBy"),
                withoutIt: L("permission.transfer-device.withoutIt")
            )
        ]
    }

    public static var desktopIcons: [PermissionNeed] {
        [
            PermissionNeed(
                id: "desktop-icons-files",
                kind: .filesAndFolders,
                title: L("permission.desktop-icons-files.title"),
                usedBy: L("permission.desktop-icons-files.usedBy"),
                withoutIt: L("permission.desktop-icons-files.withoutIt"),
                settingsAnchor: filesAndFoldersAnchor
            )
        ]
    }

    public static var appClone: [PermissionNeed] {
        [
            PermissionNeed(
                id: "appclone-files",
                kind: .filesAndFolders,
                title: L("permission.appclone-files.title"),
                usedBy: L("permission.appclone-files.usedBy"),
                withoutIt: L("permission.appclone-files.withoutIt"),
                settingsAnchor: filesAndFoldersAnchor
            ),
            PermissionNeed(
                id: "appclone-clang",
                kind: .xcodeCommandLineTools,
                title: L("permission.appclone-clang.title"),
                usedBy: L("permission.appclone-clang.usedBy"),
                withoutIt: L("permission.appclone-clang.withoutIt"),
                isOptional: true
            )
        ]
    }

    public static var appUninstall: [PermissionNeed] {
        [
            PermissionNeed(
                id: "appuninstall-fda",
                kind: .fullDiskAccess,
                title: L("permission.appuninstall-fda.title"),
                usedBy: L("permission.appuninstall-fda.usedBy"),
                withoutIt: L("permission.appuninstall-fda.withoutIt"),
                settingsAnchor: fullDiskAccessAnchor,
                isOptional: true
            ),
            PermissionNeed(
                id: "appuninstall-management",
                kind: .appManagement,
                title: L("permission.appuninstall-management.title"),
                usedBy: L("permission.appuninstall-management.usedBy"),
                withoutIt: L("permission.appuninstall-management.withoutIt"),
                settingsAnchor: "Privacy_AppBundles",
                isOptional: true
            )
        ]
    }

    public static var macApp: [PermissionNeed] {
        [
            PermissionNeed(
                id: "macapp-files",
                kind: .filesAndFolders,
                title: L("permission.macapp-files.title"),
                usedBy: L("permission.macapp-files.usedBy"),
                withoutIt: L("permission.macapp-files.withoutIt"),
                settingsAnchor: filesAndFoldersAnchor
            ),
            PermissionNeed(
                id: "macapp-management",
                kind: .appManagement,
                title: L("permission.macapp-management.title"),
                usedBy: L("permission.macapp-management.usedBy"),
                withoutIt: L("permission.macapp-management.withoutIt"),
                settingsAnchor: "Privacy_AppBundles",
                isOptional: true
            )
        ]
    }

    public static var signing: [PermissionNeed] {
        [
            PermissionNeed(
                id: "signing-files",
                kind: .filesAndFolders,
                title: L("permission.signing-files.title"),
                usedBy: L("permission.signing-files.usedBy"),
                withoutIt: L("permission.signing-files.withoutIt"),
                settingsAnchor: filesAndFoldersAnchor
            ),
            PermissionNeed(
                id: "signing-network",
                kind: .network,
                title: L("permission.signing-network.title"),
                usedBy: L("permission.signing-network.usedBy"),
                withoutIt: L("permission.signing-network.withoutIt"),
                isOptional: true
            ),
            PermissionNeed(
                id: "signing-keychain",
                kind: .keychain,
                title: L("permission.signing-keychain.title"),
                usedBy: L("permission.signing-keychain.usedBy"),
                withoutIt: L("permission.signing-keychain.withoutIt"),
                isOptional: true
            )
        ]
    }

    public static func settingsURLs(anchor: String?) -> [URL] {
        guard let anchor, !anchor.isEmpty else { return [] }
        return [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        ].compactMap(URL.init(string:))
    }

    /// 已授权的不再占版面。可选权限只有明确探测为未授予时才提示；
    /// 探测不到时不反复占版面——App 管理无法无副作用探测，带着设置入口也会永远钉在注入页上。
    public static func visibleNeeds(
        _ needs: [PermissionNeed],
        snapshot: PermissionStatusSnapshot
    ) -> [PermissionNeed] {
        needs.filter { need in
            switch snapshot.status(for: need.kind) {
            case .granted:
                return false
            case .missing:
                return true
            case .unknown:
                return !need.isOptional
            }
        }
    }
}
