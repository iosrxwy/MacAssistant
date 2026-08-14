import Foundation

public enum DebDependencyConfidence: String, Codable, Hashable, Sendable {
    case candidate
    case unresolved
}

public struct DebDependencySuggestion: Identifiable, Codable, Hashable, Sendable {
    public var id: String { installName }
    public let installName: String
    public let suggestedPackageID: String?
    public let confidence: DebDependencyConfidence
    public let reason: String
}

public enum DebDependencyAdvisor {
    /// Mach-O install name 只能产生候选；不会自动写入 control。
    public static func suggestions(for dylibs: [URL]) throws -> [DebDependencySuggestion] {
        var paths = Set<String>()
        for dylib in dylibs {
            let analysis = try DylibService.analyze(fileAt: dylib)
            paths.formUnion(analysis.dependencies.map(\.path))
        }
        return paths.sorted().compactMap { path in
            guard !isAppleSystemPath(path) else { return nil }
            let lower = path.lowercased()
            if lower.contains("cydiasubstrate.framework")
                || lower.contains("mobilesubstrate") {
                return DebDependencySuggestion(
                    installName: path,
                    suggestedPackageID: "mobilesubstrate",
                    confidence: .candidate,
                    reason: L("deb.dependency.reason.substrate")
                )
            }
            if lower.contains("ellekit") {
                return DebDependencySuggestion(
                    installName: path,
                    suggestedPackageID: "ellekit",
                    confidence: .candidate,
                    reason: L("deb.dependency.reason.elleKit")
                )
            }
            return DebDependencySuggestion(
                installName: path,
                suggestedPackageID: nil,
                confidence: .unresolved,
                reason: L("deb.dependency.reason.unresolved")
            )
        }
    }

    /// 仅返回用户显式确认的 package ID，调用方再合并到 Depends。
    public static func confirmedPackageIDs(
        from suggestions: [DebDependencySuggestion],
        confirmedInstallNames: Set<String>
    ) -> [String] {
        Array(Set(suggestions.compactMap {
            guard confirmedInstallNames.contains($0.installName) else { return nil }
            return $0.suggestedPackageID
        })).sorted()
    }

    private static func isAppleSystemPath(_ path: String) -> Bool {
        if path.hasPrefix("/System/Library/") { return true }
        if path.hasPrefix("/usr/lib/") {
            let lower = path.lowercased()
            return !["substrate", "substitute", "hooker", "ellekit", "cephei", "rocketbootstrap"]
                .contains(where: { lower.contains($0) })
        }
        return false
    }
}
