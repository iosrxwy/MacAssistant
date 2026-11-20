import Foundation

/// 把各家用量接口的 JSON 收成窗口。字段名按公开的用量响应，不保存原文。
public enum AIQuotaParsing {
    public static func codex(_ data: Data) -> (plan: String?, windows: [AIQuotaWindow])? {
        guard let json = object(data) else { return nil }
        let plan = shortToken(json["plan_type"])
        var windows: [AIQuotaWindow] = []
        if let rate = json["rate_limit"] as? [String: Any] {
            if let primary = rate["primary_window"] as? [String: Any],
               let window = codexWindow(primary, id: "primary") {
                windows.append(window)
            }
            if let secondary = rate["secondary_window"] as? [String: Any],
               let window = codexWindow(secondary, id: "secondary") {
                windows.append(window)
            }
        }
        if let extras = json["additional_rate_limits"] as? [[String: Any]] {
            for (index, extra) in extras.enumerated() {
                let source = (extra["primary_window"] as? [String: Any]) ?? extra
                let name = shortToken(extra["name"]) ?? shortToken(extra["model"]) ?? shortToken(extra["label"])
                if let window = codexWindow(source, id: "extra-\(index)", forcedTitle: name) {
                    windows.append(window)
                }
            }
        }
        return (plan, windows)
    }

    /// `/wham/usage` 里的 `rate_limit_reset_credits`。没有可用次数时返回 nil。
    public static func codexResets(inUsage data: Data) -> AIQuotaResets? {
        guard let json = object(data),
              let body = json["rate_limit_reset_credits"] as? [String: Any] else { return nil }
        return resets(from: body)
    }

    /// `/wham/rate-limit-reset-credits` 的明细。失败或没有可用次数时返回 nil。
    public static func codexResetCredits(_ data: Data) -> AIQuotaResets? {
        guard let json = object(data) else { return nil }
        return resets(from: json)
    }

    public static func claude(_ data: Data) -> (plan: String?, windows: [AIQuotaWindow])? {
        guard let json = object(data) else { return nil }
        let plan = shortToken(json["subscription_type"])
            ?? shortToken(json["subscriptionType"])
            ?? shortToken(json["rate_limit_tier"])
        var windows: [AIQuotaWindow] = []
        func append(_ key: String, id: String, titleKey: String) {
            guard let body = json[key] as? [String: Any],
                  let used = officialPercent(body["utilization"]) else { return }
            windows.append(AIQuotaWindow(
                id: id,
                titleKey: titleKey,
                usedFraction: used,
                resetsAt: date(body["resets_at"])
            ))
        }
        append("five_hour", id: "session", titleKey: "aiquota.window.session")
        if json["seven_day"] != nil {
            append("seven_day", id: "weekly", titleKey: "aiquota.window.weekly")
        } else {
            append("seven_day_oauth_apps", id: "weekly", titleKey: "aiquota.window.weekly")
        }
        append("seven_day_sonnet", id: "sonnet", titleKey: "aiquota.window.sonnet")
        append("seven_day_opus", id: "opus", titleKey: "aiquota.window.opus")
        return (plan.map(displayPlan), windows)
    }

    public static func cursorSummary(_ data: Data) -> (plan: String?, note: String?, windows: [AIQuotaWindow])? {
        guard let json = object(data) else { return nil }
        let plan = shortToken(json["membershipType"]) ?? shortToken(json["individualMembershipType"])
        let reset = date(json["billingCycleEnd"])
        let note = publicNote(json["autoModelSelectedDisplayMessage"])
            ?? publicNote(json["namedModelSelectedDisplayMessage"])
        let planBody = dig(json, "individualUsage", "plan") ?? (json["planUsage"] as? [String: Any])
        var windows = planBody.map { cursorPools($0, reset: reset) } ?? []
        if windows.isEmpty, json["isUnlimited"] as? Bool == true {
            windows.append(AIQuotaWindow(
                id: "primary",
                titleKey: "aiquota.window.primary",
                usedFraction: 0,
                resetsAt: reset
            ))
        }
        return (plan.map(displayPlan), note, windows)
    }

    /// 设置页的两条额度：`autoPercentUsed` 是 Cursor 模型，`apiPercentUsed` 是其他模型。
    /// 这两个字段固定是 0...100，1 表示 1%，0.37 表示 0.37%。
    /// `totalPercentUsed` 是加权混合，`used/limit` 是旧的金额比，都不能当成那两条。
    private static func cursorPools(_ planBody: [String: Any], reset: Date?) -> [AIQuotaWindow] {
        let auto = officialPercent(planBody["autoPercentUsed"])
        let api = officialPercent(planBody["apiPercentUsed"])
        if auto != nil || api != nil {
            var windows: [AIQuotaWindow] = []
            if let auto {
                windows.append(AIQuotaWindow(
                    id: "primary",
                    titleKey: "aiquota.window.cursorModels",
                    usedFraction: auto,
                    resetsAt: reset
                ))
            }
            if let api {
                windows.append(AIQuotaWindow(
                    id: auto == nil ? "primary" : "api",
                    titleKey: "aiquota.window.otherModels",
                    usedFraction: api,
                    resetsAt: reset
                ))
            }
            return windows
        }
        let fromCounts: Double? = {
            guard let used = number(planBody["used"]), let limit = number(planBody["limit"]), limit > 0 else {
                return nil
            }
            return min(1, max(0, used / limit))
        }()
        guard let used = officialPercent(planBody["totalPercentUsed"]) ?? fromCounts else { return [] }
        return [AIQuotaWindow(
            id: "primary",
            titleKey: "aiquota.window.primary",
            usedFraction: used,
            resetsAt: reset
        )]
    }

    public static func grokBilling(_ data: Data) -> [AIQuotaWindow]? {
        guard let json = object(data) else { return nil }
        let config = (json["config"] as? [String: Any]) ?? json
        let period = config["currentPeriod"] as? [String: Any]
        let reset = date(period?["end"]) ?? date(config["billingPeriodEnd"])
        let weekly = (period?["type"] as? String)?.localizedCaseInsensitiveContains("WEEKLY") == true
        guard let used = officialPercent(config["creditUsagePercent"]) else { return nil }
        var windows = [
            AIQuotaWindow(
                id: "primary",
                titleKey: weekly ? "aiquota.window.weekly" : "aiquota.window.monthly",
                usedFraction: used,
                resetsAt: reset
            )
        ]
        if let products = config["productUsage"] as? [[String: Any]] {
            for (index, item) in products.prefix(4).enumerated() {
                guard let productUsed = officialPercent(item["usagePercent"]),
                      let name = shortToken(item["product"]) else { continue }
                windows.append(AIQuotaWindow(
                    id: "product-\(index)",
                    title: spacedName(name),
                    usedFraction: productUsed,
                    resetsAt: reset
                ))
            }
        }
        return windows
    }

    public static func gemini(_ data: Data) -> [AIQuotaWindow]? {
        guard let json = object(data) else { return nil }
        let buckets = (json["buckets"] as? [[String: Any]]) ?? []
        var windows: [AIQuotaWindow] = []
        for (index, bucket) in buckets.prefix(6).enumerated() {
            guard let remaining = fraction(bucket["remainingFraction"]),
                  let title = geminiName(bucket["modelId"]) else { continue }
            windows.append(AIQuotaWindow(
                id: index == 0 ? "pending-\(index)" : "model-\(index)",
                title: title,
                usedFraction: 1 - remaining,
                resetsAt: date(bucket["resetTime"])
            ))
        }
        guard let tightest = windows.min(by: { $0.remainingFraction < $1.remainingFraction }) else { return nil }
        var ordered = [AIQuotaWindow(
            id: "primary",
            title: tightest.title,
            usedFraction: tightest.usedFraction,
            resetsAt: tightest.resetsAt
        )]
        for window in windows where window.title != tightest.title || window.resetsAt != tightest.resetsAt {
            guard ordered.count < 4 else { break }
            ordered.append(window)
        }
        return ordered
    }

    public static func muse(_ data: Data) -> (plan: String?, windows: [AIQuotaWindow])? {
        guard let json = object(data), json["schemaVersion"] as? Int == 1 else { return nil }
        if json["allowance"] is NSNull { return nil }
        guard let allowance = json["allowance"] as? [String: Any] else { return nil }
        var windows: [AIQuotaWindow] = []
        if let body = allowance["window"] as? [String: Any], let used = officialPercent(body["usedPercent"]) {
            windows.append(AIQuotaWindow(
                id: "session",
                titleKey: "aiquota.window.session",
                usedFraction: used,
                resetsAt: date(body["resetsAtMs"])
            ))
        }
        if let body = allowance["weekly"] as? [String: Any], let used = officialPercent(body["usedPercent"]) {
            windows.append(AIQuotaWindow(
                id: "weekly",
                titleKey: "aiquota.window.weekly",
                usedFraction: used,
                resetsAt: date(body["resetsAtMs"])
            ))
        }
        guard let tightest = windows.min(by: { $0.remainingFraction < $1.remainingFraction }) else { return nil }
        var ordered = [AIQuotaWindow(
            id: "primary",
            titleKey: tightest.titleKey,
            title: tightest.title,
            usedFraction: tightest.usedFraction,
            resetsAt: tightest.resetsAt
        )]
        if let other = windows.first(where: { abs($0.usedFraction - tightest.usedFraction) > 0.02 || $0.resetsAt != tightest.resetsAt }) {
            ordered.append(other)
        }
        return (shortToken(allowance["tier"]), ordered)
    }

    public static func grokBot(_ data: Data) -> (plan: String?, note: String?, windows: [AIQuotaWindow])? {
        guard let json = object(data) else { return nil }
        guard let found = grokPercent(json, depth: 0) else { return nil }
        let window = AIQuotaWindow(
            id: "primary",
            titleKey: "aiquota.window.primary",
            usedFraction: found.used,
            resetsAt: found.reset
        )
        return (publicNote(json["grokPlanLabel"]), nil, [window])
    }

    // MARK: - Codex window

    private static func codexWindow(
        _ body: [String: Any],
        id: String,
        forcedTitle: String? = nil
    ) -> AIQuotaWindow? {
        guard let used = officialPercent(body["used_percent"]) else { return nil }
        let seconds = number(body["limit_window_seconds"])
        let titleKey = forcedTitle == nil ? windowKey(seconds: seconds) : nil
        return AIQuotaWindow(
            id: id,
            titleKey: titleKey,
            title: forcedTitle ?? "",
            usedFraction: used,
            resetsAt: date(body["reset_at"])
        )
    }

    private static func resets(from body: [String: Any]) -> AIQuotaResets? {
        let listed = expiries(body["credits"])
        let count = wholeCount(body["available_count"] ?? body["availableCount"]) ?? (listed.isEmpty ? nil : listed.count)
        guard let count, count > 0 else { return nil }
        return AIQuotaResets(availableCount: count, expiries: listed)
    }

    /// 只留下状态为可用、并且能解析出到期时间的条目。服务原文标题不进界面。
    private static func expiries(_ value: Any?) -> [Date] {
        guard let rows = value as? [[String: Any]] else { return [] }
        var dates: [Date] = []
        for row in rows.prefix(12) {
            if let status = row["status"] as? String {
                let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !normalized.isEmpty, normalized != "available" { continue }
            }
            guard let expiry = date(row["expires_at"] ?? row["expiresAt"]) else { continue }
            dates.append(expiry)
        }
        return Array(dates.sorted().prefix(4))
    }

    private static func wholeCount(_ value: Any?) -> Int? {
        guard let number = number(value), number >= 1, number <= 99, number.rounded() == number else { return nil }
        return Int(number)
    }

    private static func windowKey(seconds: Double?) -> String {
        guard let seconds else { return "aiquota.window.primary" }
        if seconds <= 6 * 60 * 60 { return "aiquota.window.session" }
        if seconds <= 8 * 24 * 60 * 60 { return "aiquota.window.weekly" }
        return "aiquota.window.monthly"
    }

    // MARK: - Numbers and dates

    /// Claude / Codex 的百分比字段是 0...100，0.5 表示百分之 0.5。
    private static func officialPercent(_ value: Any?) -> Double? {
        guard let number = number(value) else { return nil }
        return min(1, max(0, number / 100))
    }

    /// Cursor 有的接口用 0...1，有的用 0...100。
    private static func cursorRatio(_ value: Any?) -> Double? {
        guard let number = number(value) else { return nil }
        if number > 1 { return min(1, number / 100) }
        return min(1, max(0, number))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        // JSON 的 true/false 也是 NSNumber，不能当成用量。
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = number(value) {
            let seconds = number > 1_000_000_000_000 ? number / 1000 : number
            guard seconds > 1_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        if let number = Double(text), number > 1_000_000_000 {
            let seconds = number > 1_000_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        guard data.count < 2_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func dig(_ json: [String: Any], _ a: String, _ b: String) -> [String: Any]? {
        (json[a] as? [String: Any])?[b] as? [String: Any]
    }

    private static func grokPercent(_ value: Any, depth: Int) -> (used: Double, reset: Date?)? {
        guard depth < 4, let dict = value as? [String: Any] else { return nil }
        if let used = cursorRatio(dict["usagePercent"] ?? dict["usedPercent"] ?? dict["percentUsed"]) {
            let reset = date(dict["nextResetTimestampUtc"] ?? dict["resetAt"] ?? dict["resetsAt"] ?? dict["reset_at"])
            return (used, reset)
        }
        for key in ["usage", "quota", "data", "result", "sand"] {
            if let nested = dict[key], let found = grokPercent(nested, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func shortToken(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32, !trimmed.contains("@"), !trimmed.contains(" "),
              !trimmed.contains("\n"), !trimmed.contains("sk-") else { return nil }
        return trimmed
    }

    private static func publicNote(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 140, !trimmed.contains("@"), !trimmed.contains("\n"),
              !trimmed.contains("sk-"), !trimmed.contains("eyJ") else { return nil }
        return trimmed
    }

    private static func fraction(_ value: Any?) -> Double? {
        guard let number = number(value) else { return nil }
        return min(1, max(0, number))
    }

    private static func geminiName(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48, !trimmed.contains("@"), !trimmed.contains(" "),
              !trimmed.contains("sk-"), !trimmed.contains("eyJ") else { return nil }
        let known = [
            "gemini-2.5-pro": "Pro",
            "gemini-2.5-flash": "Flash",
            "gemini-2.5-flash-lite": "Flash Lite",
            "gemini-3.0-pro": "3.0 Pro",
            "gemini-3.0-flash": "3.0 Flash",
            "gemini-3.1-pro": "3.1 Pro",
            "gemini-3.1-flash": "3.1 Flash",
            "gemini-3.1-flash-lite": "3.1 Flash Lite"
        ]
        if let name = known[trimmed] { return name }
        var name = trimmed
        if name.lowercased().hasPrefix("gemini-") {
            name = String(name.dropFirst("gemini-".count))
        }
        let words = name.split(separator: "-").map { part in
            guard let first = part.first else { return "" }
            return first.uppercased() + part.dropFirst()
        }
        let title = words.joined(separator: " ")
        return title.isEmpty ? nil : title
    }

    private static func spacedName(_ raw: String) -> String {
        var result = ""
        for character in raw {
            if character.isUppercase, let last = result.last, last.isLowercase || last.isNumber {
                result.append(" ")
            }
            result.append(character)
        }
        return result
    }

    private static func displayPlan(_ raw: String) -> String {
        let lower = raw.lowercased()
        switch lower {
        case "free": return "Free"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "max": return "Max"
        case "ultra": return "Ultra"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        default:
            if lower.contains("max_20") || lower.contains("20x") { return "Max 20x" }
            if lower.contains("max_5") || lower.contains("5x") { return "Max 5x" }
            if lower.contains("max") { return "Max" }
            if lower.contains("pro") { return "Pro" }
            return raw
        }
    }
}
