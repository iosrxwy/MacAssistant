import Foundation

/// 体积测量(解包后近似安装占用 / zip 后近似下载大小)。
public struct SizePair: Sendable {
    public let unpacked: Int64
    public let zipped: Int64
    public init(unpacked: Int64, zipped: Int64) {
        self.unpacked = unpacked
        self.zipped = zipped
    }
}

/// IPA 瘦身选项。
public struct SlimOptions: Sendable {
    public var thinToArch: String?               // 仅保留该架构(优先于 removeArchs)
    public var removeArchs: [String]             // 去掉这些架构(如 x86_64 / i386 模拟器切片)
    public var stripSymbols: Bool                // strip -rSTx(🔴 需确认已备份 dSYM)
    public var gentleStripFrameworksOnly: Bool   // 仅对 Frameworks 温和 strip -x
    public var removeAppDSYM: Bool               // 删 .app 内嵌 *.dSYM
    public var removeRootDebris: Bool            // 删根级 Symbols / *.dSYM / *.bcsymbolmap(不动 .app)
    public var signMethod: SignMethod            // 触碰 mach-o 后重签

    public init(thinToArch: String? = "arm64",
                removeArchs: [String] = ["x86_64", "i386"],
                stripSymbols: Bool = false,
                gentleStripFrameworksOnly: Bool = false,
                removeAppDSYM: Bool = true,
                removeRootDebris: Bool = true,
                signMethod: SignMethod = .codesignAdhoc) {
        self.thinToArch = thinToArch
        self.removeArchs = removeArchs
        self.stripSymbols = stripSymbols
        self.gentleStripFrameworksOnly = gentleStripFrameworksOnly
        self.removeAppDSYM = removeAppDSYM
        self.removeRootDebris = removeRootDebris
        self.signMethod = signMethod
    }
}

public struct SlimResult: Sendable {
    public var before: SizePair
    public var after: SizePair
    public var touchedMachO: Bool
    public var output: URL
    public var log: [String]
    public var freedZipped: Int64 { max(0, before.zipped - after.zipped) }
    public var freedUnpacked: Int64 { max(0, before.unpacked - after.unpacked) }
}

public enum SlimError: LocalizedError {
    case commandFailed(String)
    public var errorDescription: String? {
        switch self { case let .commandFailed(o): return L("slim.error.commandFailed", o) }
    }
}

/// IPA 瘦身:去架构 / 去符号 / 清 dSYM·bcsymbolmap·Symbols + 前后体积测量 + 触碰 Mach-O 后自动重签。
public enum SlimService {

    /// 递归测量一个目录(解包后体积)。
    public static func measureUnpacked(_ dir: URL) -> Int64 { FileSystemHelper.size(at: dir) }

    public static func slim(ipaAt url: URL, options: SlimOptions, outputURL: URL? = nil) throws -> SlimResult {
        var log: [String] = []
        var touched = false
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-slim")
        defer { try? FileManager.default.removeItem(at: work) }

        let extractDir = work.appendingPathComponent("x")
        try IpaService.unzip(url, to: extractDir)
        try IpaService.validatePayloadStructure(in: extractDir)
        let before = SizePair(unpacked: FileSystemHelper.size(at: extractDir),
                              zipped: FileSystemHelper.size(at: url))
        log.append(L(
            "slim.log.unpacked",
            FileSystemHelper.humanReadableSize(before.unpacked),
            FileSystemHelper.humanReadableSize(before.zipped)
        ))

        // A. 删根级调试产物(不动 .app,无需重签)
        if options.removeRootDebris {
            try removeRootDebris(in: extractDir, log: &log)
        }

        let app = try IpaService.locateApp(in: extractDir)

        // D. 删 .app 内嵌 dSYM(动 .app → 需重签)
        if options.removeAppDSYM {
            for d in FileSystemHelper.allFiles(in: app, where: { $0.pathExtension == "dSYM" }) {
                try FileManager.default.removeItem(at: d)
                touched = true
                log.append(L("slim.log.removedEmbeddedDSYM", d.lastPathComponent))
            }
        }

        // B. 去架构(动 Mach-O → 需重签)
        let machOs = FileSystemHelper.allFiles(in: app) { MachOIdentifier.isMachO(fileAt: $0) }
        for m in machOs {
            let archs = try BinaryService.architectures(fileAt: m)
            guard archs.count > 1 else { continue }
            if let keep = options.thinToArch, archs.contains(keep) {
                if try thinInPlace(m, keepArch: keep) { touched = true; log.append(L("slim.log.lipoThin", keep, m.lastPathComponent)) }
            } else {
                let toRemove = options.removeArchs.filter { archs.contains($0) && archs.count > 1 }
                if !toRemove.isEmpty, try removeArchsInPlace(m, remove: toRemove, current: archs) {
                    touched = true
                    log.append(L("slim.log.lipoRemoveArchs", toRemove.joined(separator: ","), m.lastPathComponent))
                }
            }
        }

        // C. strip 去符号(动 Mach-O → 需重签)
        if options.stripSymbols {
            guard ExternalTool.strip.isAvailable else {
                throw SlimError.commandFailed(L("slim.error.stripUnavailable"))
            }
            for m in FileSystemHelper.allFiles(in: app, where: { MachOIdentifier.isMachO(fileAt: $0) }) {
                let r = try ExternalTool.strip.run(["-rSTx", m.path])
                guard r.succeeded else { throw SlimError.commandFailed(r.combinedOutput) }
                touched = true
            }
            log.append(L("slim.log.stripSymbolsDone"))
        } else if options.gentleStripFrameworksOnly, ExternalTool.strip.isAvailable {
            let fw = app.appendingPathComponent("Frameworks")
            if FileSystemHelper.isDirectory(fw) {
                for m in FileSystemHelper.allFiles(in: fw, where: { MachOIdentifier.isMachO(fileAt: $0) }) {
                    let r = try ExternalTool.strip.run(["-x", m.path])
                    guard r.succeeded else { throw SlimError.commandFailed(r.combinedOutput) }
                    touched = true
                }
                log.append(L("slim.log.gentleStripDone"))
            }
        }

        // 触碰 Mach-O / .app 内文件 → 重签
        if touched {
            log.append(L("slim.log.resigning", options.signMethod.rawValue))
            _ = try SigningService.resignJailbreak(app: app, method: options.signMethod, entitlements: nil, log: &log)
        } else {
            log.append(L("slim.log.noResignNeeded"))
        }

        // E. 重新打包
        let proposed = url.deletingPathExtension().appendingPathExtension("slim").appendingPathExtension("ipa")
        let output = outputURL ?? FileSystemHelper.uniqueOutputURL(basedOn: proposed)
        try repackage(extractDir: extractDir, to: output)
        log.append(L("slim.log.repackaged", output.lastPathComponent))

        let after = SizePair(unpacked: FileSystemHelper.size(at: extractDir),
                             zipped: FileSystemHelper.size(at: output))
        log.append(L(
            "slim.log.afterSlimming",
            FileSystemHelper.humanReadableSize(after.unpacked),
            FileSystemHelper.humanReadableSize(after.zipped)
        ))

        return SlimResult(before: before, after: after, touchedMachO: touched, output: output, log: log)
    }

    // MARK: - 内部

    static func removeRootDebris(in extractDir: URL, log: inout [String]) throws {
        let fm = FileManager.default
        let symbols = extractDir.appendingPathComponent("Symbols")
        if FileSystemHelper.isDirectory(symbols) { try fm.removeItem(at: symbols); log.append(L("slim.log.removedRootSymbols")) }
        // 根级(非 .app 内)*.dSYM / *.bcsymbolmap
        let items = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        for item in items where item.pathExtension == "dSYM" {
            try fm.removeItem(at: item); log.append(L("slim.log.removedRootItem", item.lastPathComponent))
        }
        for bc in FileSystemHelper.allFiles(in: extractDir, where: { $0.pathExtension == "bcsymbolmap" && !$0.path.contains(".app/") }) {
            try fm.removeItem(at: bc)
        }
    }

    static func thinInPlace(_ url: URL, keepArch: String) throws -> Bool {
        let tmp = url.appendingPathExtension("thintmp")
        defer { try? FileManager.default.removeItem(at: tmp) } // 工作区临时产物，失败时清理。
        let r = try ExternalTool.lipo.run([url.path, "-thin", keepArch, "-output", tmp.path])
        guard r.succeeded else { throw SlimError.commandFailed(r.combinedOutput) }
        try replace(url, with: tmp)
        return true
    }

    static func removeArchsInPlace(_ url: URL, remove: [String], current: [String]) throws -> Bool {
        guard current.count - remove.count >= 1 else { return false }
        let tmp = url.appendingPathExtension("lipotmp")
        defer { try? FileManager.default.removeItem(at: tmp) } // 工作区临时产物，失败时清理。
        var args = [url.path]
        for a in remove { args += ["-remove", a] }
        args += ["-output", tmp.path]
        let r = try ExternalTool.lipo.run(args)
        guard r.succeeded else { throw SlimError.commandFailed(r.combinedOutput) }
        try replace(url, with: tmp)
        return true
    }

    private static func replace(_ url: URL, with tmp: URL) throws {
        let perms = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        if let perms { try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
    }

    static func repackage(extractDir: URL, to output: URL) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw SlimError.commandFailed(L("slim.error.outputExists", output.path))
        }
        try IpaService.validatePayloadStructure(in: extractDir)
        let topItems = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
        let temporaryOutput = output.deletingLastPathComponent()
            .appendingPathComponent(".slim-\(UUID().uuidString).ipa")
        defer { try? FileManager.default.removeItem(at: temporaryOutput) } // 失败时不暴露半成品。
        let r = try ExternalTool.zip.run(["-qry", "-X", temporaryOutput.path] + topItems, currentDirectory: extractDir)
        guard r.succeeded else { throw SlimError.commandFailed(r.combinedOutput) }
        _ = try ArchiveSafety.validateZIP(at: temporaryOutput)
        try FileManager.default.moveItem(at: temporaryOutput, to: output)
    }
}
