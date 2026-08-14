import Foundation

/// 命令风险等级。
public enum RiskLevel: String, Codable, Sendable, CaseIterable {
    case safe       // 🟢 只读或可逆
    case caution    // 🟡 会修改状态 / 需 sudo
    case danger     // 🔴 可能破坏系统或不可逆

    public var label: String {
        L("risk.\(rawValue)")
    }

    public var symbol: String {
        switch self {
        case .safe: return "🟢"
        case .caution: return "🟡"
        case .danger: return "🔴"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .safe: return 0
        case .caution: return 1
        case .danger: return 2
        }
    }
}

/// 一条命令速查条目。
public struct CommandEntry: Identifiable, Sendable, Codable, Hashable {
    public let id: String
    public let category: String
    public let title: String
    public let command: String
    public let detail: String
    public let risk: RiskLevel
    public let versionNote: String?
}

/// 命令速查数据源:内置痛点命令清单 + `Resources/more-mac-commands.md` 扩充条目。
public enum CommandLibrary {

    /// 规范分类顺序(用于筛选与完整性校验)。
    public static let categories: [String] = [
        "签名与安全",
        "隔离与 Gatekeeper",
        "安装与卸载",
        "SIP·权限·磁盘",
        "系统清理",
        "网络",
        "界面技巧",
        "逆向·开发",
        "性能·电池·硬件",
        "Time Machine·启动项",
        "Homebrew",
        "安全开关",
        "终端·输入法",
        "诊断采集"
    ]

    public static let all: [CommandEntry] = (raws + researchAdditions).enumerated().map { index, r in
        CommandEntry(id: String(format: "cmd-%03d", index + 1),
                     category: r.0, title: r.1, command: r.2, detail: r.3, risk: r.4, versionNote: r.5)
    }

    /// 按关键字 / 风险 / 分类过滤。
    public static func search(_ keyword: String = "", risk: RiskLevel? = nil, category: String? = nil) -> [CommandEntry] {
        let key = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { entry in
            if let risk, entry.risk != risk { return false }
            if let category, entry.category != category { return false }
            if key.isEmpty { return true }
            return entry.title.lowercased().contains(key)
                || entry.command.lowercased().contains(key)
                || entry.detail.lowercased().contains(key)
                || entry.category.lowercased().contains(key)
        }
    }

    public static func count(of risk: RiskLevel) -> Int {
        all.filter { $0.risk == risk }.count
    }

    /// 分类的中文名同时是数据主键(过滤、去重、`more-mac-commands.md` 解析都依赖它),
    /// 所以只在展示时翻译,不动存储值。
    public static func localizedCategory(_ category: String) -> String {
        guard let slug = categorySlugs[category] else { return category }
        return L("cmd.category.\(slug)")
    }

    private static let categorySlugs: [String: String] = [
        "签名与安全": "signing",
        "隔离与 Gatekeeper": "quarantine",
        "安装与卸载": "install",
        "SIP·权限·磁盘": "sip",
        "系统清理": "cleanup",
        "网络": "network",
        "界面技巧": "interface",
        "逆向·开发": "reverse",
        "性能·电池·硬件": "performance",
        "Time Machine·启动项": "backup",
        "Homebrew": "homebrew",
        "安全开关": "securityToggles",
        "终端·输入法": "terminal",
        "诊断采集": "diagnostics"
    ]

    private typealias Raw = (String, String, String, String, RiskLevel, String?)

    private static let researchSectionCategories: [Int: String] = [
        1: "界面技巧",
        2: "界面技巧",
        3: "终端·输入法",
        4: "界面技巧",
        5: "网络",
        6: "SIP·权限·磁盘",
        7: "逆向·开发",
        8: "系统清理",
        9: "性能·电池·硬件",
        10: "安全开关",
        11: "界面技巧",
        12: "性能·电池·硬件",
        13: "Time Machine·启动项",
        14: "界面技巧"
    ]

    private static let researchAdditions: [Raw] = {
        guard let url = researchCommandsURL(),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return parseResearchCommands(text)
    }()

    private static func parseResearchCommands(_ text: String) -> [Raw] {
        var section: Int?
        var result: [Raw] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("## 第三方工具清单") { break }
            if line.hasPrefix("## "),
               let range = line.range(of: #"^##\s+(\d+)\."#, options: .regularExpression) {
                section = Int(line[range].filter(\.isNumber))
                continue
            }
            guard let section, let category = researchSectionCategories[section],
                  line.hasPrefix("| "), !line.hasPrefix("| ---"), !line.contains("| 标题 |")
            else { continue }
            let sentinel = "\u{E000}"
            let protected = line.replacingOccurrences(of: "\\|", with: sentinel)
            let columns = protected.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast()
                .map {
                    String($0)
                        .replacingOccurrences(of: sentinel, with: "|")
                        .trimmingCharacters(in: .whitespaces)
                }
            guard columns.count >= 5, columns[3] != "—",
                  !columns[2].contains("占位提醒")
            else { continue }
            let title = cleanResearchMarkdown(columns[0])
            let originalCommand = cleanResearchMarkdown(columns[1])
                .replacingOccurrences(of: "<br>", with: "\n")
            var detail = cleanResearchMarkdown(columns[2])
            let version = cleanResearchMarkdown(columns[4])
            let requiresVerification = title.contains("需验证")
                || detail.contains("需验证")
                || version.contains("需验证")
            let command: String
            if requiresVerification {
                command = "# 需目标系统验证；请优先使用系统设置，未提供可执行命令。"
                detail += " 原始参考（不可直接执行）：\(originalCommand.replacingOccurrences(of: "\n", with: "；"))"
            } else {
                command = originalCommand
            }
            let risk: RiskLevel = columns[3].contains("🔴") ? .danger
                : (columns[3].contains("🟡") ? .caution : .safe)
            result.append((category, title, command, detail, risk, version.isEmpty ? nil : version))
        }
        return result
    }

    private static func cleanResearchMarkdown(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "<br>", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func researchCommandsURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "more-mac-commands", withExtension: "md") {
            return bundled
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let source = root.appendingPathComponent("Resources/more-mac-commands.md")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    private static let raws: [Raw] = [
        // MARK: 签名与安全
        ("签名与安全", "查看 App 的签名详情 / Team ID", #"codesign -dv --verbose=4 /path/App.app"#,
         "输出 Identifier、TeamIdentifier、证书链与 CDHash;Signature=adhoc 表示本地伪签名。", .safe, nil),
        ("签名与安全", "校验签名完整性(找出被改动组件)", #"codesign --verify --strict --verbose=4 /path/App.app"#,
         "严格校验主 bundle；Framework、appex 等嵌套 bundle 应分别执行同一命令。", .safe, nil),
        ("签名与安全", "导出 App 的 entitlements", #"codesign -d --entitlements :- /path/App.app"#,
         ":- 以 XML 打印到终端;重签名时需保留原 entitlements。", .safe, nil),
        ("签名与安全", "ad-hoc 逐层签名 App", #"codesign --force --sign - /path/App.app"#,
         "- 代表 ad-hoc。先签最深处的 dylib/framework/helper，再签主 App；不要把 --deep 用作签名方式。", .caution, nil),
        ("签名与安全", "逐层重签名(复杂 App 推荐)", #"""
        codesign --force --sign - "/path/App.app/Contents/Frameworks/Foo.framework"
        codesign --force --sign - "/path/App.app/Contents/MacOS/HelperTool"
        codesign --force --sign - "/path/App.app"
        """#,
         "先签最深处的 dylib/framework/helper,再一路向外,最后签 .app 根,每层都不带 --deep。", .caution, nil),
        ("签名与安全", "用 Developer ID 证书正式签名", #"codesign --force --options runtime --sign "Developer ID Application: 你的名字 (TEAMID)" /path/App.app"#,
         "--options runtime 启用 Hardened Runtime,是公证前置条件。", .caution, nil),
        ("签名与安全", "带 entitlements 重签名", #"codesign --force --sign - --entitlements ent.plist --options runtime /path/binary"#,
         "签名会覆盖 entitlements,需显式带上,否则沙盒/权限功能失效。", .caution, nil),
        ("签名与安全", "移除签名", #"codesign --remove-signature /path/App.app"#,
         "某些注入需先去掉 LC_CODE_SIGNATURE 再重签。", .caution, nil),
        ("签名与安全", "列出钥匙串里可用的签名证书", #"security find-identity -v -p codesigning"#,
         "查看本机可用于代码签名的身份。", .safe, nil),
        ("签名与安全", "查看是否已公证 / 装订(staple)", #"""
        spctl -a -vvv -t exec /path/App.app
        xcrun stapler validate /path/App.app
        """#,
         "source=Notarized Developer ID 表示已公证。", .safe, nil),
        ("签名与安全", "解析 mobileprovision / provisionprofile", #"security cms -D -i /path/embedded.provisionprofile"#,
         "查看描述文件里的 App ID、过期时间与 entitlements。", .safe, nil),
        ("签名与安全", "快速读 Info.plist 字段", #"""
        defaults read /path/App.app/Contents/Info.plist CFBundleIdentifier
        /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /path/App.app/Contents/Info.plist
        """#,
         "清理残留/卸载时需要精确 bundle id 与版本。", .safe, nil),

        // MARK: 隔离与 Gatekeeper
        ("隔离与 Gatekeeper", "修复「App 已损坏,无法打开」", #"sudo xattr -rd com.apple.quarantine /Applications/App.app"#,
         "多为 Gatekeeper 拦截未公证 App 的误导性提示,并非真损坏。", .caution, "Sequoia 15 / Tahoe 26 需再删 com.apple.provenance"),
        ("隔离与 Gatekeeper", "删除 provenance 属性(Sequoia+ 必需)", #"sudo xattr -rd com.apple.provenance /Applications/App.app"#,
         "新系统额外加了 com.apple.provenance,单删 quarantine 往往不够。", .caution, "Sequoia 15 / Tahoe 26 新增属性"),
        ("隔离与 Gatekeeper", "清除全部扩展属性(最省事)", #"sudo xattr -cr /Applications/App.app"#,
         "-c 清空、-r 递归;会连同 Finder 标签一起清掉。", .caution, nil),
        ("隔离与 Gatekeeper", "查看文件的扩展属性 / 隔离标记", #"""
        xattr -l /path/file
        xattr -p com.apple.quarantine /path/file
        """#,
         "提示 No such xattr 不是错误,只代表该属性本就不存在。", .safe, nil),
        ("隔离与 Gatekeeper", "命令行工具去隔离 + 加执行权限", #"xattr -d com.apple.quarantine ./tool 2>/dev/null; chmod +x ./tool"#,
         "解决下载脚本/二进制的「来自不受信任的开发者」。", .caution, nil),
        ("隔离与 Gatekeeper", "Gatekeeper 只读评估与单 App 放行", #"spctl --assess --type execute --verbose=4 /Applications/App.app"#,
         "先检查签名与隔离属性，再到“系统设置 > 隐私与安全性”使用“仍要打开”；不提供全局关闭 Gatekeeper 命令。", .safe, "macOS 15 / 26：首次拦截后一小时内可出现“仍要打开”"),
        ("隔离与 Gatekeeper", "恢复 Gatekeeper 默认 / 查看状态", #"""
        sudo spctl --master-enable
        spctl --status
        """#,
         "折腾完务必恢复安全设置。", .safe, nil),
        ("隔离与 Gatekeeper", "让某个已被拦的 App「仍要打开」", #"sudo xattr -rd com.apple.quarantine /Applications/App.app && open /Applications/App.app"#,
         "只放行单个 App,比全局关 Gatekeeper 更安全。", .caution, "Sequoia+ 建议直接用系统设置的「仍要打开」按钮"),

        // MARK: 安装与卸载
        ("安装与卸载", "命令行挂载 / 卸载 dmg", #"""
        hdiutil attach /path/x.dmg
        hdiutil detach "/Volumes/X"
        """#,
         "自动化脚本里装 dmg;挂载后出现在 /Volumes。", .safe, nil),
        ("安装与卸载", "命令行安装 pkg", #"sudo installer -pkg /path/x.pkg -target /"#,
         "批量部署或无 GUI 安装 pkg。", .caution, nil),
        ("安装与卸载", "查看 pkg 会安装哪些文件", #"""
        pkgutil --payload-files /path/x.pkg
        pkgutil --files <pkg-id>
        """#,
         "装前了解会往哪写文件,方便日后卸载。", .safe, nil),
        ("安装与卸载", "列出已安装 pkg 收据 / 详情", #"""
        pkgutil --pkgs
        pkgutil --pkg-info <pkg-id>
        """#,
         "查看安装位置、版本与时间。", .safe, nil),
        ("安装与卸载", "卸载 pkg 的残留文件", #"""
        pkgutil --files <pkg-id>
        sudo rm -rf /Library/Application\ Support/AppName
        sudo pkgutil --forget <pkg-id>
        """#,
         "--forget 只删收据不删文件;需先看清路径再手删。", .danger, nil),
        ("安装与卸载", "安装 Rosetta 2(Apple Silicon 跑 Intel)", #"softwareupdate --install-rosetta --agree-to-license"#,
         "打开 Intel-only App 提示需要 Rosetta 时使用。", .safe, nil),
        ("安装与卸载", "强制以某架构运行程序", #"""
        arch -x86_64 /path/tool
        arch -arm64  /path/tool
        """#,
         "某工具在 arm64 下有 bug 时用 x86_64(Rosetta)跑。", .safe, nil),
        ("安装与卸载", "检查可执行文件 / App 架构", #"""
        file /path/App.app/Contents/MacOS/App
        lipo -archs /path/binary
        """#,
         "输出 x86_64 / arm64 等。", .safe, nil),
        ("安装与卸载", "彻底卸载普通 App(含残留)", #"""
        BID="com.vendor.app"
        rm -rf /Applications/App.app
        for d in "Application Support" Caches Preferences Logs Containers "Saved Application State" HTTPStorages WebKit; do
          rm -rf "$HOME/Library/$d/$BID"* 2>/dev/null
        done
        """#,
         "App 数据散落多个目录,先用前面的命令查到 bundle id。", .caution, nil),
        ("安装与卸载", "重建 LaunchServices(打开方式重复/图标错乱)", #"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user && killall Finder"#,
         "右键「打开方式」重复或图标乱掉时重建数据库。", .caution, nil),
        ("安装与卸载", "关闭「打开从网上下载的 App」提示", #"defaults write com.apple.LaunchServices LSQuarantine -bool false"#,
         "会降低安全性(不再对下载文件隔离提示)。", .danger, nil),

        // MARK: SIP·权限·磁盘
        ("SIP·权限·磁盘", "查看 SIP 状态", #"csrutil status"#, "查看系统完整性保护是否开启。", .safe, nil),
        ("SIP·权限·磁盘", "关闭 / 开启 SIP", #"""
        csrutil disable
        csrutil enable
        """#,
         "SIP 保护系统关键路径,关闭会显著降低安全性。", .danger, "仅能在「恢复模式」终端执行,用完务必恢复"),
        ("SIP·权限·磁盘", "重置某类隐私权限(让 App 重新弹授权)", #"""
        tccutil reset Camera
        tccutil reset Microphone
        tccutil reset ScreenCapture
        tccutil reset Accessibility
        tccutil reset SystemPolicyAllFiles
        """#,
         "服务名区分大小写;误点「不允许」后可重置。", .caution, nil),
        ("SIP·权限·磁盘", "重置某个 App 的全部隐私授权", #"tccutil reset All <bundleid>"#,
         "例:tccutil reset All com.google.Chrome。", .caution, nil),
        ("SIP·权限·磁盘", "重置全部隐私授权(慎用)", #"sudo tccutil reset All"#,
         "所有 App 都要重新授权。", .danger, nil),
        ("SIP·权限·磁盘", "磁盘校验 / 修复", #"""
        diskutil verifyVolume /
        sudo diskutil repairVolume /Volumes/数据盘
        """#,
         "系统盘需在恢复模式用磁盘工具急救或 fsck。", .caution, nil),
        ("SIP·权限·磁盘", "修复用户主目录权限 / ACL", #"diskutil resetUserPermissions / $(id -u)"#,
         "登录后权限异常、无法写入自己文件夹时用。", .caution, nil),
        ("SIP·权限·磁盘", "修改文件属主 / 权限位", #"""
        sudo chown -R $(whoami) /path/dir
        chmod -R u+rw /path/dir
        chmod +x script.sh
        """#,
         "chown 用错路径可能损坏系统,务必确认路径。", .danger, nil),
        ("SIP·权限·磁盘", "chflags 锁定 / 解锁文件", #"""
        chflags nouchg /path/file
        chflags uchg  /path/file
        """#,
         "uchg=用户不可改;Finder 小锁删不掉时先解锁。", .caution, nil),
        ("SIP·权限·磁盘", "删除顽固文件(无法删除)", #"sudo chflags -R noschg,nouchg /path && sudo rm -rf /path"#,
         "去掉 uchg/schg 标志后强删。", .danger, nil),
        ("SIP·权限·磁盘", "显示 ~/Library 目录", #"chflags nohidden ~/Library"#,
         "Finder 里默认看不到用户资源库。", .safe, nil),
        ("SIP·权限·磁盘", "隐藏 / 显示任意文件(Finder 层)", #"""
        chflags hidden   /path/file
        chflags nohidden /path/file
        """#,
         "在 Finder 中隐藏或显示文件。", .safe, nil),
        ("SIP·权限·磁盘", "查看磁盘 / 目录占用", #"""
        df -h
        du -sh ~/Downloads/*
        du -sh * | sort -rh | head
        """#,
         "查看各卷剩余与当前目录 Top 大项。", .safe, nil),

        // MARK: 系统清理
        ("系统清理", "清理用户缓存", #"rm -rf ~/Library/Caches/*"#,
         "清内容而非删目录本身;~/Library/Caches 常占数十 GB。", .caution, nil),
        ("系统清理", "清 Xcode DerivedData / 缓存", #"""
        rm -rf ~/Library/Developer/Xcode/DerivedData/*
        rm -rf ~/Library/Caches/com.apple.dt.Xcode/*
        rm -rf ~/Library/Developer/Xcode/iOS\ DeviceSupport/*
        """#,
         "构建产物与索引可重建;删掉解决编译诡异报错。", .safe, nil),
        ("系统清理", "删除无用的模拟器", #"xcrun simctl delete unavailable"#,
         "清理不可用的旧模拟器 runtime。", .safe, nil),
        ("系统清理", "开发者冷缓存测试(purge)", #"sudo purge"#,
         "仅清理可重建的文件系统缓存，通常不会释放应用匿名内存；用于冷缓存/基准测试，可能让随后读取变慢且不保证提速。", .caution, nil),
        ("系统清理", "清空废纸篓(命令行)", #"rm -rf ~/.Trash/*"#, "不可恢复,谨慎执行。", .caution, nil),
        ("系统清理", "Homebrew 清理旧版本与缓存", #"""
        brew cleanup -s
        brew autoremove
        rm -rf "$(brew --cache)"
        """#,
         "清旧版本、孤儿依赖与下载缓存。", .safe, nil),
        ("系统清理", "Docker 全面清理", #"docker system prune -a --volumes"#,
         "会删除未使用镜像/容器/卷;Docker.raw 常吃几十 GB。", .danger, nil),
        ("系统清理", "清各语言包管理器缓存", #"""
        npm cache clean --force
        yarn cache clean
        pnpm store prune
        pip cache purge
        pod cache clean --all
        """#,
         "均可重新下载,安全。", .safe, nil),
        ("系统清理", "清崩溃日志 / 应用保存状态", #"""
        rm -rf ~/Library/Logs/DiagnosticReports/*
        rm -rf ~/Library/Saved\ Application\ State/*
        """#,
         "清理诊断报告与窗口恢复状态。", .caution, nil),
        ("系统清理", "重建 / 关闭 Spotlight 索引", #"""
        sudo mdutil -E /
        sudo mdutil -i off /Volumes/X
        """#,
         "Spotlight 搜不到或 mds 狂占 CPU 时用。", .caution, nil),

        // MARK: 网络
        ("网络", "刷新 DNS 缓存", #"sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"#,
         "两条都要跑,无输出即成功;改 hosts/换 DNS 后必备。", .caution, "Ventura→Tahoe 26 命令一致"),
        ("网络", "查端口占用并杀进程", #"""
        lsof -i :3000
        kill -15 $(lsof -t -i :3000)
        kill -9  $(lsof -t -i :3000)
        """#,
         "解决 Address already in use;Monterey+ 端口 5000/7000 被 AirPlay 占用。", .caution, nil),
        ("网络", "查看所有监听端口", #"lsof -iTCP -sTCP:LISTEN -nP"#, "列出处于 LISTEN 的端口。", .safe, nil),
        ("网络", "查看本机内网 IP", #"ipconfig getifaddr en0"#, "Wi-Fi 通常 en0,有线可能 en1。", .safe, nil),
        ("网络", "查看公网 IP", #"curl -s https://ipinfo.io/ip; echo"#, "获取出口公网 IP。", .safe, nil),
        ("网络", "ping / traceroute / arp", #"""
        ping -c 4 apple.com
        traceroute apple.com
        arp -a
        """#,
         "连通性、路径与局域网 IP-MAC 对照。", .safe, nil),
        ("网络", "命令行抓包", #"sudo tcpdump -i en0 -n host 1.1.1.1 and port 443"#,
         "需 sudo,可能含敏感数据。", .caution, nil),
        ("网络", "设置 / 关闭 HTTP(S) 代理", #"""
        networksetup -setwebproxy      "Wi-Fi" 127.0.0.1 7890
        networksetup -setsecurewebproxy "Wi-Fi" 127.0.0.1 7890
        networksetup -setwebproxystate  "Wi-Fi" off
        """#,
         "命令行给系统挂/摘代理(如本地 7890)。", .caution, nil),
        ("网络", "查看 / 修改 DNS 服务器", #"""
        networksetup -getdnsservers "Wi-Fi"
        networksetup -setdnsservers "Wi-Fi" 1.1.1.1 8.8.8.8
        networksetup -setdnsservers "Wi-Fi" Empty
        """#,
         "Empty 恢复为自动获取。", .caution, nil),
        ("网络", "列出全部网络服务名", #"networksetup -listallnetworkservices"#, "查看可用于上面命令的服务名。", .safe, nil),
        ("网络", "编辑 hosts 文件并生效", #"""
        sudo nano /etc/hosts
        sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
        """#,
         "把某域名指到指定 IP,改完刷新 DNS。", .caution, nil),
        ("网络", "续租 DHCP / 测端口 / 路由表", #"""
        sudo ipconfig set en0 DHCP
        nc -vz apple.com 443
        netstat -rn
        """#,
         "重新获取 IP、测 TCP 端口可达、查看路由。", .safe, nil),

        // MARK: 界面技巧
        ("界面技巧", "显示 / 隐藏隐藏文件", #"defaults write com.apple.finder AppleShowAllFiles -bool true; killall Finder"#,
         "临时切换用快捷键 ⌘⇧.。", .safe, nil),
        ("界面技巧", "显示所有文件扩展名", #"defaults write NSGlobalDomain AppleShowAllExtensions -bool true; killall Finder"#,
         "全局显示扩展名。", .safe, nil),
        ("界面技巧", "标题栏显示完整 POSIX 路径", #"defaults write com.apple.finder _FXShowPosixPathInTitle -bool true; killall Finder"#,
         "窗口标题显示完整路径。", .safe, nil),
        ("界面技巧", "显示路径栏 / 状态栏", #"""
        defaults write com.apple.finder ShowPathbar   -bool true
        defaults write com.apple.finder ShowStatusBar -bool true; killall Finder
        """#,
         "底部显示路径与项目数量/剩余空间。", .safe, nil),
        ("界面技巧", "重启 Finder / Dock / 菜单栏", #"""
        killall Finder
        killall Dock
        killall SystemUIServer
        """#,
         "卡死、图标错乱时救急。", .safe, nil),
        ("界面技巧", "修改截图保存目录", #"""
        mkdir -p ~/Pictures/Screenshots
        defaults write com.apple.screencapture location ~/Pictures/Screenshots; killall SystemUIServer
        """#,
         "整理散落桌面的截图。", .safe, nil),
        ("界面技巧", "修改截图格式", #"defaults write com.apple.screencapture type jpg; killall SystemUIServer"#,
         "可选 png/jpg/pdf/tiff/heic。", .safe, nil),
        ("界面技巧", "截图去掉窗口阴影", #"defaults write com.apple.screencapture disable-shadow -bool true; killall SystemUIServer"#,
         "窗口截图不再带阴影。", .safe, nil),
        ("界面技巧", "截图不带日期后缀 / 自定义前缀", #"""
        defaults write com.apple.screencapture include-date -bool false
        defaults write com.apple.screencapture name "Shot"; killall SystemUIServer
        """#,
         "自定义截图文件名。", .safe, nil),
        ("界面技巧", "Dock 去掉自动隐藏延迟与动画", #"""
        defaults write com.apple.dock autohide-delay -float 0
        defaults write com.apple.dock autohide-time-modifier -float 0; killall Dock
        """#,
         "Dock 显隐瞬间完成。", .safe, nil),
        ("界面技巧", "Dock 只显示已打开的 App", #"defaults write com.apple.dock static-only -bool true; killall Dock"#,
         "Dock 只保留正在运行的 App。", .caution, nil),
        ("界面技巧", "Dock 添加空白分隔占位", #"defaults write com.apple.dock persistent-apps -array-add '{"tile-type"="spacer-tile";}'; killall Dock"#,
         "给 Dock 加一个可拖动的空白分隔。", .safe, nil),
        ("界面技巧", "禁止在网络盘 / U 盘生成 .DS_Store", #"""
        defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
        defaults write com.apple.desktopservices DSDontWriteUSBStores    -bool true
        """#,
         "避免在网络/U 盘留下 .DS_Store。", .safe, nil),
        ("界面技巧", "加快窗口与动画速度", #"""
        defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
        defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
        """#,
         "让窗口缩放/动画更快。", .safe, nil),
        ("界面技巧", "键盘极速重复 + 关闭长按重音", #"""
        defaults write NSGlobalDomain KeyRepeat -int 2
        defaults write NSGlobalDomain InitialKeyRepeat -int 15
        defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false
        """#,
         "方向键与删除键连发;注销重登生效。", .safe, nil),
        ("界面技巧", "隐藏 / 恢复桌面所有图标", #"defaults write com.apple.finder CreateDesktop -bool false; killall Finder"#,
         "false=隐藏桌面图标(录屏/演示常用)。", .caution, nil),
        ("界面技巧", "保存 / 打印对话框默认展开", #"""
        defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
        defaults write NSGlobalDomain PMPrintingExpandedStateForPrint    -bool true
        """#,
         "对话框默认展开为详细视图。", .safe, nil),
        ("界面技巧", "Finder ⌘Q 退出 / 搜索默认当前文件夹", #"""
        defaults write com.apple.finder QuitMenuItem -bool true
        defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"; killall Finder
        """#,
         "SCcf=搜索范围默认当前文件夹。", .safe, nil),

        // MARK: 逆向·开发
        ("逆向·开发", "查看二进制的动态库依赖", #"otool -L /path/binary"#, "列出链接的动态库。", .safe, nil),
        ("逆向·开发", "查看 load commands / rpath", #"otool -l /path/binary | grep -A2 LC_RPATH"#, "查看 LC_RPATH 等。", .safe, nil),
        ("逆向·开发", "修改依赖库路径", #"install_name_tool -change /old/libfoo.dylib @rpath/libfoo.dylib /path/binary"#,
         "改完签名失效,需重签。", .caution, nil),
        ("逆向·开发", "修改库自身 install name / 添加 rpath", #"""
        install_name_tool -id @rpath/libfoo.dylib /path/libfoo.dylib
        install_name_tool -add_rpath @executable_path/../Frameworks /path/binary
        """#,
         "调整库标识与运行时搜索路径。", .caution, nil),
        ("逆向·开发", "查看 / 瘦身 / 合并架构(lipo)", #"""
        lipo -info /path/binary
        lipo /path/binary -thin arm64 -output /path/binary.arm64
        lipo a_x86_64 a_arm64 -create -output a_universal
        """#,
         "universal 包瘦身或合并单架构。", .caution, nil),
        ("逆向·开发", "ldid 伪签名 / 处理 entitlements", #"""
        brew install ldid
        ldid -S /path/binary
        ldid -Sent.xml /path/binary
        ldid -e /path/binary > ent.xml
        """#,
         "越狱环境或需要「假签名 + entitlements」时用。", .caution, nil),
        ("逆向·开发", "解包 / 打包 deb", #"""
        dpkg-deb -R pkg.deb out/
        dpkg-deb -c pkg.deb
        dpkg-deb -b out/ new.deb
        """#,
         "改 deb 内容或做插件包。", .safe, nil),
        ("逆向·开发", "给 ipa 注入 dylib(完整流程)", #"""
        unzip App.ipa -d payloaddir && cd payloaddir
        mkdir -p "Payload/App.app/Frameworks"
        cp ~/MyLib.dylib "Payload/App.app/Frameworks/"
        insert_dylib --strip-codesig --inplace "@executable_path/Frameworks/MyLib.dylib" "Payload/App.app/App"
        zip -r ../patched.ipa Payload
        """#,
         "本 App 的「IPA 注入」页已用原生 Swift 实现该流程,无需 insert_dylib。", .danger, "加密(App Store)ipa 需先脱壳;注入后原签名失效需重签"),
        ("逆向·开发", "查看符号表 / 字符串 / 反汇编", #"""
        nm -gU /path/binary
        strings -a /path/binary | grep -i "http"
        otool -tV /path/binary | less
        xxd /path/file | less
        """#,
         "静态分析常用只读命令。", .safe, nil),
        ("逆向·开发", "dyld 注入调试(受 SIP 限制)", #"""
        DYLD_PRINT_LIBRARIES=1 /path/your_own_binary
        DYLD_INSERT_LIBRARIES=/path/hook.dylib /path/your_own_binary
        """#,
         "hook 库加载;系统程序被 SIP 拦截。", .caution, "系统程序受 SIP 限制"),
        ("逆向·开发", "安装 / 修复 Xcode 命令行工具", #"""
        xcode-select --install
        sudo xcode-select -r
        sudo xcodebuild -license accept
        """#,
         "git/clang 提示需要 CLT 或路径错乱时用。", .caution, nil),

        // MARK: 性能·电池·硬件
        ("性能·电池·硬件", "电池健康(循环次数 / 状态)", #"system_profiler SPPowerDataType | grep -A3 -i "cycle\|condition\|full charge""#,
         "查看循环次数与健康度。", .safe, nil),
        ("性能·电池·硬件", "电池 / 电源实时状态", #"""
        pmset -g batt
        pmset -g
        """#,
         "当前电量、是否充电与全部电源设置。", .safe, nil),
        ("性能·电池·硬件", "阻止 Mac 睡眠", #"""
        caffeinate -dimsu
        caffeinate -t 3600
        caffeinate -i <长命令>
        """#,
         "演示或长任务时保持唤醒,Ctrl-C 结束。", .safe, nil),
        ("性能·电池·硬件", "设置显示器 / 系统睡眠时间", #"""
        sudo pmset displaysleep 15
        sudo pmset sleep 0
        """#,
         "15 分钟息屏;接电源从不休眠。", .caution, nil),
        ("性能·电池·硬件", "查看 CPU / 内存占用", #"""
        top -o cpu
        top -o mem
        vm_stat
        memory_pressure
        """#,
         "按 CPU/内存排序与分页统计。", .safe, nil),
        ("性能·电池·硬件", "硬件 / CPU / 内存信息", #"""
        system_profiler SPHardwareDataType
        sysctl -n machdep.cpu.brand_string
        sysctl -n hw.memsize
        """#,
         "型号、芯片与物理内存。", .safe, nil),
        ("性能·电池·硬件", "系统版本 / 内核 / 序列号", #"""
        sw_vers
        uname -a
        system_profiler SPHardwareDataType | grep -i "serial"
        """#,
         "macOS 版本、内核与序列号。", .safe, nil),
        ("性能·电池·硬件", "强制退出无响应 App / 按名杀进程", #"""
        killall "App Name"
        pkill -f keyword
        """#,
         "未保存数据会丢失。", .caution, nil),

        // MARK: Time Machine·启动项
        ("Time Machine·启动项", "列出本地快照", #"tmutil listlocalsnapshots /"#,
         "磁盘删了大文件空间不涨,常因本地快照占用。", .safe, nil),
        ("Time Machine·启动项", "删除本地快照释放空间", #"""
        sudo tmutil deletelocalsnapshots 2026-01-07-221601
        tmutil thinlocalsnapshots / 21474836480 4
        """#,
         "删指定时间点,或按需回收字节数(urgency 1-4)。", .caution, nil),
        ("Time Machine·启动项", "Time Machine 备份控制", #"""
        tmutil status
        tmutil startbackup --block
        tmutil localsnapshot
        """#,
         "查看状态、立即备份、建本地快照。", .safe, nil),
        ("Time Machine·启动项", "查看 / 管理启动项(launchd)", #"""
        launchctl list | grep -v com.apple
        ls ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons
        """#,
         "排查开机自启与可疑常驻项。", .safe, nil),
        ("Time Machine·启动项", "加载 / 卸载 / 禁用 launch agent", #"""
        launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/x.plist
        launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/x.plist
        launchctl disable   gui/$(id -u)/<label>
        """#,
         "新式 bootout/bootstrap;旧式为 unload/load -w。", .caution, nil),
        ("Time Machine·启动项", "软件更新(命令行)", #"""
        softwareupdate -l
        softwareupdate -ia
        softwareupdate -ia --restart
        """#,
         "列出/安装全部更新,可自动重启。", .caution, nil),
        ("Time Machine·启动项", "图片批处理(sips)", #"""
        sips -s format png in.jpg --out out.png
        sips -Z 1024 *.jpg
        sips -g pixelWidth -g pixelHeight in.jpg
        """#,
         "转格式、等比缩放、读尺寸。", .safe, nil),
        ("Time Machine·启动项", "生成 .icns 应用图标", #"""
        mkdir icon.iconset
        sips -z 512 512 src.png --out icon.iconset/icon_512x512.png
        iconutil -c icns icon.iconset
        """#,
         "需补齐各尺寸再转 icns。", .safe, nil),
        ("Time Machine·启动项", "剪贴板 / 语音 / UUID / 随机密码", #"""
        pbcopy < file.txt
        pbpaste > out.txt
        say "任务完成"
        uuidgen
        openssl rand -base64 16
        """#,
         "常用一行小工具。", .safe, nil),
        ("Time Machine·启动项", "Finder 相关 open 技巧", #"""
        open .
        open -R /path/file
        open -a "Visual Studio Code" /path/file
        """#,
         "打开目录、定位选中、指定 App 打开。", .safe, nil),
        ("Time Machine·启动项", "快速起本地静态文件服务器", #"python3 -m http.server 8000"#,
         "临时共享目录,浏览器访问 http://本机IP:8000。", .safe, nil),
        ("Time Machine·启动项", "用 mdfind 从终端搜 Spotlight", #"""
        mdfind -name "report.pdf"
        mdfind "kMDItemContentType == 'com.adobe.pdf'"
        """#,
         "命令行调用 Spotlight 索引搜索。", .safe, nil),

        // MARK: Homebrew
        ("Homebrew", "从 brew doctor 开始诊断", #"brew doctor"#,
         "多数警告无害;重点看 CLT 过期、PATH 顺序。", .safe, nil),
        ("Homebrew", "Apple Silicon 找不到 brew(PATH)", #"""
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
        """#,
         "Apple Silicon 装在 /opt/homebrew;Intel 为 /usr/local。", .safe, nil),
        ("Homebrew", "误用 sudo 后修复权限", #"sudo chown -R $(whoami) /opt/homebrew"#,
         "Homebrew 不应加 sudo;Intel 换成 /usr/local。", .danger, nil),
        ("Homebrew", "tap / update 出错", #"brew update-reset"#,
         "重置并重新克隆 tap 仓库。", .caution, nil),
        ("Homebrew", "常规更新与升级", #"""
        brew update && brew upgrade
        brew upgrade --cask
        """#,
         "升级可能引入不兼容,留意变更。", .caution, nil),

        // MARK: 安全开关
        ("安全开关", "应用防火墙开关", #"""
        defaults write /Library/Preferences/com.apple.alf globalstate -int 1
        sudo pkill -HUP socketfilterfw
        """#,
         "1 开 0 关。", .caution, nil),
        ("安全开关", "开启防火墙隐身模式(不响应 ping)", #"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on"#,
         "对外不响应探测。", .caution, nil),
        ("安全开关", "查看 FileVault 磁盘加密状态", #"fdesetup status"#, "查看磁盘是否加密。", .safe, nil),
        ("安全开关", "查看 XProtect / MRT 等安全组件版本", #"system_profiler SPInstallHistoryDataType | grep -i -A2 "XProtect\|MRT""#,
         "查看内置安全组件更新历史。", .safe, nil),
        ("安全开关", "引导辅助功能 / 完全磁盘访问", #"""
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        """#,
         "TCC 保护,不能命令行直接授予,只能打开设置页手动勾选。", .safe, nil),

        // MARK: 终端·输入法
        ("终端·输入法", "查看 / 切换默认 shell", #"""
        echo $SHELL
        chsh -s /bin/zsh
        """#,
         "切换登录 shell。", .caution, nil),
        ("终端·输入法", "让 .zshrc 立即生效", #"source ~/.zshrc"#, "重新加载 zsh 配置。", .safe, nil),
        ("终端·输入法", "关闭「上次会话恢复」终端标签", #"defaults write com.apple.Terminal NSQuitAlwaysKeepsWindows -bool false"#,
         "退出终端不再恢复上次窗口。", .safe, nil),
        ("终端·输入法", "查看输入法 / 键盘布局偏好", #"defaults read ~/Library/Preferences/com.apple.HIToolbox.plist AppleEnabledInputSources"#,
         "查看已启用的输入源。", .safe, nil),
        ("终端·输入法", "关闭自动纠正 / 智能标点(写代码友好)", #"""
        defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
        defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled  -bool false
        defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled   -bool false
        """#,
         "避免代码里被自动改成中文标点。", .safe, nil),

        // MARK: 诊断采集
        ("诊断采集", "一键系统概览", #"sw_vers; echo; sysctl -n machdep.cpu.brand_string; echo "内存: $(($(sysctl -n hw.memsize)/1024/1024/1024)) GB"; df -h /"#,
         "版本、芯片、内存与磁盘一览。", .safe, nil),
        ("诊断采集", "磁盘容量与 purgeable 占比", #"""
        df -h /
        diskutil info / | grep -i "Container Free\|Free"
        """#,
         "查看可清理(purgeable)空间。", .safe, nil),
        ("诊断采集", "列出占空间最大的用户文件夹", #"du -sh ~/* ~/Library/* 2>/dev/null | sort -rh | head -20"#,
         "找出主目录里的占用大户。", .safe, nil),
        ("诊断采集", "查看最近安装 / 崩溃报告", #"""
        ls -lt ~/Library/Logs/DiagnosticReports | head
        system_profiler SPInstallHistoryDataType | head -40
        """#,
         "排查最近变更与崩溃。", .safe, nil),
        ("诊断采集", "查看已连接外设 / 显示器 / 网络接口", #"system_profiler SPUSBDataType SPDisplaysDataType SPNetworkDataType"#,
         "查看 USB、显示器与网络接口。", .safe, nil)
    ]
}
