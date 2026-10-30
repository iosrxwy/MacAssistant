import Foundation

/// 命令速查和快捷开关的联合结果，给总搜索条用，不另做一套动作系统。
public struct ToolFindHit: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case command
        case recipe
        case feature
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public let destination: AppDestination
    public let copyText: String
    public let searchQuery: String

    public var kindLabel: String {
        switch kind {
        case .command: return L("toolfinder.kind.command")
        case .recipe: return L("toolfinder.kind.recipe")
        case .feature: return L("toolfinder.kind.feature")
        }
    }
}

public enum ToolFinder {
    public static func search(_ query: String, limit: Int = 8) -> [ToolFindHit] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, limit > 0 else { return [] }

        var hits: [ToolFindHit] = []
        for feature in features where feature.matches(key) {
            guard hits.count < limit else { break }
            hits.append(
                ToolFindHit(
                    id: "feature.\(feature.id)",
                    kind: .feature,
                    title: feature.title,
                    detail: feature.detail,
                    destination: feature.destination,
                    copyText: feature.title,
                    searchQuery: feature.title
                )
            )
        }
        for recipe in RecipeLibrary.search(key) {
            guard hits.count < limit else { break }
            hits.append(
                ToolFindHit(
                    id: "recipe.\(recipe.id)",
                    kind: .recipe,
                    title: recipe.name,
                    detail: recipe.detail,
                    destination: .recipes,
                    copyText: recipe.command,
                    searchQuery: recipe.name
                )
            )
        }
        if hits.count < limit {
            for command in CommandLibrary.search(key) {
                guard hits.count < limit else { break }
                hits.append(
                    ToolFindHit(
                        id: "command.\(command.id)",
                        kind: .command,
                        title: command.title,
                        detail: command.detail,
                        destination: .cheatsheet,
                        copyText: command.command,
                        searchQuery: command.title
                    )
                )
            }
        }
        return hits
    }

    private struct FeatureEntry {
        let id: String
        let destination: AppDestination
        let keywords: [String]

        var title: String { L("toolfinder.feature.\(id).title") }
        var detail: String { L("toolfinder.feature.\(id).detail") }

        func matches(_ key: String) -> Bool {
            if TextSearch.matches(title, needle: key) { return true }
            if TextSearch.matches(detail, needle: key) { return true }
            return keywords.contains { TextSearch.matches($0, needle: key) }
        }
    }

    private static let features: [FeatureEntry] = [
        FeatureEntry(
            id: "desktopIcons",
            destination: .desktopIcons,
            keywords: [
                "图标", "icon", "icns", "桌面", "文件夹图标", "应用图标", "自定义图标",
                "desktop icon", "folder icon", "app icon", "custom icon"
            ]
        ),
        FeatureEntry(
            id: "appClone",
            destination: .appClone,
            keywords: [
                "分身", "应用分身", "双开", "多开", "临时多开", "克隆", "clone", "dual", "wechat",
                "微信分身", "QQ分身", "sandbox", "多账号", "open -n"
            ]
        ),
        FeatureEntry(
            id: "appUninstall",
            destination: .appUninstall,
            keywords: [
                "卸载", "卸除", "删除应用", "残留", "废纸篓", "uninstall", "remove app", "leftover"
            ]
        ),
        FeatureEntry(
            id: "macApp",
            destination: .macApp,
            keywords: [
                "注入", "卸载", "卸除", "插件", "卸载插件", "卸除插件",
                "dylib", "wechat", "微信插件", "inject", "uninject", "plugin", "tweak"
            ]
        )
    ]
}
