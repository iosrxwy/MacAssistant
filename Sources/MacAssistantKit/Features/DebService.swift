import Foundation

/// Debian 包(.deb)的 control 元信息。
public struct DebControl: Sendable {
    public var fields: [String: String]
    public var rawText: String

    public var package: String? { fields["Package"] }
    public var version: String? { fields["Version"] }
    public var architecture: String? { fields["Architecture"] }
    public var maintainer: String? { fields["Maintainer"] }
    public var depends: String? { fields["Depends"] }
    public var section: String? { fields["Section"] }
    public var descriptionText: String? { fields["Description"] }
}

/// data.tar 中的一个条目。
public struct DebEntry: Identifiable, Sendable {
    public let id = UUID()
    public let path: String
    public let size: Int64?
    public let isDirectory: Bool
    public let link: String?
    /// 原始权限串(如 `-rwsr-xr-x`)。setuid/setgid 与可执行位的判定依赖它,不解析就丢会让
    /// 后续无法识别设备级二进制,故予以保留。来源工具不提供时为 nil。
    public let mode: String?

    public init(
        path: String,
        size: Int64?,
        isDirectory: Bool,
        link: String?,
        mode: String? = nil
    ) {
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.link = link
        self.mode = mode
    }
}

/// .deb 检查结果。
public struct DebInfo: Sendable {
    public var control: DebControl
    public var entries: [DebEntry]
    public var usedDpkg: Bool
}

public enum DebPackageLayout: String, CaseIterable, Sendable {
    case rootful
    case rootless
    case roothide

    public var label: String {
        switch self {
        case .rootful: return "Rootful / 有根"
        case .rootless: return "Rootless / 无根"
        case .roothide: return "Roothide / 隐根"
        }
    }

    public var defaultArchitecture: String {
        switch self {
        case .rootful: return "iphoneos-arm"
        case .rootless: return "iphoneos-arm64"
        case .roothide: return "iphoneos-arm64e"
        }
    }

    public var pathHint: String {
        switch self {
        case .rootful: return "/Library/…"
        case .rootless: return "/var/jb/Library/…"
        case .roothide: return "随机 jbroot / Library/…"
        }
    }

    fileprivate var machORootPrefix: String {
        switch self {
        case .rootful: return "/"
        case .rootless: return "/var/jb/"
        case .roothide: return "@loader_path/.jbroot/"
        }
    }

    public var packagePrefix: String {
        switch self {
        case .rootful: return ""
        case .rootless: return "var/jb"
        case .roothide: return ""
        }
    }

    public var dynamicLibrariesPath: String {
        joining(packagePrefix, "Library/MobileSubstrate/DynamicLibraries")
    }

    public var frameworksPath: String {
        joining(packagePrefix, "Library/Frameworks")
    }

    private func joining(_ prefix: String, _ suffix: String) -> String {
        prefix.isEmpty ? suffix : "\(prefix)/\(suffix)"
    }
}

public struct DebPackageMetadata: Equatable, Sendable {
    public var packageID: String
    public var name: String
    public var version: String
    public var architecture: String
    public var description: String
    public var maintainer: String
    public var author: String
    public var depends: String
    public var section: String

    public init(
        packageID: String,
        name: String,
        version: String,
        architecture: String,
        description: String,
        maintainer: String,
        author: String = "",
        depends: String = "",
        section: String = "Tweaks"
    ) {
        self.packageID = packageID
        self.name = name
        self.version = version
        self.architecture = architecture
        self.description = description
        self.maintainer = maintainer
        self.author = author
        self.depends = depends
        self.section = section
    }
}

public enum DebMaintainerScript: String, CaseIterable, Sendable {
    case preinst, postinst, prerm, postrm
}

public struct TweakFilter: Equatable, Sendable {
    public var bundles: [String]
    public var executables: [String]
    public var classes: [String]
    public var coreFoundationVersion: [Double]

    public init(
        bundles: [String] = [],
        executables: [String] = [],
        classes: [String] = [],
        coreFoundationVersion: [Double] = []
    ) {
        self.bundles = bundles
        self.executables = executables
        self.classes = classes
        self.coreFoundationVersion = coreFoundationVersion
    }

    public var isEmpty: Bool {
        bundles.isEmpty && executables.isEmpty && classes.isEmpty && coreFoundationVersion.isEmpty
    }
}

public struct DebPackageRequest: Sendable {
    public var metadata: DebPackageMetadata
    public var layout: DebPackageLayout
    public var sourceLayout: DebPackageLayout?
    public var dylibs: [URL]
    public var companionPlists: [String: URL]
    public var extraResources: [URL]
    public var generatedFilter: TweakFilter?
    public var scripts: [DebMaintainerScript: String]

    public init(
        metadata: DebPackageMetadata,
        layout: DebPackageLayout,
        sourceLayout: DebPackageLayout? = nil,
        dylibs: [URL],
        companionPlists: [String: URL] = [:],
        extraResources: [URL] = [],
        generatedFilter: TweakFilter? = nil,
        scripts: [DebMaintainerScript: String] = [:]
    ) {
        self.metadata = metadata
        self.layout = layout
        self.sourceLayout = sourceLayout
        self.dylibs = dylibs
        self.companionPlists = companionPlists
        self.extraResources = extraResources
        self.generatedFilter = generatedFilter
        self.scripts = scripts
    }
}

public enum DebPlannedEntryKind: String, Sendable {
    case control, dylib, filter, framework, bundle, resource, script
}

public struct DebPlannedEntry: Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let kind: DebPlannedEntryKind
    public let source: URL?
    public let size: Int64
}

public struct DebBuildPlan: Sendable {
    public let controlText: String
    public let entries: [DebPlannedEntry]
    public let estimatedSize: Int64
    public let tree: String
}

public struct DebBuildResult: Sendable {
    public let output: URL
    public let plan: DebBuildPlan
    public let infoOutput: String
    public let contentsOutput: String
}

public struct DebLayoutConversionResult: Sendable {
    public let output: URL
    public let sourceLayout: DebPackageLayout
    public let targetLayout: DebPackageLayout
    public let sha256: String
    public let changes: [DebWorkspaceChange]
    public let verification: DebInfo
}

public struct DebValidationError: LocalizedError, Equatable {
    public let messages: [String]
    public var errorDescription: String? {
        L("deb.error.validationFailed", messages.map { "• \($0)" }.joined(separator: "\n"))
    }
}

/// .deb 的解包、查看、提取与重新打包。
///
/// 优先使用 `dpkg-deb`;若不可用则回退到 `ar` + `tar`(macOS 自带),
/// 从而在没有安装 dpkg 的机器上也能工作。
public enum DebService {

    public static let supportedArchitectures = [
        "iphoneos-arm", "iphoneos-arm64", "iphoneos-arm64e", "all", "arm64", "darwin-arm64"
    ]

    /// 仅在 dylib 同目录查找同 basename 的 plist；跨目录同名不自动猜测。
    public static func autoCompanionPlists(for dylibs: [URL]) -> [String: URL] {
        var result: [String: URL] = [:]
        for dylib in dylibs {
            let baseName = dylib.deletingPathExtension().lastPathComponent
            let candidate = dylib.deletingPathExtension().appendingPathExtension("plist")
            guard FileManager.default.fileExists(atPath: candidate.path),
                  !FileSystemHelper.isDirectory(candidate),
                  let data = try? Data(contentsOf: candidate),
                  (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil
            else { continue }
            result[baseName] = candidate
        }
        return result
    }

    public static func validate(metadata: DebPackageMetadata, layout: DebPackageLayout) throws {
        var messages: [String] = []
        let packageParts = metadata.packageID.split(separator: ".", omittingEmptySubsequences: false)
        let packagePartPattern = #"^[a-z0-9][a-z0-9+-]*$"#
        if packageParts.count < 2 || packageParts.contains(where: {
            $0.range(of: packagePartPattern, options: .regularExpression) == nil
        }) {
            messages.append(L("deb.validation.packageID"))
        }
        if metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(L("deb.validation.nameEmpty"))
        }
        if metadata.version.range(
            of: #"^[0-9][0-9A-Za-z.+:~_-]*$"#,
            options: .regularExpression
        ) == nil {
            messages.append(L("deb.validation.version"))
        }
        if !supportedArchitectures.contains(metadata.architecture) {
            messages.append(L("deb.validation.architectureUnsupported"))
        }
        if layout != .rootful && metadata.architecture == "iphoneos-arm" {
            messages.append(L("deb.validation.rootlessArchitecture"))
        }
        if layout == .roothide && metadata.architecture != "iphoneos-arm64e" {
            messages.append(L("deb.validation.roothideArchitecture"))
        }
        if metadata.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(L("deb.validation.descriptionEmpty"))
        }
        if metadata.maintainer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(L("deb.validation.maintainerEmpty"))
        }
        let singleLineValues = [
            ("Name", metadata.name), ("Architecture", metadata.architecture),
            ("Maintainer", metadata.maintainer), ("Author", metadata.author),
            ("Depends", metadata.depends), ("Section", metadata.section)
        ]
        for (field, value) in singleLineValues where value.contains("\n") || value.contains("\r") {
            messages.append(L("deb.validation.fieldNoNewline", field))
        }
        if !messages.isEmpty { throw DebValidationError(messages: messages) }
    }

    public static func renderControl(_ metadata: DebPackageMetadata) throws -> String {
        try validate(metadata: metadata, layout: metadata.architecture == "iphoneos-arm" ? .rootful : .rootless)
        var lines = [
            "Package: \(metadata.packageID)",
            "Name: \(metadata.name)",
            "Version: \(metadata.version)",
            "Architecture: \(metadata.architecture)"
        ]
        if !metadata.section.isEmpty { lines.append("Section: \(metadata.section)") }
        lines.append("Maintainer: \(metadata.maintainer)")
        if !metadata.author.isEmpty { lines.append("Author: \(metadata.author)") }
        if !metadata.depends.isEmpty {
            lines.append(contentsOf: foldedField(name: "Depends", value: metadata.depends))
        }
        lines.append(contentsOf: descriptionField(metadata.description))
        return lines.joined(separator: "\n") + "\n"
    }

    public static func renderFilterPlist(_ filter: TweakFilter) throws -> Data {
        var values: [String: Any] = [:]
        if !filter.bundles.isEmpty { values["Bundles"] = filter.bundles }
        if !filter.executables.isEmpty { values["Executables"] = filter.executables }
        if !filter.classes.isEmpty { values["Classes"] = filter.classes }
        if !filter.coreFoundationVersion.isEmpty {
            values["CoreFoundationVersion"] = filter.coreFoundationVersion
        }
        return try PropertyListSerialization.data(
            fromPropertyList: ["Filter": values],
            format: .xml,
            options: 0
        )
    }

    public static func plan(_ request: DebPackageRequest) throws -> DebBuildPlan {
        try validate(metadata: request.metadata, layout: request.layout)
        guard !request.dylibs.isEmpty || !request.extraResources.isEmpty else {
            throw DebValidationError(messages: [L("deb.validation.needsDylib")])
        }
        let automaticallyPaired = autoCompanionPlists(for: request.dylibs)
        let companionPlists = automaticallyPaired.merging(request.companionPlists) { _, explicit in explicit }

        let control = try renderControlForLayout(request.metadata, layout: request.layout)
        var entries: [DebPlannedEntry] = [
            DebPlannedEntry(
                relativePath: "DEBIAN/control",
                kind: .control,
                source: nil,
                size: Int64(control.utf8.count)
            )
        ]
        var destinationKeys: Set<String> = ["debian/control"]

        for dylib in request.dylibs {
            guard dylib.pathExtension.lowercased() == "dylib" else {
                throw DebValidationError(messages: [L("deb.validation.notDylib", dylib.lastPathComponent)])
            }
            guard FileManager.default.fileExists(atPath: dylib.path) else {
                throw DebValidationError(messages: [L("deb.validation.fileNotFound", dylib.path)])
            }
            if request.layout == .roothide,
               MachOInspector.facts(fileAt: dylib)?.archs.contains("arm64e") != true {
                throw DebValidationError(messages: [L("deb.validation.roothideNeedsArm64e", dylib.lastPathComponent)])
            }
            let baseName = dylib.deletingPathExtension().lastPathComponent
            let dylibPath = "\(request.layout.dynamicLibrariesPath)/\(dylib.lastPathComponent)"
            try appendEntry(
                DebPlannedEntry(relativePath: dylibPath, kind: .dylib, source: dylib, size: fileSize(dylib)),
                entries: &entries,
                destinationKeys: &destinationKeys
            )

            if let plist = companionPlists[baseName] {
                guard let plistData = try? Data(contentsOf: plist),
                      (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) != nil
                else {
                    throw DebValidationError(
                        messages: [L("deb.validation.invalidPlist", plist.lastPathComponent)]
                    )
                }
                let plistPath = "\(request.layout.dynamicLibrariesPath)/\(baseName).plist"
                try appendEntry(
                    DebPlannedEntry(relativePath: plistPath, kind: .filter, source: plist, size: fileSize(plist)),
                    entries: &entries,
                    destinationKeys: &destinationKeys
                )
            } else if let filter = request.generatedFilter {
                let data = try renderFilterPlist(filter)
                let plistPath = "\(request.layout.dynamicLibrariesPath)/\(baseName).plist"
                try appendEntry(
                    DebPlannedEntry(relativePath: plistPath, kind: .filter, source: nil, size: Int64(data.count)),
                    entries: &entries,
                    destinationKeys: &destinationKeys
                )
            }
        }

        for resource in request.extraResources {
            guard FileManager.default.fileExists(atPath: resource.path) else {
                throw DebValidationError(messages: [L("deb.validation.fileNotFound", resource.path)])
            }
            let ext = resource.pathExtension.lowercased()
            let destination: String
            let kind: DebPlannedEntryKind
            if ext == "framework" {
                destination = "\(request.layout.frameworksPath)/\(resource.lastPathComponent)"
                kind = .framework
            } else if ext == "bundle" {
                destination = "\(applicationSupportPath(request))/\(resource.lastPathComponent)"
                kind = .bundle
            } else {
                destination = "\(applicationSupportPath(request))/Resources/\(resource.lastPathComponent)"
                kind = .resource
            }
            try appendEntry(
                DebPlannedEntry(
                    relativePath: destination,
                    kind: kind,
                    source: resource,
                    size: fileSize(resource)
                ),
                entries: &entries,
                destinationKeys: &destinationKeys
            )
        }

        for script in DebMaintainerScript.allCases {
            guard let body = request.scripts[script], !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let normalized = normalizedScript(body)
            entries.append(
                DebPlannedEntry(
                    relativePath: "DEBIAN/\(script.rawValue)",
                    kind: .script,
                    source: nil,
                    size: Int64(normalized.utf8.count)
                )
            )
        }

        let sorted = entries.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return DebBuildPlan(
            controlText: control,
            entries: sorted,
            estimatedSize: sorted.reduce(0) { $0 + $1.size },
            tree: renderTree(paths: sorted.map(\.relativePath))
        )
    }

    @discardableResult
    public static func stage(_ request: DebPackageRequest, at root: URL) throws -> DebBuildPlan {
        let plan = try plan(request)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        for entry in plan.entries {
            let destination = root.appendingPathComponent(entry.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let source = entry.source {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source, to: destination)
                continue
            }
            switch entry.kind {
            case .control:
                try plan.controlText.write(to: destination, atomically: true, encoding: .utf8)
            case .filter:
                let baseName = destination.deletingPathExtension().lastPathComponent
                let filter = request.generatedFilter ?? TweakFilter()
                guard request.companionPlists[baseName] == nil else { continue }
                try renderFilterPlist(filter).write(to: destination)
            case .script:
                guard let script = DebMaintainerScript(rawValue: destination.lastPathComponent),
                      let body = request.scripts[script] else { continue }
                try normalizedScript(body).write(to: destination, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            default:
                break
            }
        }
        try convertMachOPaths(
            in: root,
            from: request.sourceLayout,
            to: request.layout
        )
        return plan
    }

    /// 将随包 Mach-O 中的越狱根路径转换为目标布局；roothide 使用随机 jbroot，不能写死绝对目录。
    private static func convertMachOPaths(
        in root: URL,
        from source: DebPackageLayout?,
        to target: DebPackageLayout
    ) throws {
        guard source != target else { return }
        let files = FileSystemHelper.allFiles(in: root) { MachOIdentifier.isMachO(fileAt: $0) }
        for file in files {
            let analyzed = try? DylibService.analyze(fileAt: file)
            if let installName = analyzed?.installName,
               let converted = convertedMachOPath(installName, from: source, to: target),
               converted != installName {
                try DylibService.setInstallID(converted, fileAt: file)
            }
            // `otool -L` includes LC_ID_DYLIB as its first entry.  Use the analyzed
            // dependency list so an install name is not treated as a dependency.
            for dependency in analyzed?.dependencies ?? [] {
                guard let converted = convertedMachOPath(
                    dependency.path,
                    from: source,
                    to: target
                ), converted != dependency.path else { continue }
                try DylibService.changeDependency(from: dependency.path, to: converted, fileAt: file)
            }
        }
    }

    private static func convertedMachOPath(
        _ path: String,
        from source: DebPackageLayout?,
        to target: DebPackageLayout
    ) -> String? {
        let layouts = source.map { [$0] } ?? [.roothide, .rootless, .rootful]
        for layout in layouts {
            guard let relative = relativeMachOPath(path, under: layout), isJailbreakPath(relative) else {
                continue
            }
            return target.machORootPrefix + relative
        }
        return nil
    }

    private static func relativeMachOPath(
        _ path: String,
        under layout: DebPackageLayout
    ) -> String? {
        let prefix = layout.machORootPrefix
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    private static func isJailbreakPath(_ relative: String) -> Bool {
        if relative.hasPrefix("Library/") { return true }
        guard relative.hasPrefix("usr/lib/") else { return false }
        let name = relative.lowercased()
        return DependencyClassifier.jailbreakRuntimeKeywords.contains(where: name.contains)
    }

    public static func build(_ request: DebPackageRequest, to output: URL) throws -> DebBuildResult {
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-wizard")
        defer { try? FileManager.default.removeItem(at: work) }
        let packageRoot = work.appendingPathComponent("package")
        let plan = try stage(request, at: packageRoot)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try repack(directory: packageRoot, to: output)

        if ExternalTool.dpkgDeb.isAvailable {
            let info = try ExternalTool.dpkgDeb.run(["--info", output.path])
            let contents = try ExternalTool.dpkgDeb.run(["--contents", output.path])
            let builtFileSize = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard info.succeeded, contents.succeeded, builtFileSize > 0 else {
                throw DebError.commandFailed(info.combinedOutput + "\n" + contents.combinedOutput)
            }
            return DebBuildResult(
                output: output,
                plan: plan,
                infoOutput: info.combinedOutput,
                contentsOutput: contents.combinedOutput
            )
        }

        let inspected = try inspect(debAt: output)
        guard inspected.control.package == request.metadata.packageID,
              !inspected.entries.isEmpty else {
            throw DebError.commandFailed(L("deb.error.arTarVerificationFailed"))
        }
        return DebBuildResult(
            output: output,
            plan: plan,
            infoOutput: inspected.control.rawText,
            contentsOutput: inspected.entries.map(\.path).joined(separator: "\n")
        )
    }

    /// 从已有 DEB 创建布局转换副本；源包保持只读，改动发生在私有工作区。
    public static func convert(
        debAt source: URL,
        from sourceLayout: DebPackageLayout,
        to targetLayout: DebPackageLayout,
        output: URL
    ) throws -> DebLayoutConversionResult {
        guard sourceLayout != targetLayout else {
            throw DebValidationError(messages: ["来源布局和目标布局相同"])
        }
        let workspace = try DebEditableWorkspaceService.create(from: source)
        try relocatePayload(in: workspace.stage, from: sourceLayout, to: targetLayout)
        try updateControlArchitecture(
            at: workspace.stage.appendingPathComponent("DEBIAN/control"),
            architecture: targetLayout.defaultArchitecture
        )
        try convertMachOPaths(in: workspace.stage, from: sourceLayout, to: targetLayout)
        let rebuilt = try DebEditableWorkspaceService.repack(workspace, to: output)
        return DebLayoutConversionResult(
            output: rebuilt.outputURL,
            sourceLayout: sourceLayout,
            targetLayout: targetLayout,
            sha256: rebuilt.sha256,
            changes: rebuilt.changes,
            verification: rebuilt.verification
        )
    }

    private static func relocatePayload(
        in stage: URL,
        from source: DebPackageLayout,
        to target: DebPackageLayout
    ) throws {
        guard source != target else { return }
        let fm = FileManager.default
        if source == .rootless {
            let jb = stage.appendingPathComponent("var/jb", isDirectory: true)
            guard fm.fileExists(atPath: jb.path) else {
                throw DebValidationError(messages: ["包内未找到 var/jb，来源布局与内容不一致"])
            }
            for item in try fm.contentsOfDirectory(at: jb, includingPropertiesForKeys: nil) {
                let destination = stage.appendingPathComponent(item.lastPathComponent)
                guard !fm.fileExists(atPath: destination.path) else {
                    throw DebValidationError(messages: ["转换目标路径冲突：\(item.lastPathComponent)"])
                }
                try fm.moveItem(at: item, to: destination)
            }
            try fm.removeItem(at: jb)
            let varDirectory = stage.appendingPathComponent("var")
            if (try? fm.contentsOfDirectory(atPath: varDirectory.path).isEmpty) == true {
                try fm.removeItem(at: varDirectory)
            }
        }
        if target == .rootless {
            let temporary = stage.deletingLastPathComponent()
                .appendingPathComponent("relocated-\(UUID().uuidString)")
            let jb = temporary.appendingPathComponent("var/jb", isDirectory: true)
            try fm.createDirectory(at: jb, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temporary) }
            for item in try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
            where item.lastPathComponent != "DEBIAN" {
                try fm.moveItem(at: item, to: jb.appendingPathComponent(item.lastPathComponent))
            }
            try fm.moveItem(
                at: temporary.appendingPathComponent("var"),
                to: stage.appendingPathComponent("var")
            )
        }
    }

    private static func updateControlArchitecture(at url: URL, architecture: String) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var found = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("Architecture:") else { return String(line) }
            found = true
            return "Architecture: \(architecture)"
        }
        guard found else { throw DebValidationError(messages: ["control 缺少 Architecture 字段"]) }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: 查看

    public static func inspect(debAt url: URL) throws -> DebInfo {
        if ExternalTool.dpkgDeb.isAvailable {
            let field = try ExternalTool.dpkgDeb.run(["-f", url.path])
            let contents = try ExternalTool.dpkgDeb.run(["-c", url.path])
            guard field.succeeded, contents.succeeded else {
                throw DebError.commandFailed(field.combinedOutput + "\n" + contents.combinedOutput)
            }
            let entries = parseDpkgContents(contents.stdout)
            _ = try ArchiveSafety.validateEntries(entries.map { ($0.path, $0.size ?? 0, $0.link) })
            return DebInfo(control: parseControl(field.stdout),
                           entries: entries,
                           usedDpkg: true)
        }

        let tmp = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-inspect")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let members = try extractArMembers(url, to: tmp)

        var control = DebControl(fields: [:], rawText: "")
        if let controlTar = members.first(where: { $0.lastPathComponent.hasPrefix("control.tar") }) {
            let controlDir = tmp.appendingPathComponent("control")
            try FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
            try validateTarArchive(controlTar)
            let extraction = try ExternalTool.tar.run(["-xf", controlTar.path, "-C", controlDir.path])
            guard extraction.succeeded else { throw DebError.commandFailed(extraction.combinedOutput) }
            let controlFile = controlDir.appendingPathComponent("control")
            if let text = try? String(contentsOf: controlFile, encoding: .utf8) {
                control = parseControl(text)
            }
        }

        var entries: [DebEntry] = []
        if let dataTar = members.first(where: { $0.lastPathComponent.hasPrefix("data.tar") }) {
            let list = try ExternalTool.tar.run(["-tvf", dataTar.path])
            guard list.succeeded else { throw DebError.commandFailed(list.combinedOutput) }
            entries = parseTarVerbose(list.stdout)
            _ = try ArchiveSafety.validateEntries(entries.map { ($0.path, $0.size ?? 0, $0.link) })
        }
        return DebInfo(control: control, entries: entries, usedDpkg: false)
    }

    // MARK: 解包

    /// 解包 .deb 到目标目录。
    /// - Parameter dataOnly: true 只解 data(文件系统);false 同时解出控制脚本到 `DEBIAN/`。
    @discardableResult
    public static func extract(debAt url: URL, to destination: URL, dataOnly: Bool = false) throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            guard existing.isEmpty else { throw DebError.outputExists(destination.path) }
            try FileManager.default.removeItem(at: destination)
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".deb-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: staging) } // 失败时清理半成品。

        if ExternalTool.dpkgDeb.isAvailable {
            let listing = try ExternalTool.dpkgDeb.run(["-c", url.path])
            guard listing.succeeded else { throw DebError.commandFailed(listing.combinedOutput) }
            let entries = parseDpkgContents(listing.stdout)
            _ = try ArchiveSafety.validateEntries(entries.map { ($0.path, $0.size ?? 0, $0.link) })
            let result = dataOnly
                ? try ExternalTool.dpkgDeb.run(["-x", url.path, staging.path])
                : try ExternalTool.dpkgDeb.run(["-R", url.path, staging.path])
            guard result.succeeded else { throw DebError.commandFailed(result.combinedOutput) }
            try FileManager.default.moveItem(at: staging, to: destination)
            return destination
        }

        let tmp = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-extract")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let members = try extractArMembers(url, to: tmp)

        guard let dataTar = members.first(where: { $0.lastPathComponent.hasPrefix("data.tar") }) else {
            throw DebError.missingMember("data.tar")
        }
        try validateTarArchive(dataTar)
        let untar = try ExternalTool.tar.run(["-xf", dataTar.path, "-C", staging.path])
        guard untar.succeeded else { throw DebError.commandFailed(untar.combinedOutput) }

        if !dataOnly, let controlTar = members.first(where: { $0.lastPathComponent.hasPrefix("control.tar") }) {
            try validateTarArchive(controlTar)
            let debianDir = staging.appendingPathComponent("DEBIAN")
            try FileManager.default.createDirectory(at: debianDir, withIntermediateDirectories: true)
            let controlResult = try ExternalTool.tar.run(["-xf", controlTar.path, "-C", debianDir.path])
            guard controlResult.succeeded else { throw DebError.commandFailed(controlResult.combinedOutput) }
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    // MARK: 重新打包

    /// 将一个包含 `DEBIAN/control` 的目录重新打包为 .deb。
    @discardableResult
    public static func repack(directory: URL, to output: URL, compression: String = "gzip") throws -> URL {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw DebError.outputExists(output.path)
        }
        let temporaryOutput = output.deletingLastPathComponent()
            .appendingPathComponent(".deb-build-\(UUID().uuidString).deb")
        defer { try? FileManager.default.removeItem(at: temporaryOutput) } // 失败时清理半成品。
        if ExternalTool.dpkgDeb.isAvailable {
            let preferred = try ExternalTool.dpkgDeb.run([
                "-Z\(compression)", "--root-owner-group", "--build", directory.path, temporaryOutput.path
            ])
            if preferred.succeeded {
                try FileManager.default.moveItem(at: temporaryOutput, to: output)
                return output
            }

            let lower = preferred.combinedOutput.lowercased()
            guard lower.contains("unknown option")
                    || lower.contains("unrecognized option")
                    || lower.contains("illegal option")
            else {
                throw DebError.commandFailed(preferred.combinedOutput)
            }
            let compatible = try ExternalTool.dpkgDeb.run([
                "-Z\(compression)", "--build", directory.path, temporaryOutput.path
            ])
            guard compatible.succeeded else {
                throw DebError.commandFailed(
                    preferred.combinedOutput + "\n" + L("deb.error.compatibilityModeLabel") + "\n"
                        + compatible.combinedOutput
                )
            }
            try FileManager.default.moveItem(at: temporaryOutput, to: output)
            return output
        }
        _ = try repackWithArTar(directory: directory, to: temporaryOutput)
        try FileManager.default.moveItem(at: temporaryOutput, to: output)
        return output
    }

    // MARK: 从 deb 中提取 Mach-O / dylib

    /// 解包 deb 后,返回其中所有 Mach-O 文件(常用于提取 dylib)。
    public static func machOFiles(inDebAt url: URL) throws -> (root: URL, files: [URL]) {
        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-macho")
        try extract(debAt: url, to: dir, dataOnly: true)
        let files = FileSystemHelper.allFiles(in: dir) { MachOIdentifier.isMachO(fileAt: $0) }
        return (dir, files)
    }

    /// 返回包内实际存在的维护脚本清单。只检测**存在性**,绝不读取或执行脚本内容——
    /// 「不执行维护脚本」是本应用的既有安全边界。
    public static func presentMaintainerScripts(debAt url: URL) throws -> [DebMaintainerScript] {
        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-ctrl")
        defer { try? FileManager.default.removeItem(at: dir) }
        let extracted = dir.appendingPathComponent("payload", isDirectory: true)
        try extract(debAt: url, to: extracted, dataOnly: false)
        let debian = extracted.appendingPathComponent("DEBIAN", isDirectory: true)
        return DebMaintainerScript.allCases.filter {
            FileManager.default.fileExists(
                atPath: debian.appendingPathComponent($0.rawValue).path
            )
        }
    }

    // MARK: - 内部实现

    private static func renderControlForLayout(
        _ metadata: DebPackageMetadata,
        layout: DebPackageLayout
    ) throws -> String {
        try validate(metadata: metadata, layout: layout)
        var lines = [
            "Package: \(metadata.packageID)",
            "Name: \(metadata.name)",
            "Version: \(metadata.version)",
            "Architecture: \(metadata.architecture)"
        ]
        if !metadata.section.isEmpty { lines.append("Section: \(metadata.section)") }
        lines.append("Maintainer: \(metadata.maintainer)")
        if !metadata.author.isEmpty { lines.append("Author: \(metadata.author)") }
        if !metadata.depends.isEmpty {
            lines.append(contentsOf: foldedField(name: "Depends", value: metadata.depends))
        }
        lines.append(contentsOf: descriptionField(metadata.description))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func foldedField(name: String, value: String, width: Int = 78) -> [String] {
        let pieces = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var lines: [String] = []
        var current = "\(name):"
        for (index, piece) in pieces.enumerated() {
            let token = (index == pieces.count - 1 ? piece : piece + ",")
            if current.count + token.count + 1 > width, current != "\(name):" {
                lines.append(current)
                current = " \(token)"
            } else {
                current += " \(token)"
            }
        }
        lines.append(current)
        return lines
    }

    private static func descriptionField(_ value: String) -> [String] {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let sourceLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let summary = sourceLines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var lines = ["Description: \(summary)"]
        for line in sourceLines.dropFirst() {
            lines.append(line.isEmpty ? " ." : " " + line)
        }
        return lines
    }

    private static func appendEntry(
        _ entry: DebPlannedEntry,
        entries: inout [DebPlannedEntry],
        destinationKeys: inout Set<String>
    ) throws {
        guard !entry.relativePath.hasPrefix("/"),
              !entry.relativePath.split(separator: "/").contains("..")
        else {
            throw DebValidationError(messages: [L("deb.validation.illegalPackagePath", entry.relativePath)])
        }
        let key = entry.relativePath.lowercased()
        guard !destinationKeys.contains(key) else {
            throw DebValidationError(messages: [L("deb.validation.duplicatePackagePath", entry.relativePath)])
        }
        destinationKeys.insert(key)
        entries.append(entry)
    }

    private static func applicationSupportPath(_ request: DebPackageRequest) -> String {
        let prefix = request.layout.packagePrefix
        let base = prefix.isEmpty ? "Library/Application Support" : "\(prefix)/Library/Application Support"
        return "\(base)/\(safePathComponent(request.metadata.name))"
    }

    private static func safePathComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
            .union(.newlines)
            .union(.controlCharacters)
        let components = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        let result = components.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "TweakResources" : result
    }

    private static func fileSize(_ url: URL) -> Int64 {
        FileSystemHelper.size(at: url)
    }

    private static func normalizedScript(_ body: String) -> String {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if !text.hasPrefix("#!") { text = "#!/bin/sh\n" + text }
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    private static func renderTree(paths: [String]) -> String {
        var seen: Set<String> = []
        var lines = ["package/"]
        for path in paths.sorted() {
            let components = path.split(separator: "/").map(String.init)
            var partial = ""
            for (index, component) in components.enumerated() {
                partial = partial.isEmpty ? component : "\(partial)/\(component)"
                guard !seen.contains(partial) else { continue }
                seen.insert(partial)
                let isFile = index == components.count - 1
                lines.append(
                    String(repeating: "  ", count: index + 1)
                    + (isFile ? "└── " : "├── ")
                    + component
                    + (isFile ? "" : "/")
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func extractArMembers(_ url: URL, to dir: URL) throws -> [URL] {
        let table = try ExternalTool.ar.run(["t", url.path])
        guard table.succeeded else { throw DebError.commandFailed(table.combinedOutput) }
        let names = table.stdout.split(separator: "\n").map(String.init)
        _ = try ArchiveSafety.validateEntries(names.map { ($0, 0, nil) })
        let result = try ExternalTool.ar.run(["x", url.path], currentDirectory: dir)
        guard result.succeeded else { throw DebError.commandFailed(result.combinedOutput) }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    }

    private static func validateTarArchive(_ url: URL) throws {
        let listing = try ExternalTool.tar.run(["-tvf", url.path])
        guard listing.succeeded else { throw DebError.commandFailed(listing.combinedOutput) }
        let entries = parseTarVerbose(listing.stdout)
        guard !entries.isEmpty else { throw DebError.commandFailed(L("deb.error.tarEmptyOrUnparsable")) }
        _ = try ArchiveSafety.validateEntries(entries.map { ($0.path, $0.size ?? 0, $0.link) })
    }

    private static func repackWithArTar(directory: URL, to output: URL) throws -> URL {
        let tmp = try FileSystemHelper.makeTemporaryDirectory(prefix: "deb-repack")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let debianDir = directory.appendingPathComponent("DEBIAN")
        guard FileSystemHelper.isDirectory(debianDir) else {
            throw DebError.missingMember("DEBIAN/control")
        }

        let debianBinary = tmp.appendingPathComponent("debian-binary")
        try "2.0\n".write(to: debianBinary, atomically: true, encoding: .utf8)

        let controlTar = tmp.appendingPathComponent("control.tar.gz")
        let controlResult = try ExternalTool.tar.run([
            "--numeric-owner", "-czf", controlTar.path, "-C", debianDir.path, "."
        ])
        guard controlResult.succeeded else { throw DebError.commandFailed(controlResult.combinedOutput) }

        let dataTar = tmp.appendingPathComponent("data.tar.gz")
        let dataResult = try ExternalTool.tar.run([
            "--numeric-owner", "--exclude", "./DEBIAN", "-czf", dataTar.path, "-C", directory.path, "."
        ])
        guard dataResult.succeeded else { throw DebError.commandFailed(dataResult.combinedOutput) }

        // Debian 要求成员顺序:debian-binary, control.tar.*, data.tar.*
        let arResult = try ExternalTool.ar.run([
            "rc", output.path, debianBinary.path, controlTar.path, dataTar.path
        ])
        guard arResult.succeeded else { throw DebError.commandFailed(arResult.combinedOutput) }
        return output
    }

    // MARK: - 解析

    static func parseControl(_ text: String) -> DebControl {
        var fields: [String: String] = [:]
        var currentKey: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.first == " " || line.first == "\t" {
                if let key = currentKey {
                    fields[key, default: ""] += "\n" + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fields[key] = value
            currentKey = key
        }
        return DebControl(fields: fields, rawText: text)
    }

    /// 解析 `dpkg-deb -c` 输出。
    static func parseDpkgContents(_ text: String) -> [DebEntry] {
        text.split(separator: "\n").compactMap { line -> DebEntry? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 6 else { return nil }
            let mode = parts[0]
            let size = Int64(parts[2])
            let pathParts = parts[5...].joined(separator: " ")
            var path = pathParts
            var link: String?
            if let range = pathParts.range(of: " -> ") {
                path = String(pathParts[..<range.lowerBound])
                link = String(pathParts[range.upperBound...])
            }
            return DebEntry(path: path, size: size, isDirectory: mode.first == "d", link: link, mode: mode)
        }
    }

    /// 解析 `tar -tvf` 输出。
    static func parseTarVerbose(_ text: String) -> [DebEntry] {
        text.split(separator: "\n").compactMap { line -> DebEntry? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 6 else { return nil }
            let mode = parts[0]
            let isBSD = Int(parts[1]) != nil
            let sizeIndex = isBSD ? 4 : 2
            let pathIndex = isBSD ? 8 : 5
            guard parts.indices.contains(sizeIndex), parts.indices.contains(pathIndex),
                  let size = Int64(parts[sizeIndex]) else { return nil }
            let pathParts = parts[pathIndex...].joined(separator: " ")
            var path = pathParts
            var link: String?
            if let range = pathParts.range(of: " -> ") {
                path = String(pathParts[..<range.lowerBound])
                link = String(pathParts[range.upperBound...])
            }
            return DebEntry(path: path, size: size, isDirectory: mode.first == "d", link: link, mode: mode)
        }
    }
}

public enum DebError: LocalizedError {
    case commandFailed(String)
    case missingMember(String)
    case outputExists(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(output): return L("deb.error.commandFailed", output)
        case let .missingMember(name): return L("deb.error.missingMember", name)
        case let .outputExists(path): return L("deb.error.outputExists", path)
        }
    }
}
