import Foundation

/// 重签名方式。
public enum SignMethod: String, CaseIterable, Sendable {
    case codesignAdhoc = "codesign (ad-hoc)"
    case ldid = "ldid (伪签名)"
    case none = "不签名"

    /// rawValue 同时是持久化标识,展示一律走这里。
    public var label: String {
        switch self {
        case .codesignAdhoc: return L("signMethod.codesignAdhoc")
        case .ldid: return L("signMethod.ldid")
        case .none: return L("signMethod.none")
        }
    }
}

/// IPA 注入选项。
public struct IpaInjectionOptions: Sendable {
    public var dylibSource: URL
    /// 自定义 load 路径;为空时根据是否放入 Frameworks 自动生成。
    public var customLoadPath: String?
    public var weak: Bool
    public var stripCodeSignature: Bool
    public var signMethod: SignMethod
    /// true:放入 `<App>/Frameworks/`;false:放到 App 根目录。
    public var embedIntoFrameworks: Bool
    public var addRPath: Bool

    public init(dylibSource: URL,
                customLoadPath: String? = nil,
                weak: Bool = false,
                stripCodeSignature: Bool = true,
                signMethod: SignMethod = .codesignAdhoc,
                embedIntoFrameworks: Bool = true,
                addRPath: Bool = true) {
        self.dylibSource = dylibSource
        self.customLoadPath = customLoadPath
        self.weak = weak
        self.stripCodeSignature = stripCodeSignature
        self.signMethod = signMethod
        self.embedIntoFrameworks = embedIntoFrameworks
        self.addRPath = addRPath
    }
}

/// IPA 注入结果。
public struct IpaInjectionResult: Sendable {
    public var outputIPA: URL
    public var appName: String
    public var executableName: String
    public var injectedLoadPath: String
    public var log: [String]
}

/// 把本机 .app / .xcarchive / 已解包 Payload 原样打成 IPA 的结果。不修改 Mach-O，不脱壳。
public struct IpaPackageResult: Sendable {
    public var outputIPA: URL
    public var appName: String
    public var bundleIdentifier: String?
    public var executableName: String
    public var isEncrypted: Bool
    public var architectures: [String]
    public var log: [String]
}

/// IPA 的解包、注入 dylib、重签名与重打包。
public enum IpaService {

    /// 把本机 `.app`、`.xcarchive` 或已解包的 `Payload` 打成 IPA。
    /// 只做拷贝和打包，不改 cryptid，也不解密 FairPlay。
    public static func package(source: URL, outputURL: URL? = nil) throws -> IpaPackageResult {
        var log: [String] = []
        let app = try resolveAppBundle(from: source)
        try rejectMacApp(app)
        log.append(L("ipa.log.packageSource", app.path))

        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-package")
        defer { try? FileManager.default.removeItem(at: work) }
        let payload = work.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let destApp = payload.appendingPathComponent(app.lastPathComponent)
        try copyAppBundle(app, to: destApp)
        try validatePayloadStructure(in: work)

        let plist = try infoPlist(appBundle: destApp)
        let execName = (plist["CFBundleExecutable"] as? String)
            ?? destApp.deletingPathExtension().lastPathComponent
        let bundleID = plist["CFBundleIdentifier"] as? String
        let execURL = destApp.appendingPathComponent(execName)
        guard MachOIdentifier.isMachO(fileAt: execURL) else { throw IpaError.executableNotFound }
        let facts = MachOInspector.facts(fileAt: execURL)
        let encrypted = facts?.isEncrypted == true
        log.append(L("ipa.log.mainExecutable", execName))
        log.append(encrypted ? L("ipa.log.encryptedCopy") : L("ipa.log.unencryptedCopy"))

        let proposed = outputURL ?? source
            .deletingPathExtension()
            .appendingPathExtension("ipa")
        let output = FileSystemHelper.uniqueOutputURL(basedOn: proposed)
        try zipPayload(in: work, to: output)
        log.append(L("ipa.log.packaged", output.lastPathComponent))

        return IpaPackageResult(
            outputIPA: output,
            appName: destApp.lastPathComponent,
            bundleIdentifier: bundleID,
            executableName: execName,
            isEncrypted: encrypted,
            architectures: facts?.archs ?? [],
            log: log
        )
    }

    /// 把设备归档（zip / ipa / 裸 .app）规范成 IPA。仍是原样拷贝，不脱壳。
    public static func adoptDeviceArchive(_ archive: URL, outputURL: URL) throws -> IpaPackageResult {
        var log: [String] = [L("ipa.log.adoptArchive", archive.lastPathComponent)]
        if archive.pathExtension.lowercased() == "app", FileSystemHelper.isDirectory(archive) {
            let result = try package(source: archive, outputURL: outputURL)
            return IpaPackageResult(
                outputIPA: result.outputIPA,
                appName: result.appName,
                bundleIdentifier: result.bundleIdentifier,
                executableName: result.executableName,
                isEncrypted: result.isEncrypted,
                architectures: result.architectures,
                log: log + result.log
            )
        }

        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-adopt")
        defer { try? FileManager.default.removeItem(at: work) }
        try unzip(archive, to: work)

        if (try? validatePayloadStructure(in: work)) != nil {
            let app = try locateApp(in: work)
            try rejectMacApp(app)
            let facts = try executableFacts(appBundle: app)
            let output = FileSystemHelper.uniqueOutputURL(basedOn: outputURL)
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw IpaError.outputExists(output.path)
            }
            try FileManager.default.copyItem(at: archive, to: output)
            log.append(facts.isEncrypted ? L("ipa.log.encryptedCopy") : L("ipa.log.unencryptedCopy"))
            log.append(L("ipa.log.packaged", output.lastPathComponent))
            return IpaPackageResult(
                outputIPA: output,
                appName: app.lastPathComponent,
                bundleIdentifier: facts.bundleIdentifier,
                executableName: facts.executableName,
                isEncrypted: facts.isEncrypted,
                architectures: facts.architectures,
                log: log
            )
        }

        let rootApps = try FileManager.default.contentsOfDirectory(
            at: work,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "app" && FileSystemHelper.isDirectory($0) }
        guard rootApps.count == 1 else {
            throw IpaError.invalidPayload(L("ipa.invalidPayload.archiveAppCount", rootApps.count))
        }
        let wrapped = try package(source: rootApps[0], outputURL: outputURL)
        return IpaPackageResult(
            outputIPA: wrapped.outputIPA,
            appName: wrapped.appName,
            bundleIdentifier: wrapped.bundleIdentifier,
            executableName: wrapped.executableName,
            isEncrypted: wrapped.isEncrypted,
            architectures: wrapped.architectures,
            log: log + wrapped.log
        )
    }

    /// 解包 IPA 并返回其中的 Payload/*.app 信息(用于查看)。
    public static func inspect(ipaAt url: URL) throws -> (appName: String, executable: String, plist: [String: Any]) {
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-inspect")
        defer { try? FileManager.default.removeItem(at: work) }
        let extractDir = work.appendingPathComponent("x")
        try unzip(url, to: extractDir)
        try validatePayloadStructure(in: extractDir)
        let app = try locateApp(in: extractDir)
        let plist = try infoPlist(appBundle: app)
        let exec = (plist["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
        return (app.lastPathComponent, exec, plist)
    }

    public static func identity(ipaAt url: URL) throws -> IpaIdentity {
        let inspected = try inspect(ipaAt: url)
        let bundleID = (inspected.plist["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bundleID.isEmpty else {
            throw IpaError.invalidPayload(L("ipa.invalidPayload.missingBundleID"))
        }
        return IpaIdentity(
            appName: inspected.appName,
            bundleIdentifier: bundleID,
            executableName: inspected.executable,
            shortVersion: inspected.plist["CFBundleShortVersionString"] as? String,
            buildVersion: inspected.plist["CFBundleVersion"] as? String
        )
    }

    /// 保留数据降级：只提高 CFBundleVersion，让 iOS 把旧包当成升级覆盖。
    /// 显示版本（CFBundleShortVersionString）保持 IPA 原值。改 Info.plist 后必须重签。
    public static func prepareKeepDataDowngrade(
        ipaAt url: URL,
        installedBuild: String?,
        signMethod: SignMethod,
        outputURL: URL? = nil
    ) throws -> IpaPackageResult {
        var log: [String] = []
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-downgrade")
        defer { try? FileManager.default.removeItem(at: work) }
        let extractDir = work.appendingPathComponent("extract")
        try unzip(url, to: extractDir)
        try validatePayloadStructure(in: extractDir)
        let app = try locateApp(in: extractDir)
        try rejectMacApp(app)
        let facts = try executableFacts(appBundle: app)
        if facts.isEncrypted {
            throw IpaError.unsupportedSource(L("ipa.error.encryptedNoInPlaceDowngrade"))
        }

        let plist = try infoPlist(appBundle: app)
        let originalBuild = plist["CFBundleVersion"] as? String
        let shortVersion = plist["CFBundleShortVersionString"] as? String
        let newBuild = AppVersionOrdering.buildNumberForInPlaceDowngrade(
            ipaBuild: originalBuild,
            installedBuild: installedBuild
        )
        try bumpBuildNumbers(in: app, to: newBuild)
        log.append(L("ipa.log.bumpedBuild", originalBuild ?? "—", newBuild))
        log.append(L("ipa.log.keepShortVersion", shortVersion ?? "—"))

        try SigningService.resignJailbreak(app: app, method: signMethod, entitlements: nil, log: &log)
        try validatePayloadStructure(in: extractDir)

        let proposed = outputURL ?? url
            .deletingPathExtension()
            .appendingPathExtension("downgrade")
            .appendingPathExtension("ipa")
        let output = FileSystemHelper.uniqueOutputURL(basedOn: proposed)
        let topItems = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
        try zipItems(topItems, in: extractDir, to: output)
        log.append(L("ipa.log.packaged", output.lastPathComponent))

        return IpaPackageResult(
            outputIPA: output,
            appName: app.lastPathComponent,
            bundleIdentifier: facts.bundleIdentifier,
            executableName: facts.executableName,
            isEncrypted: false,
            architectures: facts.architectures,
            log: log
        )
    }

    /// 向 IPA 注入 dylib。
    public static func inject(ipaAt url: URL,
                              options: IpaInjectionOptions,
                              outputURL: URL? = nil) throws -> IpaInjectionResult {
        var log: [String] = []
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-inject")
        defer { try? FileManager.default.removeItem(at: work) }

        // 1) 解包
        let extractDir = work.appendingPathComponent("extract")
        try unzip(url, to: extractDir)
        try validatePayloadStructure(in: extractDir)
        log.append(L("ipa.log.unpacked"))

        // 2) 定位 App 与主可执行文件
        let app = try locateApp(in: extractDir)
        log.append("App:\(app.lastPathComponent)")
        let plist = try infoPlist(appBundle: app)
        let execName = (plist["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
        let execURL = app.appendingPathComponent(execName)
        guard MachOIdentifier.isMachO(fileAt: execURL) else { throw IpaError.executableNotFound }
        log.append(L("ipa.log.mainExecutable", execName))

        // 3) 拷贝 dylib
        let dylibName = options.dylibSource.lastPathComponent
        let destDir: URL
        let loadPath: String
        if options.embedIntoFrameworks {
            destDir = app.appendingPathComponent("Frameworks")
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            loadPath = options.customLoadPath ?? "@executable_path/Frameworks/\(dylibName)"
        } else {
            destDir = app
            loadPath = options.customLoadPath ?? "@executable_path/\(dylibName)"
        }
        let dylibDest = destDir.appendingPathComponent(dylibName)
        if FileManager.default.fileExists(atPath: dylibDest.path) {
            throw IpaError.outputExists(dylibDest.path)
        }
        try FileManager.default.copyItem(at: options.dylibSource, to: dylibDest)
        log.append(L("ipa.log.dylibCopied", loadPath))

        let executableArchitectures = try BinaryService.architectures(fileAt: execURL)
        let dylibArchitectures = try BinaryService.architectures(fileAt: dylibDest)
        let missing = Set(executableArchitectures).subtracting(dylibArchitectures)
        guard missing.isEmpty else {
            throw IpaError.architectureMismatch(
                executable: executableArchitectures,
                dylib: dylibArchitectures,
                missing: missing.sorted()
            )
        }

        // 4) 注入 load command
        let report = try DylibInjector.inject(dylibPath: loadPath, intoFileAt: execURL,
                                              weak: options.weak,
                                              stripCodeSignature: options.stripCodeSignature)
        log.append(contentsOf: report.messages)

        // 5) 可选:补 rpath
        if options.addRPath, options.embedIntoFrameworks {
            guard ExternalTool.installNameTool.isAvailable else {
                throw IpaError.commandFailed(L("ipa.error.installNameToolUnavailable"))
            }
            let existing = try DylibService.rpaths(fileAt: execURL)
            if !existing.contains("@executable_path/Frameworks") {
                let rpathResult = try DylibService.addRPath("@executable_path/Frameworks", fileAt: execURL)
                guard rpathResult.succeeded else { throw IpaError.commandFailed(rpathResult.combinedOutput) }
            }
        }

        // 6) 重签名(注入后原签名已失效)
        try resign(execURL: execURL, dylibURL: dylibDest, app: app, method: options.signMethod, log: &log)

        // 7) 重打包:在解包根目录下压缩全部顶层项(保留 Symbols 等)。
        try validatePayloadStructure(in: extractDir)
        let proposed = url.deletingPathExtension()
            .appendingPathExtension("injected")
            .appendingPathExtension("ipa")
        let output = outputURL ?? FileSystemHelper.uniqueOutputURL(basedOn: proposed)
        let topItems = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
        try zipItems(topItems, in: extractDir, to: output)
        log.append(L("ipa.log.repackaged", output.lastPathComponent))

        return IpaInjectionResult(outputIPA: output,
                                  appName: app.lastPathComponent,
                                  executableName: execName,
                                  injectedLoadPath: loadPath,
                                  log: log)
    }

    // MARK: - 内部

    private static func resign(execURL: URL, dylibURL: URL, app: URL,
                               method: SignMethod, log: inout [String]) throws {
        _ = execURL
        _ = dylibURL
        _ = try SigningService.resignJailbreak(app: app, method: method, entitlements: nil, log: &log)
    }

    static func unzip(_ url: URL, to destination: URL) throws {
        _ = try ArchiveSafety.validateZIP(at: url)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let result = try ExternalTool.unzip.run(["-q", "-o", url.path, "-d", destination.path])
        guard result.succeeded else { throw IpaError.commandFailed(result.combinedOutput) }
        let links = FileSystemHelper.allFiles(in: destination) {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        }
        guard links.isEmpty else { throw ArchiveSafetyError.symbolicLink(links[0].path) }
    }

    static func locateApp(in extractDir: URL) throws -> URL {
        let payload = extractDir.appendingPathComponent("Payload")
        guard let items = try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil),
              let app = items.first(where: { $0.pathExtension == "app" }) else {
            throw IpaError.appNotFound
        }
        return app
    }

    public static func infoPlist(appBundle: URL) throws -> [String: Any] {
        let plistURL = infoPlistURL(appBundle: appBundle)
        let data = try Data(contentsOf: plistURL)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = obj as? [String: Any] else {
            throw IpaError.invalidPayload(L("ipa.invalidPayload.infoPlistRootNotDictionary"))
        }
        return dictionary
    }

    static func infoPlistURL(appBundle: URL) -> URL {
        let macOSPlist = appBundle.appendingPathComponent("Contents/Info.plist")
        return FileManager.default.fileExists(atPath: macOSPlist.path)
            ? macOSPlist
            : appBundle.appendingPathComponent("Info.plist")
    }

    public static func validatePayloadStructure(in extractDir: URL) throws {
        let payload = extractDir.appendingPathComponent("Payload")
        guard FileSystemHelper.isDirectory(payload) else {
            throw IpaError.invalidPayload(L("ipa.invalidPayload.missingPayloadDirectory"))
        }
        let items = try FileManager.default.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let apps = items.filter { $0.pathExtension.lowercased() == "app" && FileSystemHelper.isDirectory($0) }
        guard apps.count == 1 else {
            throw IpaError.invalidPayload(L("ipa.invalidPayload.appCount", apps.count))
        }
    }

    static func resolveAppBundle(from source: URL) throws -> URL {
        let ext = source.pathExtension.lowercased()
        if ext == "ipa" {
            throw IpaError.unsupportedSource(L("ipa.error.alreadyIPA"))
        }
        if ext == "app", FileSystemHelper.isDirectory(source) {
            return source
        }
        if ext == "xcarchive", FileSystemHelper.isDirectory(source) {
            let appsDir = source.appendingPathComponent("Products/Applications")
            let items = (try? FileManager.default.contentsOfDirectory(
                at: appsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let apps = items.filter { $0.pathExtension.lowercased() == "app" && FileSystemHelper.isDirectory($0) }
            guard apps.count == 1 else {
                throw IpaError.invalidPayload(L("ipa.invalidPayload.xcarchiveAppCount", apps.count))
            }
            return apps[0]
        }
        if source.lastPathComponent == "Payload" {
            return try locateApp(in: source.deletingLastPathComponent())
        }
        let nestedPayload = source.appendingPathComponent("Payload")
        if FileSystemHelper.isDirectory(nestedPayload) {
            try validatePayloadStructure(in: source)
            return try locateApp(in: source)
        }
        throw IpaError.unsupportedSource(L("ipa.error.unsupportedPackageSource"))
    }

    static func rejectMacApp(_ app: URL) throws {
        let macOSDir = app.appendingPathComponent("Contents/MacOS")
        guard !FileSystemHelper.isDirectory(macOSDir) else {
            throw IpaError.unsupportedSource(L("ipa.error.macAppNotIPA"))
        }
    }

    private static func copyAppBundle(_ app: URL, to dest: URL) throws {
        try FileManager.default.copyItem(at: app, to: dest)
        let links = FileSystemHelper.allFiles(in: dest) {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        }
        guard links.isEmpty else { throw ArchiveSafetyError.symbolicLink(links[0].path) }
    }

    private static func zipPayload(in workDir: URL, to output: URL) throws {
        try zipItems(["Payload"], in: workDir, to: output)
    }

    private static func zipItems(_ items: [String], in directory: URL, to output: URL) throws {
        guard !items.isEmpty else { throw IpaError.commandFailed(L("ipa.error.emptyZipItems")) }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw IpaError.outputExists(output.path)
        }
        let temporaryOutput = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryOutput) }
        let zipResult = try ExternalTool.zip.run(
            ["-qry", "-X", temporaryOutput.path] + items,
            currentDirectory: directory
        )
        guard zipResult.succeeded else { throw IpaError.commandFailed(zipResult.combinedOutput) }
        _ = try ArchiveSafety.validateZIP(at: temporaryOutput)
        try FileManager.default.moveItem(at: temporaryOutput, to: output)
    }

    private static func executableFacts(appBundle: URL) throws -> (
        executableName: String,
        bundleIdentifier: String?,
        isEncrypted: Bool,
        architectures: [String]
    ) {
        let plist = try infoPlist(appBundle: appBundle)
        let execName = (plist["CFBundleExecutable"] as? String)
            ?? appBundle.deletingPathExtension().lastPathComponent
        let execURL = appBundle.appendingPathComponent(execName)
        guard MachOIdentifier.isMachO(fileAt: execURL) else { throw IpaError.executableNotFound }
        let facts = MachOInspector.facts(fileAt: execURL)
        return (
            execName,
            plist["CFBundleIdentifier"] as? String,
            facts?.isEncrypted == true,
            facts?.archs ?? []
        )
    }

    private static func bumpBuildNumbers(in app: URL, to newBuild: String) throws {
        var plistURLs = FileSystemHelper.allFiles(in: app) { $0.lastPathComponent == "Info.plist" }
        let root = infoPlistURL(appBundle: app)
        if !plistURLs.contains(root) { plistURLs.insert(root, at: 0) }
        for plistURL in plistURLs {
            var format: PropertyListSerialization.PropertyListFormat = .xml
            let data = try Data(contentsOf: plistURL)
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            guard var dictionary = object as? [String: Any] else { continue }
            dictionary["CFBundleVersion"] = newBuild
            let written = try PropertyListSerialization.data(fromPropertyList: dictionary, format: format, options: 0)
            try written.write(to: plistURL)
        }
    }
}

public enum IpaError: LocalizedError {
    case commandFailed(String)
    case appNotFound
    case executableNotFound
    case outputExists(String)
    case architectureMismatch(executable: [String], dylib: [String], missing: [String])
    case invalidPayload(String)
    case unsupportedSource(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(output): return L("ipa.error.commandFailed", output)
        case .appNotFound: return L("ipa.error.appNotFound")
        case .executableNotFound: return L("ipa.error.executableNotFound")
        case let .outputExists(path): return L("ipa.error.outputExists", path)
        case let .architectureMismatch(executable, dylib, missing):
            return L(
                "ipa.error.architectureMismatch",
                executable.joined(separator: ","),
                dylib.joined(separator: ","),
                missing.joined(separator: ",")
            )
        case let .invalidPayload(reason): return L("ipa.error.invalidPayload", reason)
        case let .unsupportedSource(reason): return reason
        }
    }
}
