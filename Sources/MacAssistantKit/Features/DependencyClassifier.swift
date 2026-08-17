import Foundation

/// 一条依赖的归类结论。
///
/// 五态刻意区分「能在本机确认」与「只能在设备确认」与「无法判定」，
/// 因为把这三者混成一个「缺失/满足」布尔值，正是本项目要修的伪报来源。
public enum DependencyClassification: String, Codable, Hashable, Sendable {
    /// iOS 自带系统库,设备上一定存在。
    case systemLibrary
    /// 能在 App/IPA 内找到的内嵌库。
    case appEmbedded
    /// 越狱环境提供,本机无法验证其存在与版本。
    case deviceProvided
    /// 用户这次一起提供了的插件自带库。
    case pluginProvided
    /// 依据不足,拒绝猜测。
    case unknown
}

/// 分类所需的上下文:本机能观察到什么。名字统一小写比较,避免大小写漂移。
public struct DependencyClassificationContext: Sendable, Hashable {
    public let appEmbeddedNames: Set<String>
    public let pluginProvidedNames: Set<String>

    public init(appEmbeddedNames: Set<String> = [], pluginProvidedNames: Set<String> = []) {
        self.appEmbeddedNames = Set(appEmbeddedNames.map { $0.lowercased() })
        self.pluginProvidedNames = Set(pluginProvidedNames.map { $0.lowercased() })
    }
}

/// 单条依赖的分类结果。`evidence` 必须能被展示给用户,说明结论的依据。
public struct DependencyClassificationResult: Identifiable, Codable, Hashable, Sendable {
    public var id: String { installPath }
    public let installPath: String
    public let fileName: String
    public let classification: DependencyClassification
    public let evidence: String

    public init(
        installPath: String,
        fileName: String,
        classification: DependencyClassification,
        evidence: String
    ) {
        self.installPath = installPath
        self.fileName = fileName
        self.classification = classification
        self.evidence = evidence
    }

    /// 已验证可解析:系统库、App 内嵌、或用户本次提供。其余(设备提供 / 未知)都视为未解析。
    public var isResolvedLocally: Bool {
        switch classification {
        case .systemLibrary, .appEmbedded, .pluginProvided: return true
        case .deviceProvided, .unknown: return false
        }
    }
}

/// 依赖分类器:取代按文件名关键字硬猜的做法。
///
/// 关键原则:文件名只能作为「线索」,不能据此静默推断包名或伪装成已知库;
/// 依据不足时一律归入 `.unknown`。设备提供类同样是「本机无法验证」的诚实状态,
/// 不会被当成「已解决」。
public enum DependencyClassifier {

    /// 全项目唯一的越狱运行时组件关键字表。此前散落在 TweakInjectService / DebService /
    /// IpaInjectionWorkflow / DebDependencyAdvisor 四处、且互相不一致,现收敛到此。
    /// 命中只用于把 /usr/lib 下的歧义项标成「设备提供(无法验证)」,绝不据此编造包名。
    static let jailbreakRuntimeKeywords: [String] = [
        "substrate", "substitute", "hooker", "ellekit", "cephei",
        "colorpicker", "rocketbootstrap", "preferenceloader", "libhooker"
    ]

    /// 明确已知的 iOS 公共系统库(basename,小写)。列表之外的 /usr/lib 项不冒充系统库。
    private static let knownSystemLibraryNames: Set<String> = [
        "libobjc.a.dylib", "libc++.1.dylib", "libc++abi.dylib", "libsystem.b.dylib",
        "libsqlite3.dylib", "libsqlite3.0.dylib", "libz.1.dylib", "libcompression.dylib",
        "libiconv.2.dylib", "libnetwork.dylib", "libresolv.9.dylib", "libxml2.2.dylib",
        "libc.dylib", "libdyld.dylib", "libcache.dylib", "libcommoncrypto.dylib",
        "libmacho.dylib", "libcopyfile.dylib", "libremovefile.dylib", "libdispatch.dylib"
    ]

    /// 系统库常见前缀:libSwift* 运行时以及 System.B 等以 lib 开头的核心库族。
    private static let systemLibraryPrefixes: [String] = [
        "libswift", "libsystem", "libc++", "libobjc", "libdispatch", "libxpc"
    ]

    static func matchesJailbreakKeyword(_ name: String) -> Bool {
        let lower = name.lowercased()
        return jailbreakRuntimeKeywords.contains { lower.contains($0) }
    }

    static func isKnownSystemLibrary(_ name: String) -> Bool {
        let lower = name.lowercased()
        if knownSystemLibraryNames.contains(lower) { return true }
        return systemLibraryPrefixes.contains { lower.hasPrefix($0) }
    }

    public static func classify(
        paths: [String],
        context: DependencyClassificationContext
    ) -> [DependencyClassificationResult] {
        paths.map { classify(path: $0, context: context) }
    }

    public static func classify(
        path: String,
        context: DependencyClassificationContext
    ) -> DependencyClassificationResult {
        let name = (path as NSString).lastPathComponent
        let lowerName = name.lowercased()

        func result(_ classification: DependencyClassification, _ key: String) -> DependencyClassificationResult {
            DependencyClassificationResult(
                installPath: path,
                fileName: name,
                classification: classification,
                evidence: L(key, path)
            )
        }

        if context.pluginProvidedNames.contains(lowerName) {
            return result(.pluginProvided, "dep.class.plugin")
        }
        if context.appEmbeddedNames.contains(lowerName) {
            return result(.appEmbedded, "dep.class.appEmbedded")
        }
        // loader 相对路径若未在上面命中,本机无从判断其在设备上是否解析,如实归为未知。
        if path.hasPrefix("@") {
            return result(.unknown, "dep.class.loaderRelativeUnresolved")
        }
        if isJailbreakRootPath(path) {
            return result(.deviceProvided, "dep.class.deviceJailbreakPath")
        }
        if path.hasPrefix("/System/Library/") {
            return result(.systemLibrary, "dep.class.systemFramework")
        }
        if path.hasPrefix("/usr/lib/") {
            if isKnownSystemLibrary(name) {
                return result(.systemLibrary, "dep.class.systemLibrary")
            }
            if matchesJailbreakKeyword(name) {
                return result(.deviceProvided, "dep.class.deviceKeyword")
            }
            return result(.unknown, "dep.class.usrLibUnrecognized")
        }
        return result(.unknown, "dep.class.unknown")
    }

    /// 越狱根路径:rootless 的 /var/jb、roothide 的 .jbroot、以及设备上仅越狱环境才有的
    /// /Library(含 MobileSubstrate、Frameworks)。/System/Library 由调用处单独先行判定。
    private static func isJailbreakRootPath(_ path: String) -> Bool {
        if path.hasPrefix("/var/jb/") { return true }
        if path.contains("/.jbroot/") { return true }
        if path.contains("/MobileSubstrate/") { return true }
        if path.hasPrefix("/Library/") { return true }
        return false
    }
}
