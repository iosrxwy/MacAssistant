import Foundation

// MARK: - 版本号解析与比较

/// 语义化版本号中的预发布标识符。数字段按整数比较,字母段按 ASCII 字典序,数字段永远小于字母段。
public enum PrereleaseIdentifier: Equatable, Comparable, Sendable {
    case numeric(Int)
    case alphanumeric(String)

    public var text: String {
        switch self {
        case .numeric(let value): return String(value)
        case .alphanumeric(let value): return value
        }
    }

    public static func < (lhs: PrereleaseIdentifier, rhs: PrereleaseIdentifier) -> Bool {
        switch (lhs, rhs) {
        case (.numeric(let l), .numeric(let r)): return l < r
        case (.alphanumeric(let l), .alphanumeric(let r)): return l < r
        case (.numeric, .alphanumeric): return true
        case (.alphanumeric, .numeric): return false
        }
    }
}

/// 宽松的语义化版本号。解析成功即代表可以安全比较,解析失败返回 nil 由调用方兜底。
///
/// 容忍的写法:`v` 前缀、位数不足(`1.2` 等价 `1.2.0`)、构建元数据(`1.2.0+abc` 忽略 `+` 之后)。
/// 拒绝的写法:空串、含非数字段(`1.2.x`)、空段(`1..2`、`1.2.`)、空预发布段(`1.2.0-`)。
public struct AppVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    /// 主版本段,长度不定;比较时短的一侧按 0 补齐。
    public let numbers: [Int]
    /// 预发布段,为空表示正式版。
    public let prerelease: [PrereleaseIdentifier]

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 构建元数据不参与优先级比较(semver 规定),直接丢弃。
        let withoutMetadata = trimmed.split(separator: "+", maxSplits: 1,
                                            omittingEmptySubsequences: false)[0]
        var core = Substring(withoutMetadata)
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        guard !core.isEmpty else { return nil }

        let parts = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let numericPart = parts.first, !numericPart.isEmpty else { return nil }

        var numbers: [Int] = []
        for component in numericPart.split(separator: ".", omittingEmptySubsequences: false) {
            // unicodeScalars 判断可以挡住全角数字和 "+1" / "-1" 这类 Int() 会接受的写法。
            guard !component.isEmpty,
                  component.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                  let value = Int(component)
            else { return nil }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }

        var prerelease: [PrereleaseIdentifier] = []
        if parts.count == 2 {
            let raw = parts[1]
            guard !raw.isEmpty else { return nil }
            for component in raw.split(separator: ".", omittingEmptySubsequences: false) {
                guard !component.isEmpty,
                      component.unicodeScalars.allSatisfy({ CharacterSet.prereleaseAllowed.contains($0) })
                else { return nil }
                if component.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                   let value = Int(component) {
                    prerelease.append(.numeric(value))
                } else {
                    prerelease.append(.alphanumeric(String(component)))
                }
            }
        }

        self.numbers = numbers
        self.prerelease = prerelease
    }

    /// 规范化写法:至少三段,去掉第三段之后多余的 0。用于展示以及「跳过此版本」的持久化 key。
    public var canonical: String {
        var components = numbers
        while components.count > 3, components.last == 0 { components.removeLast() }
        while components.count < 3 { components.append(0) }
        let base = components.map(String.init).joined(separator: ".")
        guard !prerelease.isEmpty else { return base }
        return base + "-" + prerelease.map(\.text).joined(separator: ".")
    }

    public var description: String { canonical }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }

        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false    // 正式版大于同号预发布版
        case (false, true): return true
        case (false, false):
            for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
                guard index < lhs.prerelease.count else { return true }   // 段数少的更小
                guard index < rhs.prerelease.count else { return false }
                if lhs.prerelease[index] != rhs.prerelease[index] {
                    return lhs.prerelease[index] < rhs.prerelease[index]
                }
            }
            return false
        }
    }

    /// 与 `<` 保持同一套补零 / 预发布规则,`1.2` 与 `1.2.0` 判定相等。
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// 任一侧解析失败都返回 false:宁可漏报「有新版本」,也不能误报。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = AppVersion(candidate), let current = AppVersion(current) else {
            return false
        }
        return candidate > current
    }
}

private extension CharacterSet {
    static let prereleaseAllowed = CharacterSet(charactersIn:
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-")
}

// MARK: - 当前版本来源

/// 运行时版本号来源。优先 Info.plist,读不到再回退到常量。
///
/// 三种启动方式的实际表现:
/// - `dist/Mac小助手.app`:`build_app.sh` 把 `Resources/AppVersion.txt` 写进了 `CFBundleShortVersionString`,读得到真实版本。
/// - `swift run` / Xcode 直接跑 SwiftPM 可执行文件:没有 Info.plist,走 `fallbackVersion`。
public enum AppVersionSource {
    /// 必须与仓库根目录 `Resources/AppVersion.txt` 一致,`UpdateServiceTests` 会校验两者不漂移。
    public static let fallbackVersion = "1.0.0-beta.1"

    /// 纯函数形式,方便测试。传入解析不了的内容一律回退,保证任何启动方式都拿得到可比较的版本号。
    public static func resolve(infoDictionaryVersion: String?) -> String {
        guard let raw = infoDictionaryVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              AppVersion(raw) != nil
        else { return fallbackVersion }
        return raw
    }

    public static var current: String {
        resolve(
            infoDictionaryVersion: Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }
}

// MARK: - GitHub 数据模型

/// GitHub `releases/latest` 返回体中本功能用得到的字段。未知字段一律忽略。
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public let tagName: String
    public let htmlURL: URL
    public let name: String?
    public let body: String?
    public let publishedAt: String?
    public let prerelease: Bool
    public let draft: Bool

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case name, body, prerelease, draft
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        // 缺字段时按「正式发布」处理,后续的 tag 比较仍然会拦住不合理的版本号。
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
    }

    public var publishedDate: Date? {
        guard let publishedAt else { return nil }
        return ISO8601DateFormatter().date(from: publishedAt)
    }
}

/// 提示弹窗需要的全部信息。
public struct UpdateInfo: Equatable, Sendable {
    /// 规范化版本号,用于展示与「跳过此版本」的比较。
    public let version: String
    /// GitHub 上的原始 tag,便于用户核对。
    public let tagName: String
    public let releaseURL: URL
    public let title: String
    public let releaseNotes: String
    public let publishedAt: Date?

    public init(
        version: String,
        tagName: String,
        releaseURL: URL,
        title: String,
        releaseNotes: String,
        publishedAt: Date?
    ) {
        self.version = version
        self.tagName = tagName
        self.releaseURL = releaseURL
        self.title = title
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
    }

    /// 弹窗里只放摘要:release body 可能很长,完整内容交给网页。
    public func releaseNotesSummary(maxLines: Int = 6, maxCharacters: Int = 280) -> String {
        let lines = releaseNotes
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }

        var truncated = lines.count > maxLines
        var text = lines.prefix(maxLines).joined(separator: "\n")
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            truncated = true
        }
        return truncated ? text + "…" : text
    }
}

// MARK: - 错误与结果

/// 检查更新的失败原因。只有手动检查才会把这些文案显示给用户。
public enum UpdateCheckError: Error, Equatable, Sendable {
    /// 网络不可达、超时、DNS 失败、代理不通等,统一归为一类。
    case network
    /// 403 且 `X-RateLimit-Remaining: 0`,或者 429。
    case rateLimited
    /// 403 但不是限流,常见于缺少 User-Agent 或被 WAF 拦截。
    case forbidden
    /// HTTP 成功但返回体不是预期结构。
    case decoding
    /// 其他非 2xx 状态码。
    case server(status: Int)

    public var message: String {
        switch self {
        case .network:
            return "无法连接 GitHub，请检查网络或代理设置。"
        case .rateLimited:
            return "GitHub 接口访问次数已达上限，请稍后再试。"
        case .forbidden:
            return "GitHub 拒绝了本次请求（403），请稍后再试。"
        case .decoding:
            return "GitHub 返回的数据无法解析，可能是接口有变化。"
        case .server(let status):
            return "GitHub 服务返回异常（HTTP \(status)），请稍后再试。"
        }
    }
}

/// 一次成功的检查得到的结论。注意「暂无发布版本」不是错误。
public enum UpdateCheckOutcome: Equatable, Sendable {
    case updateAvailable(UpdateInfo)
    case upToDate(currentVersion: String)
    /// 仓库还没建、或者建了但一个 release 都没发,GitHub 都返回 404。
    case noReleasePublished
}

/// 自动检查的最终动作。除了「确实有该提示的新版本」以外一律静默。
public enum UpdatePromptDecision: Equatable, Sendable {
    case prompt(UpdateInfo)
    case silent
}

/// 手动检查的结果,每一种都有面向用户的中文文案。
public enum ManualCheckResult: Equatable, Sendable {
    case updateAvailable(UpdateInfo)
    case upToDate(currentVersion: String)
    case noRelease
    case failed(UpdateCheckError)

    public var message: String {
        switch self {
        case .updateAvailable(let info):
            return "发现新版本 \(info.version)，可前往 GitHub 查看。"
        case .upToDate(let version):
            return "已是最新版本（\(version)）。"
        case .noRelease:
            return "项目暂无发布版本。"
        case .failed(let error):
            return error.message
        }
    }
}

// MARK: - 偏好存储

/// `UserDefaults` 的最小抽象,单元测试用内存实现替换,避免污染真实域。
public protocol UpdateDefaults: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func bool(forKey defaultName: String) -> Bool
    func double(forKey defaultName: String) -> Double
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: UpdateDefaults {}

/// 自动检查开关、节流时间戳、已跳过版本的持久化。
public struct UpdatePreferences {
    public enum Key {
        public static let automaticCheckEnabled = "update.automaticCheckEnabled"
        public static let lastCheckTimestamp = "update.lastCheckTimestamp"
        public static let skippedVersion = "update.skippedVersion"
    }

    /// 每天最多检查一次。
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UpdateDefaults

    public init(defaults: UpdateDefaults = UserDefaults.standard) {
        self.defaults = defaults
    }

    /// 默认开启:从没写过这个 key 时返回 true。
    public var automaticCheckEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.automaticCheckEnabled) != nil else { return true }
            return defaults.bool(forKey: Key.automaticCheckEnabled)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.automaticCheckEnabled) }
    }

    public var lastCheckDate: Date? {
        get {
            let timestamp = defaults.double(forKey: Key.lastCheckTimestamp)
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        }
        nonmutating set { defaults.set(newValue?.timeIntervalSince1970, forKey: Key.lastCheckTimestamp) }
    }

    public var skippedVersion: String? {
        get { defaults.string(forKey: Key.skippedVersion) }
        nonmutating set { defaults.set(newValue, forKey: Key.skippedVersion) }
    }

    public func isCheckDue(now: Date) -> Bool {
        guard let last = lastCheckDate else { return true }
        let elapsed = now.timeIntervalSince(last)
        // elapsed < 0 说明系统时间被往回调过,这种情况按「该检查了」处理,否则可能永远不再检查。
        return elapsed >= Self.checkInterval || elapsed < 0
    }

    /// 已跳过的版本不再自动提示,但更高的版本仍然要提示。
    public func shouldPrompt(for info: UpdateInfo) -> Bool {
        guard let skipped = skippedVersion,
              let skippedVersion = AppVersion(skipped),
              let candidate = AppVersion(info.version)
        else { return true }
        return candidate > skippedVersion
    }

    public func skip(_ info: UpdateInfo) {
        skippedVersion = info.version
    }

    public func clearSkippedVersion() {
        skippedVersion = nil
    }
}

// MARK: - 检查服务

/// 向 GitHub 查询最新 release 并给出是否需要提示的结论。
///
/// 只读版本号,不下载、不安装、不上传任何用户数据。当前 App 是 ad-hoc 签名的开发构建,
/// 自动替换二进制不安全,所以这里只负责提示 + 跳转浏览器。
public struct UpdateService {
    /// 网络层抽象。默认走 `URLSession`,测试注入固定 fixture,单测不会真的联网。
    public typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    /// 超时设短一些,启动时的检查不该让任何东西等它。
    public static let requestTimeout: TimeInterval = 10

    private let currentVersion: String
    private let preferences: UpdatePreferences
    private let transport: Transport

    public init(
        currentVersion: String = AppVersionSource.current,
        preferences: UpdatePreferences = UpdatePreferences(),
        transport: @escaping Transport = UpdateService.defaultTransport
    ) {
        self.currentVersion = currentVersion
        self.preferences = preferences
        self.transport = transport
    }

    // MARK: 请求构造

    public static func userAgent(currentVersion: String) -> String {
        "MacAssistant/\(currentVersion) (+\(ProductLinks.Repository.homepage.absoluteString))"
    }

    public static func makeRequest(currentVersion: String) -> URLRequest {
        var request = URLRequest(
            url: ProductLinks.Repository.latestReleaseAPI,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "GET"
        // GitHub 对没有 User-Agent 的请求直接返回 403,这个头不能省。
        request.setValue(userAgent(currentVersion: currentVersion), forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// 默认配置刻意不设置 `connectionProxyDictionary`:保持系统代理生效,用户挂梯子时才连得上。
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    public static let defaultTransport: Transport = { request in
        try await session.data(for: request)
    }

    // MARK: 纯逻辑

    /// draft / prerelease 一律不提示:`releases/latest` 本就不该返回它们,真收到了说明状态异常,
    /// 而给开发构建推未定稿的版本只会造成困扰。
    public static func evaluate(release: GitHubRelease, currentVersion: String) -> UpdateCheckOutcome {
        guard !release.draft, !release.prerelease else {
            return .upToDate(currentVersion: currentVersion)
        }
        guard let latest = AppVersion(release.tagName),
              let current = AppVersion(currentVersion),
              latest > current
        else {
            // tag 解析不了时按「无更新」兜底,避免把 "nightly" 之类的 tag 误报成新版本。
            return .upToDate(currentVersion: currentVersion)
        }

        let title = release.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .updateAvailable(
            UpdateInfo(
                version: latest.canonical,
                tagName: release.tagName,
                releaseURL: release.htmlURL,
                title: (title?.isEmpty == false ? title! : "版本 \(latest.canonical)"),
                releaseNotes: notes,
                publishedAt: release.publishedDate
            )
        )
    }

    static func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        if response.statusCode == 429 { return true }
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?
            .trimmingCharacters(in: .whitespaces)
        return remaining == "0"
    }

    // MARK: 网络

    /// 单次检查。抛出的错误一定是 `UpdateCheckError`。
    public func checkForUpdate() async throws -> UpdateCheckOutcome {
        let request = Self.makeRequest(currentVersion: currentVersion)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            // URLError 的各种子类型(超时 / DNS / 无网络 / 代理失败)对用户来说是同一件事。
            throw UpdateCheckError.network
        }

        guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.network }

        switch http.statusCode {
        case 200...299:
            break
        case 404:
            // 仓库还没建,或者建了但没发过 release —— 这是正常状态,不是错误。
            return .noReleasePublished
        case 403, 429:
            throw Self.isRateLimited(http) ? UpdateCheckError.rateLimited : UpdateCheckError.forbidden
        default:
            throw UpdateCheckError.server(status: http.statusCode)
        }

        do {
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            return Self.evaluate(release: release, currentVersion: currentVersion)
        } catch {
            throw UpdateCheckError.decoding
        }
    }

    /// 启动时的自动检查:受开关和 24 小时节流约束,任何失败都静默吞掉。
    public func runAutomaticCheck(now: Date = Date()) async -> UpdatePromptDecision {
        guard preferences.automaticCheckEnabled, preferences.isCheckDue(now: now) else {
            return .silent
        }
        // 先记时间戳:失败也算用掉了今天的额度,否则离线时每次启动都要白等一轮超时。
        preferences.lastCheckDate = now

        guard let outcome = try? await checkForUpdate() else { return .silent }
        guard case .updateAvailable(let info) = outcome,
              preferences.shouldPrompt(for: info)
        else { return .silent }
        return .prompt(info)
    }

    /// 「关于」页的手动检查:忽略节流与已跳过版本(用户主动问了就如实回答),失败会返回原因。
    public func runManualCheck(now: Date = Date()) async -> ManualCheckResult {
        preferences.lastCheckDate = now
        do {
            switch try await checkForUpdate() {
            case .updateAvailable(let info): return .updateAvailable(info)
            case .upToDate(let version): return .upToDate(currentVersion: version)
            case .noReleasePublished: return .noRelease
            }
        } catch let error as UpdateCheckError {
            return .failed(error)
        } catch {
            return .failed(.network)
        }
    }
}
