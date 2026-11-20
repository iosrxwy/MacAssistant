import Foundation

/// 一个额度窗口。`usedFraction` 是已用比例，0 表示还没花，1 表示用尽。
public struct AIQuotaWindow: Identifiable, Hashable, Sendable {
    public var id: String
    /// 界面词条。模型名这类服务原文走 `title`。
    public var titleKey: String?
    public var title: String
    public var usedFraction: Double
    public var resetsAt: Date?

    public init(id: String, titleKey: String? = nil, title: String = "", usedFraction: Double, resetsAt: Date?) {
        self.id = id
        self.titleKey = titleKey
        self.title = title
        self.usedFraction = min(1, max(0, usedFraction))
        self.resetsAt = resetsAt
    }

    public var remainingFraction: Double { 1 - usedFraction }

    public var remainingPercent: Int {
        Int((remainingFraction * 100).rounded())
    }

    public var usedPercent: Int {
        Int((usedFraction * 100).rounded())
    }
}

public enum AIQuotaState: Equatable, Sendable {
    case loading
    case ready
    case notSignedIn
    case needsKeychain
    case expired
    case unavailable
    case failed
}

/// 已经存着、还没花掉的重置次数。只展示数量和到期时间，不在这里兑换。
public struct AIQuotaResets: Hashable, Sendable {
    public var availableCount: Int
    /// 还可用的那几张，按到期从近到远，最多 4 个。
    public var expiries: [Date]

    public init(availableCount: Int, expiries: [Date]) {
        self.availableCount = availableCount
        self.expiries = expiries
    }
}

public struct AIQuotaSnapshot: Identifiable, Equatable, Sendable {
    public var id: AIQuotaProviderID
    public var plan: String?
    public var windows: [AIQuotaWindow]
    public var note: String?
    public var state: AIQuotaState
    public var fetchedAt: Date?
    public var resets: AIQuotaResets?

    public init(
        id: AIQuotaProviderID,
        plan: String?,
        windows: [AIQuotaWindow],
        note: String?,
        state: AIQuotaState,
        fetchedAt: Date?,
        resets: AIQuotaResets? = nil
    ) {
        self.id = id
        self.plan = plan
        self.windows = windows
        self.note = note
        self.state = state
        self.fetchedAt = fetchedAt
        self.resets = resets
    }

    /// 图标和列表上的数字。有综合窗口时用它，避免某个子额度用尽把整条显示成 0。
    public var headline: AIQuotaWindow? {
        windows.first { $0.id == "primary" } ?? windows.min { $0.remainingFraction < $1.remainingFraction }
    }

    public static func placeholder(_ id: AIQuotaProviderID) -> AIQuotaSnapshot {
        AIQuotaSnapshot(id: id, plan: nil, windows: [], note: nil, state: .loading, fetchedAt: nil)
    }
}

public enum AIQuotaProviderID: String, CaseIterable, Identifiable, Sendable {
    case cursor
    case codex
    case gemini
    case claude
    case grok
    case grokBot
    case muse

    public var id: String { rawValue }

    public static let displayOrder: [AIQuotaProviderID] = [.cursor, .codex, .gemini, .grok, .claude, .grokBot, .muse]

    public var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .grokBot: return "Grok Bot"
        case .muse: return "Muse"
        }
    }

    /// 程序坞里用来对上图标的 bundle id。名字只在读不到包名时兜底。
    public var bundleIDs: [String] {
        switch self {
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        case .codex: return ["com.openai.codex"]
        case .gemini: return ["com.google.GeminiMacOS"]
        case .claude: return ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .grok: return []
        case .grokBot: return ["com.anysphere.sand"]
        case .muse: return []
        }
    }

    public var dockNames: [String] {
        switch self {
        case .cursor: return ["Cursor"]
        case .codex: return ["Codex"]
        case .gemini: return ["Gemini"]
        case .claude: return ["Claude"]
        case .grok: return ["Grok"]
        case .grokBot: return ["Grok Bot", "GrokBot"]
        case .muse: return ["Muse", "Muse Code"]
        }
    }

    /// 没有桌面应用时，用包内图标。
    public var artworkName: String? {
        switch self {
        case .grok: return "grok"
        case .muse: return "muse"
        case .grokBot: return "grokBot"
        default: return nil
        }
    }
}
