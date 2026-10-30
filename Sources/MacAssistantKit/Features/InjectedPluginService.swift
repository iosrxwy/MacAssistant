#if canImport(AppKit)
import AppKit
#endif
import Foundation

/// 一条已写入宿主 Mach-O 的第三方 `LC_LOAD_*`。
public struct InjectedPluginFinding: Identifiable, Hashable, Sendable {
    public var id: String { "\(hostRelativePath)|\(loadPath)" }
    public let loadPath: String
    public let displayName: String
    public let hostURL: URL
    public let hostRelativePath: String
    public let weak: Bool
    public let payloadURL: URL?
    public let payloadRelativePath: String?
}

public struct InjectedPluginRemovalOptions: Sendable {
    public var deletePayload: Bool
    public var resign: Bool

    public init(deletePayload: Bool = true, resign: Bool = true) {
        self.deletePayload = deletePayload
        self.resign = resign
    }
}

public struct InjectedPluginRemovalReport: Sendable {
    public var messages: [String] = []
    public var removedLoadPaths: [String] = []
    public var deletedPayloads: [String] = []
    public var warnings: [String] = []

    public var log: String {
        (messages + warnings).joined(separator: "\n")
    }
}

public enum InjectedPluginError: LocalizedError {
    case notApp
    case systemLibrary(String)
    case bundledLibrary(String)

    public var errorDescription: String? {
        switch self {
        case .notApp:
            return L("injectscan.error.notApp")
        case let .systemLibrary(path):
            return L("injectscan.error.systemLibrary", path)
        case let .bundledLibrary(path):
            return L("injectscan.error.bundledLibrary", path)
        }
    }
}

enum InjectedLibraryKind: String, Sendable {
    case system
    case bundled
    case thirdParty
}

/// 扫描本机 .app 里非系统的注入项，并就地卸掉 `LC_LOAD_*`。
///
/// 不走 IPA 那套 `AppBundleMachOScanner`：macOS 包在 `Contents/` 下，
/// 微信的业务库还在 `Contents/Resources/wechat.dylib`。
public enum InjectedPluginService {

    public static func scan(app: URL) throws -> [InjectedPluginFinding] {
        try validateApp(app)
        var findings: [InjectedPluginFinding] = []
        var seen = Set<String>()
        for host in hostMachOFiles(in: app) {
            let inspections = (try? DylibInjector.inspectLoadCommands(fileAt: host)) ?? []
            for command in uniqueCommands(inspections) {
                guard classification(of: command.path, app: app) == .thirdParty else { continue }
                let hostRelative = relativePath(host, under: app)
                let key = "\(hostRelative)|\(command.path)"
                guard seen.insert(key).inserted else { continue }
                let payload = payloadRoot(
                    for: resolveLoadPath(command.path, host: host, app: app),
                    app: app
                )
                findings.append(
                    InjectedPluginFinding(
                        loadPath: command.path,
                        displayName: displayName(for: command.path),
                        hostURL: host,
                        hostRelativePath: hostRelative,
                        weak: command.weak,
                        payloadURL: payload,
                        payloadRelativePath: payload.map { relativePath($0, under: app) }
                    )
                )
            }
        }
        return findings.sorted {
            if $0.displayName != $1.displayName {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.hostRelativePath.localizedStandardCompare($1.hostRelativePath) == .orderedAscending
        }
    }

    /// 同一 Bundle ID 的其他副本。微信常同时有 `WeChat.app` 和 `微信.app`。
    public static func otherCopies(of app: URL) -> [URL] {
        let selected = app.standardizedFileURL.path
        let identifier = MacAppLibrary.bundleID(of: app)
        return MacAppLibrary.discover().filter { other in
            let path = other.standardizedFileURL.path
            guard path != selected else { return false }
            if let identifier, MacAppLibrary.bundleID(of: other) == identifier { return true }
            return MacAppLibrary.looksLikeWeChat(app) && MacAppLibrary.looksLikeWeChat(other)
        }
    }

    public static func remove(
        _ finding: InjectedPluginFinding,
        in app: URL,
        options: InjectedPluginRemovalOptions = InjectedPluginRemovalOptions()
    ) throws -> InjectedPluginRemovalReport {
        try remove([finding], in: app, options: options)
    }

    public static func remove(
        _ findings: [InjectedPluginFinding],
        in app: URL,
        options: InjectedPluginRemovalOptions = InjectedPluginRemovalOptions()
    ) throws -> InjectedPluginRemovalReport {
        try validateApp(app)
        guard !findings.isEmpty else { return InjectedPluginRemovalReport() }
        for finding in findings {
            switch classification(of: finding.loadPath, app: app) {
            case .system:
                throw InjectedPluginError.systemLibrary(finding.loadPath)
            case .bundled:
                throw InjectedPluginError.bundledLibrary(finding.loadPath)
            case .thirdParty:
                break
            }
        }

        requestQuit(app: app)
        var report = InjectedPluginRemovalReport()
        var signedHosts = Set<String>()

        for finding in findings {
            if !hasLoadCommand(finding.loadPath, in: finding.hostURL) {
                report.warnings.append(L("injectscan.log.alreadyGone", finding.loadPath))
                continue
            }
            try ensureWritable(finding.hostURL)
            try DylibInjector.removeLoadCommand(dylibPath: finding.loadPath, fileAt: finding.hostURL)
            report.removedLoadPaths.append(finding.loadPath)
            report.messages.append(
                L("injectscan.log.removedCommand", finding.loadPath, finding.hostRelativePath)
            )

            if options.deletePayload {
                deletePayload(finding.payloadURL, app: app, report: &report)
            }

            if options.resign {
                let hostPath = finding.hostURL.standardizedFileURL.path
                if signedHosts.insert(hostPath).inserted {
                    sign(finding.hostURL, label: finding.hostRelativePath, report: &report)
                }
            }
        }

        if options.resign {
            sign(app, label: app.lastPathComponent, report: &report)
        }
        return report
    }

    // MARK: 判定（测试用）

    static func classification(of path: String, app: URL) -> InjectedLibraryKind {
        if isSystemLibrary(path) { return .system }
        if isSkippedVendorPlugin(path) { return .bundled }
        if looksThirdParty(path, app: app) { return .thirdParty }
        return .bundled
    }

    static func isSystemLibrary(_ path: String) -> Bool {
        path.hasPrefix("/usr/lib/")
            || path.hasPrefix("/System/")
            || path.hasPrefix("/Library/Apple/")
    }

    static func isSkippedVendorPlugin(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("/vlc_plugins/") || lower.contains("vlc_plugins")
    }

    static func looksThirdParty(_ path: String, app: URL) -> Bool {
        let lower = path.lowercased()
        if thirdPartyMarkers.contains(where: { lower.contains($0) }) {
            return true
        }
        if path.hasPrefix("/"), isInsideApp(URL(fileURLWithPath: path), app: app) {
            return true
        }
        if path.hasPrefix("@executable_path/") {
            let rest = String(path.dropFirst("@executable_path/".count)).lowercased()
            if rest.contains(".framework/") || rest.hasSuffix(".dylib") || rest.hasSuffix(".framework") {
                return true
            }
        }
        return false
    }

    static func displayName(for loadPath: String) -> String {
        let parts = loadPath.split(separator: "/").map(String.init)
        if let framework = parts.first(where: { $0.lowercased().hasSuffix(".framework") }) {
            return String(framework.dropLast(".framework".count))
        }
        return parts.last ?? loadPath
    }

    static func resolveLoadPath(_ path: String, host: URL, app: URL) -> URL? {
        let candidate: URL
        if path.hasPrefix("@executable_path/") {
            let rest = String(path.dropFirst("@executable_path/".count))
            candidate = host.deletingLastPathComponent().appendingPathComponent(rest)
        } else if path.hasPrefix("@loader_path/") {
            let rest = String(path.dropFirst("@loader_path/".count))
            candidate = host.deletingLastPathComponent().appendingPathComponent(rest)
        } else if path.hasPrefix("@rpath/") {
            let rest = String(path.dropFirst("@rpath/".count))
            let options = [
                app.appendingPathComponent("Contents/Frameworks").appendingPathComponent(rest),
                app.appendingPathComponent("Frameworks").appendingPathComponent(rest),
                host.deletingLastPathComponent().appendingPathComponent(rest)
            ]
            candidate = options.first { FileManager.default.fileExists(atPath: $0.path) } ?? options[0]
        } else if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = host.deletingLastPathComponent().appendingPathComponent(path)
        }
        let resolved = candidate.standardizedFileURL
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }

    static func payloadRoot(for resolved: URL?, app: URL) -> URL? {
        guard let resolved, isInsideApp(resolved, app: app) else { return nil }
        var current = resolved
        while isInsideApp(current, app: app) {
            if current.pathExtension.lowercased() == "framework" {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return resolved
    }

    // MARK: 扫描

    private static let thirdPartyMarkers = [
        "wechatplugin", "x1a0he", "soviet", "wechattweak",
        "mobilesubstrate", "cydiasubstrate", "/libsubstrate",
        "ellekit", "libhooker", "cynject", "substitute.framework"
    ]

    private static func validateApp(_ app: URL) throws {
        guard app.pathExtension.lowercased() == "app", FileSystemHelper.isDirectory(app) else {
            throw InjectedPluginError.notApp
        }
    }

    private static func hostMachOFiles(in app: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: app,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if FileSystemHelper.isDirectory(url), shouldSkipDirectory(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard MachOIdentifier.isMachO(fileAt: url) else { continue }
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func shouldSkipDirectory(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "vlc_plugins" || lower == "_codesignature" { return true }
        if lower.hasSuffix(".lproj") { return true }
        if lower.hasSuffix(".app") { return true }
        return false
    }

    private static func uniqueCommands(_ inspections: [DylibSliceInspection]) -> [DylibLoadCommandInfo] {
        var seen = Set<String>()
        var result: [DylibLoadCommandInfo] = []
        for command in inspections.flatMap(\.commands) {
            let key = "\(command.weak ? "w" : "s")|\(command.path)"
            guard seen.insert(key).inserted else { continue }
            result.append(command)
        }
        return result
    }

    private static func hasLoadCommand(_ path: String, in host: URL) -> Bool {
        guard let inspections = try? DylibInjector.inspectLoadCommands(fileAt: host) else { return false }
        return inspections.contains { slice in
            slice.commands.contains { $0.path == path }
        }
    }

    // MARK: 删除与签名

    private static func deletePayload(
        _ payload: URL?,
        app: URL,
        report: inout InjectedPluginRemovalReport
    ) {
        guard let payload else {
            report.warnings.append(L("injectscan.log.payloadMissing"))
            return
        }
        guard isInsideApp(payload, app: app) else {
            report.warnings.append(L("injectscan.log.payloadOutside", payload.path))
            return
        }
        do {
            try FileManager.default.removeItem(at: payload)
            report.deletedPayloads.append(payload.path)
            report.messages.append(L("injectscan.log.deletedPayload", relativePath(payload, under: app)))
        } catch {
            report.warnings.append(
                L("injectscan.log.payloadPermission", relativePath(payload, under: app), error.localizedDescription)
            )
        }

        let state = payload.deletingLastPathComponent()
            .appendingPathComponent(".\(payload.deletingPathExtension().lastPathComponent).install_state")
        if isInsideApp(state, app: app), FileManager.default.fileExists(atPath: state.path) {
            try? FileManager.default.removeItem(at: state)
        }
    }

    private static func sign(
        _ url: URL,
        label: String,
        report: inout InjectedPluginRemovalReport
    ) {
        do {
            let result = try BinaryService.adhocSign(fileAt: url)
            if result.succeeded {
                report.messages.append(L("injectscan.log.signed", label))
            } else {
                report.warnings.append(L("injectscan.log.signFailed", label, result.combinedOutput))
            }
        } catch {
            report.warnings.append(L("injectscan.log.signFailed", label, error.localizedDescription))
        }
    }

    private static func requestQuit(app: URL) {
        #if canImport(AppKit)
        let target = app.standardizedFileURL
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == target
        }
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, running.contains(where: { !$0.isTerminated }) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        #endif
    }

    private static func ensureWritable(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isWritableKey])
        if values.isWritable == true { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        try FileManager.default.setAttributes(
            [.posixPermissions: mode | 0o200],
            ofItemAtPath: url.path
        )
    }

    private static func isInsideApp(_ url: URL, app: URL) -> Bool {
        let appPath = app.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == appPath || path.hasPrefix(appPath + "/")
    }

    private static func relativePath(_ file: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        if path == rootPath { return file.lastPathComponent }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return file.lastPathComponent
    }
}
