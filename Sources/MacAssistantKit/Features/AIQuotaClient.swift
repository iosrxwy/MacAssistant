import CommonCrypto
import Foundation
import Security
import SQLite3

/// 读取本机已经登录过的 Cursor、Codex、Claude，向它们自己的用量接口查剩余额度。
/// 令牌只留在这次请求的内存里，不写回磁盘，也不换发新令牌。
public enum AIQuotaClient {
    public static func load(interactiveKeychain: Bool) async -> [AIQuotaSnapshot] {
        let secrets = AIQuotaSecrets.collect(interactive: interactiveKeychain)
        async let cursorFamily = cursorFamily(secrets)
        async let codex = codex(secrets)
        async let claude = claude(secrets)
        async let grok = grok()
        async let gemini = gemini()
        async let muse = muse()
        let cursor = await cursorFamily
        let loaded = [cursor.cursor, await codex, await gemini, await grok, await claude, cursor.grokBot, await muse]
        return AIQuotaProviderID.displayOrder.compactMap { id in
            loaded.first { $0.id == id }
        }.filter { snapshot in
            if snapshot.state == .ready { return !snapshot.windows.isEmpty }
            return snapshot.state == .needsKeychain
        }
    }

    private static func cursorFamily(_ secrets: AIQuotaSecrets) async -> (cursor: AIQuotaSnapshot, grokBot: AIQuotaSnapshot) {
        guard let token = secrets.cursorToken else {
            let state = secrets.cursorProblem ?? .notSignedIn
            return (empty(.cursor, state), empty(.grokBot, state))
        }
        guard let cookie = cursorCookie(token) else {
            return (empty(.cursor, .expired), empty(.grokBot, .expired))
        }
        async let summary = request(
            url: URL(string: "https://cursor.com/api/usage-summary")!,
            method: "GET",
            token: token,
            account: nil,
            origin: "https://cursor.com",
            userAgent: browserAgent,
            cookie: cookie,
            referer: "https://cursor.com/dashboard"
        )
        // 设置页的 Cursor Models / Other Models 来自这一个只读查询。用量摘要里的合计不是这两条。
        async let period = request(
            url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!,
            method: "POST",
            token: token,
            account: nil,
            origin: nil,
            userAgent: browserAgent,
            body: Data("{}".utf8),
            extraHeaders: ["Connect-Protocol-Version": "1"]
        )
        async let sand = request(
            url: URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!,
            method: "POST",
            token: token,
            account: nil,
            origin: "https://cursor.com",
            userAgent: browserAgent,
            body: Data("{}".utf8),
            cookie: cookie,
            referer: "https://cursor.com/dashboard"
        )
        let cursor = cursorSnapshot(summary: await summary, period: await period)
        let grok = snapshot(.grokBot, await sand) { data in
            guard let parsed = AIQuotaParsing.grokBot(data) else { return nil }
            return (parsed.plan, parsed.note, parsed.windows)
        }
        return (cursor, grok)
    }

    /// 周期接口成功时用它的两条额度。失败时退回用量摘要，登录失效才标过期。
    private static func cursorSnapshot(summary: HTTPResult, period: HTTPResult) -> AIQuotaSnapshot {
        func parsed(_ result: HTTPResult) -> (plan: String?, note: String?, windows: [AIQuotaWindow])? {
            guard case .data(let data) = result else { return nil }
            return AIQuotaParsing.cursorSummary(data)
        }
        let fromSummary = parsed(summary)
        let fromPeriod = parsed(period)
        var windows = fromPeriod?.windows ?? []
        if windows.isEmpty {
            windows = fromSummary?.windows ?? []
        } else if windows.allSatisfy({ $0.resetsAt == nil }), let reset = fromSummary?.windows.first?.resetsAt {
            windows = windows.map { window in
                AIQuotaWindow(
                    id: window.id,
                    titleKey: window.titleKey,
                    title: window.title,
                    usedFraction: window.usedFraction,
                    resetsAt: reset
                )
            }
        }
        if !windows.isEmpty {
            return AIQuotaSnapshot(
                id: .cursor,
                plan: fromPeriod?.plan ?? fromSummary?.plan,
                windows: windows,
                note: fromPeriod?.note ?? fromSummary?.note,
                state: .ready,
                fetchedAt: Date()
            )
        }
        if case .data = summary { return empty(.cursor, .failed) }
        if case .data = period { return empty(.cursor, .failed) }
        if case .unauthorized = summary { return empty(.cursor, .expired) }
        if case .unauthorized = period { return empty(.cursor, .expired) }
        if case .unavailable = summary { return empty(.cursor, .unavailable) }
        return empty(.cursor, .failed)
    }

    private static func codex(_ secrets: AIQuotaSecrets) async -> AIQuotaSnapshot {
        guard let login = secrets.codex else {
            return empty(.codex, secrets.codexProblem ?? .notSignedIn)
        }
        let response = await request(
            url: login.usageURL,
            method: "GET",
            token: login.token,
            account: login.accountID,
            origin: nil,
            userAgent: "codex-cli"
        )
        let loaded = snapshot(.codex, response) { data in
            guard let parsed = AIQuotaParsing.codex(data) else { return nil }
            return (parsed.plan, nil, parsed.windows)
        }
        guard loaded.state == .ready, case .data(let data) = response,
              var resets = AIQuotaParsing.codexResets(inUsage: data) else {
            return loaded
        }
        // 用量接口通常只有次数。有次数时再读一次到期时间；读不到就只显示次数。
        if resets.expiries.isEmpty, let detailURL = resetCreditsURL(from: login.usageURL) {
            let detail = await request(
                url: detailURL,
                method: "GET",
                token: login.token,
                account: login.accountID,
                origin: nil,
                userAgent: "codex-cli"
            )
            if case .data(let detailData) = detail,
               let detailed = AIQuotaParsing.codexResetCredits(detailData) {
                resets = detailed
            }
        }
        return AIQuotaSnapshot(
            id: loaded.id,
            plan: loaded.plan,
            windows: loaded.windows,
            note: loaded.note,
            state: loaded.state,
            fetchedAt: loaded.fetchedAt,
            resets: resets
        )
    }

    /// 用量地址以 `/wham/usage` 结尾时，明细在同级的 `rate-limit-reset-credits`。只读，不兑换。
    private static func resetCreditsURL(from usage: URL) -> URL? {
        guard usage.lastPathComponent == "usage" else { return nil }
        return usage.deletingLastPathComponent().appendingPathComponent("rate-limit-reset-credits")
    }

    private static func claude(_ secrets: AIQuotaSecrets) async -> AIQuotaSnapshot {
        guard let token = secrets.claudeToken else {
            return empty(.claude, secrets.claudeProblem ?? .notSignedIn)
        }
        let response = await request(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            method: "GET",
            token: token,
            account: nil,
            origin: nil,
            userAgent: "claude-cli",
            extraHeaders: ["anthropic-beta": "oauth-2025-04-20"]
        )
        return snapshot(.claude, response) { data in
            guard let parsed = AIQuotaParsing.claude(data) else { return nil }
            return (parsed.plan, nil, parsed.windows)
        }
    }

    private static func grok() async -> AIQuotaSnapshot {
        guard let login = GrokAuth.read() else { return empty(.grok, .notSignedIn) }
        var headers = ["X-XAI-Token-Auth": "xai-grok-cli"]
        if let userID = login.userID { headers["x-userid"] = userID }
        let response = await request(
            url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
            method: "GET",
            token: login.token,
            account: nil,
            origin: nil,
            userAgent: "grok-cli",
            extraHeaders: headers
        )
        return snapshot(.grok, response) { data in
            guard let windows = AIQuotaParsing.grokBilling(data) else { return nil }
            return (nil, nil, windows)
        }
    }

    private static func gemini() async -> AIQuotaSnapshot {
        guard let stored = GeminiLogin.read() else { return empty(.gemini, .notSignedIn) }
        let token: String
        if let access = stored.accessToken, !stored.expired {
            token = access
        } else if let refreshed = await GeminiLogin.refresh(stored.refreshToken) {
            token = refreshed
        } else {
            return empty(.gemini, .expired)
        }
        guard let project = await GeminiLogin.projectID(accessToken: token),
              let body = try? JSONSerialization.data(withJSONObject: ["project": project]) else {
            return empty(.gemini, .unavailable)
        }
        let response = await request(
            url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
            method: "POST",
            token: token,
            account: nil,
            origin: nil,
            userAgent: "gemini-cli",
            body: body
        )
        return snapshot(.gemini, response) { data in
            guard let windows = AIQuotaParsing.gemini(data) else { return nil }
            return (nil, nil, windows)
        }
    }

    private static func muse() async -> AIQuotaSnapshot {
        guard let executable = MuseCLI.executable() else { return empty(.muse, .notSignedIn) }
        guard let output = await MuseCLI.usage(executable) else { return empty(.muse, .failed) }
        guard let parsed = AIQuotaParsing.muse(output), !parsed.windows.isEmpty else {
            return empty(.muse, .unavailable)
        }
        return AIQuotaSnapshot(
            id: .muse,
            plan: parsed.plan,
            windows: parsed.windows,
            note: nil,
            state: .ready,
            fetchedAt: Date()
        )
    }

    private static func snapshot(
        _ id: AIQuotaProviderID,
        _ response: HTTPResult,
        parse: (Data) -> (String?, String?, [AIQuotaWindow])?
    ) -> AIQuotaSnapshot {
        switch response {
        case .unauthorized:
            return empty(id, .expired)
        case .unavailable:
            return empty(id, .unavailable)
        case .failed:
            return empty(id, .failed)
        case .data(let data):
            guard let parsed = parse(data) else { return empty(id, .failed) }
            if parsed.2.isEmpty { return empty(id, .unavailable) }
            return AIQuotaSnapshot(
                id: id,
                plan: parsed.0,
                windows: parsed.2,
                note: parsed.1,
                state: .ready,
                fetchedAt: Date()
            )
        }
    }

    private static func empty(_ id: AIQuotaProviderID, _ state: AIQuotaState) -> AIQuotaSnapshot {
        AIQuotaSnapshot(id: id, plan: nil, windows: [], note: nil, state: state, fetchedAt: Date())
    }

    private static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private enum HTTPResult {
        case data(Data)
        case unauthorized
        case unavailable
        case failed
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    private static func request(
        url: URL,
        method: String,
        token: String,
        account: String?,
        origin: String?,
        userAgent: String,
        body: Data? = nil,
        extraHeaders: [String: String] = [:],
        cookie: String? = nil,
        referer: String? = nil
    ) async -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        } else {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let account, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let referer = referer ?? origin {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200..<300:
                return data.count < 2_000_000 ? .data(data) : .failed
            case 401, 403:
                return .unauthorized
            case 404:
                return .unavailable
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }
}

// MARK: - 本机登录

private struct CodexLogin: Sendable {
    var token: String
    var accountID: String?
    var usageURL: URL
}

private struct AIQuotaSecrets: Sendable {
    var cursorToken: String?
    var cursorProblem: AIQuotaState?
    var claudeToken: String?
    var claudeProblem: AIQuotaState?
    var codex: CodexLogin?
    var codexProblem: AIQuotaState?

    static func collect(interactive: Bool) -> AIQuotaSecrets {
        var secrets = AIQuotaSecrets()
        switch CursorLogin.read(interactive: interactive) {
        case .ready(let token):
            secrets.cursorToken = token
        case .expired:
            secrets.cursorProblem = .expired
        case .needsPrompt:
            secrets.cursorProblem = .needsKeychain
        case .missing:
            secrets.cursorProblem = .notSignedIn
        }
        switch ClaudeLogin.read(interactive: interactive) {
        case .ready(let token):
            secrets.claudeToken = token
        case .expired:
            secrets.claudeProblem = .expired
        case .needsPrompt:
            secrets.claudeProblem = .needsKeychain
        case .missing:
            secrets.claudeProblem = .notSignedIn
        }
        switch CodexAuth.read() {
        case .ready(let login):
            secrets.codex = login
        case .expired:
            secrets.codexProblem = .expired
        case .missing:
            secrets.codexProblem = .notSignedIn
        }
        return secrets
    }
}

private enum TokenLookup {
    case ready(String)
    case expired
    case missing
    case needsPrompt
}

private enum CursorLogin {
    static func read(interactive: Bool) -> TokenLookup {
        let stored = sqliteText(
            database: cursorDatabaseURL(),
            query: "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
            key: "cursorAuth/accessToken"
        )
        if let stored {
            if stored.hasPrefix("cursor-safe-storage:v1:") {
                var prompted = false
                for account in ["Cursor", "Cursor Key"] {
                    switch keychainData(service: "Cursor Safe Storage", account: account, interactive: interactive) {
                    case .value(let password):
                        if let token = decryptCursor(stored, password: password) {
                            let classified = classify(token)
                            if case .ready = classified { return classified }
                        }
                    case .needsPrompt:
                        prompted = true
                    case .missing:
                        break
                    }
                }
                if case .ready(let token) = fallbackCursorToken(interactive: interactive) {
                    return .ready(token)
                }
                if let cli = cliAccessToken() { return classify(cli) }
                return prompted ? .needsPrompt : .missing
            }
            return classify(stored)
        }
        if case .ready(let token) = fallbackCursorToken(interactive: interactive) {
            return .ready(token)
        }
        if let cli = cliAccessToken() { return classify(cli) }
        return fallbackCursorToken(interactive: interactive)
    }

    /// `cursor-agent` 把明文访问令牌放在 `~/.cursor/auth.json`。
    private static func cliAccessToken() -> String? {
        var roots = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor", isDirectory: true)]
        if let raw = ProcessInfo.processInfo.environment["CURSOR_CONFIG_DIR"], !raw.isEmpty {
            let expanded = NSString(string: raw).expandingTildeInPath
            if expanded.hasPrefix("/") {
                roots.insert(URL(fileURLWithPath: expanded, isDirectory: true), at: 0)
            }
        }
        for root in roots {
            let file = root.appendingPathComponent("auth.json")
            guard let data = try? Data(contentsOf: file), data.count < 1_000_000,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["accessToken"] as? String, token.count > 20 else { continue }
            return token
        }
        return nil
    }

    private static func fallbackCursorToken(interactive: Bool) -> TokenLookup {
        switch keychainData(service: "cursor-access-token", account: "cursor-user", interactive: interactive) {
        case .value(let data):
            guard let text = cleanToken(data) else { return .missing }
            return classify(text)
        case .needsPrompt:
            return .needsPrompt
        case .missing:
            return .missing
        }
    }

    private static func cursorDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }
}

private enum ClaudeLogin {
    static func read(interactive: Bool) -> TokenLookup {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), data.count < 1_000_000, let found = claudeToken(data) {
            return classify(found.token, expiry: found.expiry)
        }
        switch keychainData(service: "Claude Code-credentials", account: nil, interactive: interactive) {
        case .value(let data):
            guard let found = claudeToken(data) else { return .missing }
            return classify(found.token, expiry: found.expiry)
        case .needsPrompt:
            return .needsPrompt
        case .missing:
            return .missing
        }
    }
}

private struct GrokLogin: Sendable {
    var token: String
    var userID: String?
}

private enum GrokAuth {
    static func read() -> GrokLogin? {
        let root: URL = {
            if let raw = ProcessInfo.processInfo.environment["GROK_HOME"], !raw.isEmpty {
                let expanded = NSString(string: raw).expandingTildeInPath
                if expanded.hasPrefix("/") {
                    return URL(fileURLWithPath: expanded, isDirectory: true)
                }
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
        }()
        let file = root.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: file), data.count < 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let bodies = json.sorted { lhs, rhs in
            lhs.key.hasPrefix("https://auth.x.ai") && !rhs.key.hasPrefix("https://auth.x.ai")
        }.compactMap { $0.value as? [String: Any] }
        for body in bodies {
            guard let token = body["key"] as? String, token.count > 20, !token.contains(where: \.isWhitespace) else { continue }
            if let expiry = isoDate(body["expires_at"]), expiry.timeIntervalSinceNow < 60 { continue }
            let user = (body["user_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let userID = user.flatMap { value -> String? in
                guard !value.isEmpty, value.count <= 80, !value.contains(where: \.isWhitespace) else { return nil }
                return value
            }
            return GrokLogin(token: token, userID: userID)
        }
        return nil
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

private struct GeminiStored: Sendable {
    var accessToken: String?
    var refreshToken: String
    var expired: Bool
}

private enum GeminiLogin {
    static func read() -> GeminiStored? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: file), data.count < 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refresh = json["refresh_token"] as? String,
              refresh.count > 20, !refresh.contains(where: \.isWhitespace) else { return nil }
        let access = json["access_token"] as? String
        let expiry = (json["expiry_date"] as? NSNumber)?.doubleValue
        let expired = expiry.map { Date(timeIntervalSince1970: $0 / 1000).timeIntervalSinceNow < 60 } ?? true
        let usable = access.flatMap { token -> String? in
            guard token.count > 20, !token.contains(where: \.isWhitespace) else { return nil }
            return token
        }
        return GeminiStored(accessToken: usable, refreshToken: refresh, expired: expired || usable == nil)
    }

    static func refresh(_ refreshToken: String) async -> String? {
        guard let client = GeminiOAuthClient.load() else { return nil }
        var fields = URLComponents()
        fields.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "client_secret", value: client.secret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        guard let body = fields.percentEncodedQuery?.data(using: .utf8) else { return nil }
        guard let json = await post(
            url: URL(string: "https://oauth2.googleapis.com/token")!,
            body: body,
            contentType: "application/x-www-form-urlencoded",
            bearer: nil
        ), let token = json["access_token"] as? String,
              token.count > 20, !token.contains(where: \.isWhitespace) else { return nil }
        return token
    }

    static func projectID(accessToken: String) async -> String? {
        let payload: [String: Any] = [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI"
            ]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let json = await post(
                url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!,
                body: body,
                contentType: "application/json",
                bearer: accessToken
              ) else { return nil }
        guard let project = json["cloudaicompanionProject"] as? String else { return nil }
        let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120, !trimmed.contains(where: \.isWhitespace),
              !trimmed.contains("\""), !trimmed.contains("\\") else { return nil }
        return trimmed
    }

    private static func post(url: URL, body: Data, contentType: String, bearer: String?) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.count < 1_000_000,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json
        } catch {
            return nil
        }
    }
}

private enum GeminiOAuthClient {
    private static let cached: (id: String, secret: String)? = discover()

    static func load() -> (id: String, secret: String)? { cached }

    private static func discover() -> (id: String, secret: String)? {
        guard let directory = bundleDirectory() else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "js" {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            guard (values?.fileSize ?? 0) < 30_000_000,
                  let text = try? String(contentsOf: file, encoding: .utf8),
                  let id = first(in: text, pattern: #"OAUTH_CLIENT_ID\s*=\s*"([^"]+)""#),
                  let secret = first(in: text, pattern: #"OAUTH_CLIENT_SECRET\s*=\s*"([^"]+)""#),
                  id.contains("apps.googleusercontent.com"), id.count < 200,
                  secret.count >= 20, secret.count <= 80, !secret.contains(where: \.isWhitespace) else { continue }
            return (id, secret)
        }
        return nil
    }

    private static func bundleDirectory() -> URL? {
        var paths = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/gemini").path
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                paths.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("gemini").path)
            }
        }
        for path in paths {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            for _ in 0..<8 {
                let bundle = url.appendingPathComponent("bundle", isDirectory: true)
                if FileManager.default.fileExists(atPath: bundle.path) { return bundle }
                let parent = url.deletingLastPathComponent()
                if parent.path == url.path { break }
                url = parent
            }
        }
        return nil
    }

    private static func first(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[found])
    }
}

private enum MuseCLI {
    static func executable() -> URL? {
        var paths = [
            "/opt/homebrew/bin/muse",
            "/usr/local/bin/muse",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/muse").path
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                paths.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("muse").path)
            }
        }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let directory = resolved.deletingLastPathComponent()
        let versionFile = directory.appendingPathComponent(".muse-version")
        if let version = try? String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           version.range(of: #"^\d+\.\d+\.\d+-R\d+"#, options: .regularExpression) != nil {
            let versioned = directory.appendingPathComponent("muse-bin-\(version)")
            if FileManager.default.isExecutableFile(atPath: versioned.path) { return versioned }
        }
        return resolved
    }

    static func usage(_ executable: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["usage", "--json"]
            var environment = ProcessInfo.processInfo.environment
            environment["MUSE_NO_AUTO_UPDATE"] = "1"
            environment["MUSE_LOGIN"] = "0"
            environment["MUSE_LAUNCHER_INSTALL"] = "0"
            process.environment = environment
            process.standardOutput = output
            process.standardError = Pipe()
            let lock = NSLock()
            var finished = false
            func finish(_ data: Data?) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(returning: data)
            }
            process.terminationHandler = { _ in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                finish(data.count > 2 && data.count < 65_536 ? data : nil)
            }
            do {
                try process.run()
            } catch {
                finish(nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

private enum CodexAuth {
    static func read() -> CodexRead {
        let root = codexHome()
        let file = root.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: file), data.count < 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .missing
        }
        let tokens = json["tokens"] as? [String: Any]
        let token = (tokens?["access_token"] as? String) ?? (json["access_token"] as? String)
        guard let token, token.count > 20 else { return .missing }
        if let expiry = jwtExpiry(token), expiry.timeIntervalSinceNow < 60 {
            return .expired
        }
        let account = (tokens?["account_id"] as? String) ?? (json["account_id"] as? String)
        let accountID = account.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= 80, !trimmed.contains(where: \.isWhitespace) else { return nil }
            return trimmed
        }
        return .ready(CodexLogin(token: token, accountID: accountID, usageURL: usageURL(in: root)))
    }

    enum CodexRead {
        case ready(CodexLogin)
        case expired
        case missing
    }

    private static func codexHome() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let raw = ProcessInfo.processInfo.environment["CODEX_HOME"], !raw.isEmpty {
            let expanded = NSString(string: raw).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    private static func usageURL(in root: URL) -> URL {
        let fallback = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let config = root.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return fallback }
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            guard raw.hasPrefix("chatgpt_base_url") else { continue }
            let parts = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            var value = parts[1]
            if let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard let base = URL(string: value), base.scheme == "https", base.host != nil else { continue }
            return base
                .appendingPathComponent("backend-api")
                .appendingPathComponent("wham")
                .appendingPathComponent("usage")
        }
        return fallback
    }
}

// MARK: - Keychain, sqlite, decrypt

private enum KeychainValue {
    case value(Data)
    case missing
    case needsPrompt
}

private func keychainData(service: String, account: String?, interactive: Bool) -> KeychainValue {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    // 定时刷新不弹框。旧钥匙串项会忽略 Skip，必须把进程的交互开关也关掉。
    var previousInteraction = DarwinBoolean(true)
    if !interactive {
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        _ = SecKeychainGetUserInteractionAllowed(&previousInteraction)
        SecKeychainSetUserInteractionAllowed(false)
    }
    defer {
        if !interactive {
            SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue)
        }
    }
    if let account {
        query[kSecAttrAccount as String] = account
    }
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
        guard let data = result as? Data, !data.isEmpty else { return .missing }
        return .value(data)
    case errSecItemNotFound:
        return .missing
    case errSecInteractionNotAllowed, errSecUserCanceled, errSecAuthFailed:
        return .needsPrompt
    default:
        return interactive ? .missing : .needsPrompt
    }
}

private func sqliteText(database: URL, query: String, key: String) -> String? {
    guard FileManager.default.fileExists(atPath: database.path) else { return nil }
    var db: OpaquePointer?
    guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        return nil
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
        return nil
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    if let cString = sqlite3_column_text(statement, 0) {
        return cleanStored(String(cString: cString))
    }
    let count = Int(sqlite3_column_bytes(statement, 0))
    guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
    let data = Data(bytes: bytes, count: count)
    return cleanStored(String(decoding: data, as: UTF8.self))
}

private func cleanStored(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
        text = String(text.dropFirst().dropLast())
    }
    return text.isEmpty ? nil : text
}

private func cleanToken(_ data: Data) -> String? {
    var bytes = data
    if bytes.last == 0 { bytes.removeLast() }
    guard let text = String(data: bytes, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    guard trimmed.count >= 20, trimmed.count < 8_000, !trimmed.contains(where: \.isWhitespace) else { return nil }
    return trimmed
}

private func classify(_ token: String, expiry: Date? = nil) -> TokenLookup {
    let token = sessionToken(token)
    let known = expiry ?? jwtExpiry(token)
    if let known, known.timeIntervalSinceNow < 60 { return .expired }
    return .ready(token)
}

/// Cursor 网页用量接口认的是会话 Cookie，不是 Authorization。
private func cursorCookie(_ token: String) -> String? {
    let jwt = sessionToken(token)
    guard let subject = jwtSubject(jwt) else { return nil }
    let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
    return "WorkosCursorSessionToken=\(encoded)%3A%3A\(jwt)"
}

/// Cursor 有时把用户 id 和 JWT 拼成 `user::jwt`。用量接口要后面的 JWT。
private func sessionToken(_ token: String) -> String {
    guard let marker = token.range(of: "::") else { return token }
    let rest = String(token[marker.upperBound...])
    guard rest.split(separator: ".").count == 3 else { return token }
    return rest
}

private func jwtSubject(_ token: String) -> String? {
    guard let json = jwtPayload(token), let subject = json["sub"] as? String else { return nil }
    let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 128, !trimmed.contains(where: \.isWhitespace) else { return nil }
    return trimmed
}

private func jwtExpiry(_ token: String) -> Date? {
    guard let json = jwtPayload(token) else { return nil }
    let exp = (json["exp"] as? NSNumber).map(\.doubleValue)
    guard let exp, exp > 1_000_000_000 else { return nil }
    return Date(timeIntervalSince1970: exp)
}

private func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder != 0 { payload += String(repeating: "=", count: 4 - remainder) }
    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json
}

private func claudeToken(_ data: Data) -> (token: String, expiry: Date?)? {
    var bytes = data
    if bytes.last == 0 { bytes.removeLast() }
    guard let json = try? JSONSerialization.jsonObject(with: bytes) else { return nil }
    return findClaudeToken(json, depth: 0)
}

private func findClaudeToken(_ value: Any, depth: Int) -> (token: String, expiry: Date?)? {
    guard depth < 5, let dict = value as? [String: Any] else { return nil }
    if let nested = dict["claudeAiOauth"] {
        return findClaudeToken(nested, depth: depth + 1)
    }
    let token = (dict["accessToken"] as? String) ?? (dict["access_token"] as? String)
    if let token, token.count > 20 {
        return (token, claudeExpiry(dict["expiresAt"] ?? dict["expires_at"]))
    }
    for child in dict.values {
        if let found = findClaudeToken(child, depth: depth + 1) { return found }
    }
    return nil
}

private func claudeExpiry(_ value: Any?) -> Date? {
    guard let number = (value as? NSNumber)?.doubleValue else { return nil }
    let seconds = number > 1_000_000_000_000 ? number / 1000 : number
    guard seconds > 1_000_000_000 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

private func decryptCursor(_ stored: String, password: Data) -> String? {
    let marker = "cursor-safe-storage:v1:"
    guard stored.hasPrefix(marker) else { return nil }
    var encoded = String(stored.dropFirst(marker.count))
    let remainder = encoded.count % 4
    if remainder != 0 { encoded += String(repeating: "=", count: 4 - remainder) }
    guard let raw = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), raw.count > 16 else {
        return nil
    }
    let payload = raw.starts(with: Data("v10".utf8)) ? raw.dropFirst(3) : raw[...]
    var secret = password
    while let last = secret.last, last == 0 || last == 10 || last == 13 {
        secret.removeLast()
    }
    guard let key = pbkdfSHA1(password: secret),
          let plain = aes128CBCDecrypt(data: Data(payload), key: key) else { return nil }
    return cleanToken(plain)
}

private func pbkdfSHA1(password: Data) -> Data? {
    let salt = Data("saltysalt".utf8)
    let passwordCount = password.count
    let saltCount = salt.count
    var key = Data(count: 16)
    let status: CCStatus = key.withUnsafeMutableBytes { keyBytes in
        password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress,
                    passwordCount,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    saltCount,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    keyBytes.bindMemory(to: UInt8.self).baseAddress,
                    16
                )
            }
        }
    }
    return status == kCCSuccess ? key : nil
}

private func aes128CBCDecrypt(data: Data, key: Data) -> Data? {
    guard !data.isEmpty else { return nil }
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    let keyCount = key.count
    let inputCount = data.count
    var output = Data(count: data.count + kCCBlockSizeAES128)
    let outputCount = output.count
    var written = 0
    let status: CCStatus = output.withUnsafeMutableBytes { outputBytes in
        data.withUnsafeBytes { dataBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, keyCount,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, inputCount,
                        outputBytes.baseAddress, outputCount,
                        &written
                    )
                }
            }
        }
    }
    guard status == kCCSuccess, written > 0 else { return nil }
    return output.prefix(written)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
