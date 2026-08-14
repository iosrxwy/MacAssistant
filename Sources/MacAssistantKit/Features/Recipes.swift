import Foundation

/// 一条可运行/可复制的 shell 配方(用于开关与维护动作)。
///
/// 名称与说明按 `id` 现取现查,不能存成属性:配方表是 `static let`,只会初始化一次,
/// 存下来的话切换语言后整张表还是旧语言。
public struct ShellRecipe: Identifiable, Sendable {
    public let id: String
    /// 稳定的分类标识,分组和排序用它,展示时才翻译成 `category`。
    public let categoryID: String
    public let command: String
    public let needsSudo: Bool
    public let dangerous: Bool
    /// 少数配方的说明就是命令本身,没有可翻译的内容。
    private let literalDetail: String?

    public init(id: String, categoryID: String, command: String,
                literalDetail: String? = nil, needsSudo: Bool = false, dangerous: Bool = false) {
        self.id = id
        self.categoryID = categoryID
        self.command = command
        self.literalDetail = literalDetail
        self.needsSudo = needsSudo
        self.dangerous = dangerous
    }

    public var category: String { L("recipe.category.\(categoryID)") }
    public var name: String { L("recipe.\(id).name") }
    public var detail: String { literalDetail ?? L("recipe.\(id).detail") }
}

public enum RecipeLibrary {

    /// 侧栏分组顺序。
    public static let categoryIDs = ["finder", "dock", "screenshot", "maintenance", "security"]

    public static let all: [ShellRecipe] = finder + dock + screenshot + maintenance + security

    public static let finder: [ShellRecipe] = [
        .init(id: "finder-show-hidden-on", categoryID: "finder",
              command: "defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder"),
        .init(id: "finder-show-hidden-off", categoryID: "finder",
              command: "defaults write com.apple.finder AppleShowAllFiles -bool false && killall Finder"),
        .init(id: "finder-extensions", categoryID: "finder",
              command: "defaults write NSGlobalDomain AppleShowAllExtensions -bool true && killall Finder"),
        .init(id: "finder-pathbar", categoryID: "finder",
              command: "defaults write com.apple.finder ShowPathbar -bool true && killall Finder"),
        .init(id: "finder-statusbar", categoryID: "finder",
              command: "defaults write com.apple.finder ShowStatusBar -bool true && killall Finder"),
        .init(id: "finder-no-dsstore", categoryID: "finder",
              command: "defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true")
    ]

    public static let dock: [ShellRecipe] = [
        .init(id: "dock-autohide-on", categoryID: "dock",
              command: "defaults write com.apple.dock autohide -bool true && killall Dock"),
        .init(id: "dock-autohide-off", categoryID: "dock",
              command: "defaults write com.apple.dock autohide -bool false && killall Dock"),
        .init(id: "dock-fast", categoryID: "dock",
              command: "defaults write com.apple.dock autohide-delay -float 0 && defaults write com.apple.dock autohide-time-modifier -float 0 && killall Dock"),
        .init(id: "dock-reset-speed", categoryID: "dock",
              command: "defaults delete com.apple.dock autohide-delay; defaults delete com.apple.dock autohide-time-modifier; killall Dock"),
        .init(id: "dock-static-only", categoryID: "dock",
              command: "defaults write com.apple.dock static-only -bool true && killall Dock")
    ]

    public static let screenshot: [ShellRecipe] = [
        .init(id: "shot-jpg", categoryID: "screenshot",
              command: "defaults write com.apple.screencapture type jpg && killall SystemUIServer"),
        .init(id: "shot-png", categoryID: "screenshot",
              command: "defaults write com.apple.screencapture type png && killall SystemUIServer"),
        .init(id: "shot-no-shadow", categoryID: "screenshot",
              command: "defaults write com.apple.screencapture disable-shadow -bool true && killall SystemUIServer"),
        .init(id: "shot-location", categoryID: "screenshot",
              command: "mkdir -p ~/Desktop/Screenshots && defaults write com.apple.screencapture location ~/Desktop/Screenshots && killall SystemUIServer")
    ]

    public static let maintenance: [ShellRecipe] = [
        .init(id: "restart-finder", categoryID: "maintenance",
              command: "killall Finder", literalDetail: "killall Finder"),
        .init(id: "restart-dock", categoryID: "maintenance",
              command: "killall Dock", literalDetail: "killall Dock"),
        .init(id: "restart-menubar", categoryID: "maintenance",
              command: "killall SystemUIServer", literalDetail: "killall SystemUIServer"),
        .init(id: "restart-controlcenter", categoryID: "maintenance",
              command: "killall ControlCenter", literalDetail: "killall ControlCenter"),
        .init(id: "clear-clipboard", categoryID: "maintenance",
              command: "pbcopy < /dev/null", literalDetail: "pbcopy < /dev/null"),
        .init(id: "flush-dns", categoryID: "maintenance",
              command: NetworkService.flushDNSCommand, needsSudo: true),
        .init(id: "rebuild-launchservices", categoryID: "maintenance",
              command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user && killall Finder"),
        .init(id: "spotlight-reindex", categoryID: "maintenance",
              command: "sudo mdutil -E /", needsSudo: true, dangerous: true),
        .init(id: "memory-pressure", categoryID: "maintenance",
              command: "memory_pressure -Q")
    ]

    public static let security: [ShellRecipe] = [
        .init(id: "remove-quarantine", categoryID: "security",
              command: "sudo xattr -rd com.apple.quarantine /Applications/示例.app", needsSudo: true),
        .init(id: "gatekeeper-assess", categoryID: "security",
              command: "spctl --assess --type execute --verbose=4 /Applications/示例.app"),
        .init(id: "gatekeeper-settings", categoryID: "security",
              command: "open 'x-apple.systempreferences:com.apple.preference.security?Privacy'")
    ]

    /// 运行一条配方(通过登录 shell,使 defaults/killall 等可用)。
    public static func run(_ recipe: ShellRecipe) throws -> CommandResult {
        try Shell.script(recipe.command)
    }
}
