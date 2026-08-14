import Foundation

public enum ProductLinks {
    /// 开源仓库坐标的唯一来源:改名或迁移账号只需要动这里的 owner / name。
    public enum Repository {
        public static let owner = "iosrxwy"
        public static let name = "MacAssistant"

        public static var slug: String { "\(owner)/\(name)" }

        /// 仓库主页。
        public static var homepage: URL {
            URL(string: "https://github.com/\(slug)")!
        }

        /// Releases 列表页,没有任何发布版本时也能正常打开。
        public static var releasesPage: URL {
            homepage.appendingPathComponent("releases")
        }

        /// 最新正式版接口。仓库不存在或尚未发布任何 release 时返回 404。
        public static var latestReleaseAPI: URL {
            URL(string: "https://api.github.com/repos/\(slug)/releases/latest")!
        }
    }

    public static let github = Repository.homepage
    public static let releaseChannel = URL(string: "https://t.me/iosrxwy")!
    public static let classDumpProject = URL(string: "https://github.com/nygard/class-dump")!
    public static let dsdumpProject = URL(string: "https://github.com/DerekSelander/dsdump")!
    public static let applePlatformSecurity = URL(string: "https://support.apple.com/guide/security/welcome/web")!
}
