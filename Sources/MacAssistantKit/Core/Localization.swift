import Foundation

/// 界面语言。`rawValue` 直接用作 `.lproj` 目录名，新增一门语言只需增加一个 case，
/// 并在两个 target 的 `Localization/<rawValue>.lproj/` 下各放一份 `Localizable.strings`。
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    /// 可实际取词条的语言，按「先具体后宽泛」排序，匹配时优先命中 zh-Hans 而不是假想的 zh。
    public static var translations: [AppLanguage] {
        allCases.filter { $0 != .system }.sorted { $0.rawValue.count > $1.rawValue.count }
    }

    /// 除「跟随系统」外一律用语言自身的写法，避免用户误切到看不懂的语言后找不回来。
    public var displayName: String {
        switch self {
        case .system: return MALocalizedString("language.system", bundle: .module)
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

public enum LocalizationSettings {
    public static let defaultsKey = "MacAssistantInterfaceLanguage"

    /// 测试需要一个确定的语言，否则断言会随宿主系统语言漂移。
    public static var override: AppLanguage?

    public static var current: AppLanguage {
        get {
            if let override { return override }
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let language = AppLanguage(rawValue: raw)
            else {
                return .system
            }
            return language
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

/// 开发语言：任何语言缺词条时回退到这里，而不是把 key 直接显示给用户。
private let developmentLanguage = AppLanguage.simplifiedChinese

/// 从指定 bundle 取本地化字符串。
///
/// SwiftUI 的 `Text("key")` 只查 `Bundle.main`，而 SwiftPM 把资源放在各 target 的
/// `Bundle.module` 里，所以全项目统一走这里显式指定 bundle。
public func MALocalizedString(
    _ key: String,
    arguments: [CVarArg] = [],
    bundle: Bundle
) -> String {
    let template = LocalizationEngine.shared.string(for: key, in: bundle)
    guard !arguments.isEmpty else { return template }
    return String(format: template, arguments: arguments)
}

private let missingMarker = "\u{0}MA_MISSING\u{0}"

private final class LocalizationEngine: @unchecked Sendable {
    static let shared = LocalizationEngine()

    private let lock = NSLock()
    private var bundles: [String: Bundle] = [:]

    func string(for key: String, in base: Bundle) -> String {
        let chain = [resolvedLanguage(), developmentLanguage]
        for language in chain {
            guard let table = lproj(language, in: base) else { continue }
            let value = table.localizedString(forKey: key, value: missingMarker, table: nil)
            if value != missingMarker { return value }
        }
        return key
    }

    private func resolvedLanguage() -> AppLanguage {
        let preference = LocalizationSettings.current
        guard preference == .system else { return preference }
        return Self.bestMatch(for: Locale.preferredLanguages) ?? developmentLanguage
    }

    /// 自己做语言匹配而不用 `Bundle.preferredLocalizations(from:)`：后者依赖主 bundle 的
    /// 本地化列表，裸 SwiftPM 可执行文件下会恒定返回 en。
    static func bestMatch(for preferences: [String]) -> AppLanguage? {
        for preference in preferences {
            let wanted = preference.lowercased()
            for language in AppLanguage.translations {
                let candidate = language.rawValue.lowercased()
                if wanted == candidate
                    || wanted.hasPrefix(candidate + "-")
                    || candidate.hasPrefix(wanted + "-") {
                    return language
                }
            }
        }
        return nil
    }

    private func lproj(_ language: AppLanguage, in base: Bundle) -> Bundle? {
        let key = "\(ObjectIdentifier(base).hashValue)|\(language.rawValue)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = bundles[key] { return cached }
        guard let url = Self.lprojURL(language.rawValue, in: base),
              let resolved = Bundle(url: url)
        else {
            return nil
        }
        bundles[key] = resolved
        return resolved
    }

    /// SwiftPM 会把 `zh-Hans.lproj` 写成 `zh-hans.lproj`，按名字精确查会落空，
    /// 因此退化成大小写不敏感的目录扫描。
    private static func lprojURL(_ language: String, in base: Bundle) -> URL? {
        if let path = base.path(forResource: language, ofType: "lproj") {
            return URL(fileURLWithPath: path)
        }
        guard let resources = base.resourceURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: resources,
                  includingPropertiesForKeys: nil
              )
        else {
            return nil
        }
        let wanted = "\(language).lproj".lowercased()
        return entries.first { $0.lastPathComponent.lowercased() == wanted }
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    MALocalizedString(key, arguments: arguments, bundle: .module)
}

func L(_ key: String, arguments: [CVarArg]) -> String {
    MALocalizedString(key, arguments: arguments, bundle: .module)
}
