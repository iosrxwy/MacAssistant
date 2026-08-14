import Foundation

// MARK: - Objective-C 类型编码解码

/// 把 Objective-C 方法/ivar 的类型编码(如 `v16@0:8`)解码为可读类型。
public enum ObjCTypeDecoder {

    /// 解码整串编码为类型列表(方法编码首项为返回值,随后是 self/SEL/各参数)。
    public static func types(from encoding: String) -> [String] {
        let chars = Array(encoding)
        var i = 0
        var result: [String] = []
        while i < chars.count {
            if chars[i].isNumber { i += 1; continue }   // 跳过栈偏移数字
            let (type, next) = decode(chars, i)
            result.append(type)
            i = max(next, i + 1)
        }
        return result
    }

    /// 解码单个类型 token,返回类型字符串与下一个位置。
    public static func decode(_ c: [Character], _ start: Int) -> (String, Int) {
        var i = start
        guard i < c.count else { return ("void", i) }

        // 限定符前缀
        var constPrefix = ""
        while i < c.count, "rnNoORV".contains(c[i]) {
            if c[i] == "r" { constPrefix = "const " }
            i += 1
        }
        guard i < c.count else { return (constPrefix + "void", i) }

        switch c[i] {
        case "c": return (constPrefix + "char", i + 1)
        case "i": return (constPrefix + "int", i + 1)
        case "s": return (constPrefix + "short", i + 1)
        case "l": return (constPrefix + "long", i + 1)
        case "q": return (constPrefix + "long long", i + 1)
        case "C": return (constPrefix + "unsigned char", i + 1)
        case "I": return (constPrefix + "unsigned int", i + 1)
        case "S": return (constPrefix + "unsigned short", i + 1)
        case "L": return (constPrefix + "unsigned long", i + 1)
        case "Q": return (constPrefix + "unsigned long long", i + 1)
        case "f": return (constPrefix + "float", i + 1)
        case "d": return (constPrefix + "double", i + 1)
        case "B": return (constPrefix + "BOOL", i + 1)
        case "v": return (constPrefix + "void", i + 1)
        case "*": return (constPrefix + "char *", i + 1)
        case ":": return ("SEL", i + 1)
        case "#": return ("Class", i + 1)
        case "@":
            // @"ClassName" / @? (block)
            if i + 1 < c.count, c[i + 1] == "\"" {
                var j = i + 2
                var name = ""
                while j < c.count, c[j] != "\"" { name.append(c[j]); j += 1 }
                return (name.isEmpty ? "id" : name + " *", j + 1)
            }
            if i + 1 < c.count, c[i + 1] == "?" { return ("id /* block */", i + 2) }
            return ("id", i + 1)
        case "^":
            let (inner, next) = decode(c, i + 1)
            return (inner + " *", next)
        case "{", "(":
            let open = c[i], close: Character = (open == "{") ? "}" : ")"
            var depth = 0
            var j = i
            var name = ""
            var readingName = true
            while j < c.count {
                if c[j] == open { depth += 1; if depth == 1 { j += 1; continue } }
                if c[j] == close { depth -= 1; if depth == 0 { j += 1; break } }
                if depth == 1 {
                    if c[j] == "=" { readingName = false }
                    else if readingName { name.append(c[j]) }
                }
                j += 1
            }
            let kw = (open == "{") ? "struct" : "union"
            let cleaned = name == "?" || name.isEmpty ? "" : " " + name
            return ("\(kw)\(cleaned)", j)
        case "[":
            var j = i + 1
            var count = ""
            while j < c.count, c[j].isNumber { count.append(c[j]); j += 1 }
            let (inner, next) = decode(c, j)
            j = next
            if j < c.count, c[j] == "]" { j += 1 }
            return ("\(inner)[\(count)]", j)
        case "b":
            var j = i + 1
            while j < c.count, c[j].isNumber { j += 1 }
            return ("unsigned int", j)
        case "?":
            return ("void", i + 1)
        default:
            return (String(c[i]), i + 1)
        }
    }

    /// 由 selector + 类型编码生成方法声明,如 `- (void)setName:(id)arg1;`。
    public static func methodDeclaration(selector: String, typeEncoding: String, isClassMethod: Bool) -> String {
        let prefix = isClassMethod ? "+" : "-"
        let types = types(from: typeEncoding)
        let returnType = types.first ?? "id"
        // types[0]=return, [1]=self(@), [2]=SEL(:), [3...]=args
        let argTypes = types.count > 3 ? Array(types[3...]) : []

        if !selector.contains(":") {
            return "\(prefix) (\(returnType))\(selector);"
        }
        let parts = selector.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // parts 末尾通常是空串
        var pieces: [String] = []
        var argIndex = 0
        for part in parts where !part.isEmpty || argIndex < argTypes.count {
            if part.isEmpty && argIndex >= argTypes.count { break }
            let argType = argIndex < argTypes.count ? argTypes[argIndex] : "id"
            pieces.append("\(part):(\(argType))arg\(argIndex + 1)")
            argIndex += 1
        }
        return "\(prefix) (\(returnType))\(pieces.joined(separator: " "));"
    }
}

// MARK: - 方法列表解析(传统指针格式)

public struct ObjCMethod: Sendable, Hashable {
    public let selector: String
    public let typeEncoding: String
    public let isClassMethod: Bool
    public var declaration: String {
        ObjCTypeDecoder.methodDeclaration(selector: selector, typeEncoding: typeEncoding, isClassMethod: isClassMethod)
    }
}

public struct ObjCProperty: Sendable, Hashable {
    public let name: String
    public let attributes: String
    public var declaration: String {
        ObjCPropertyDecoder.declaration(name: name, attributes: attributes)
    }
}

public enum ObjCPropertyDecoder {
    public static func declaration(name: String, attributes: String) -> String {
        let fields = attributes.split(separator: ",").map(String.init)
        let typeEncoding = fields.first(where: { $0.hasPrefix("T") }).map { String($0.dropFirst()) } ?? "@"
        let type = ObjCTypeDecoder.types(from: typeEncoding).first ?? "id"
        var modifiers: [String] = []
        for field in fields.dropFirst() {
            switch field {
            case "R": modifiers.append("readonly")
            case "C": modifiers.append("copy")
            case "&": modifiers.append("strong")
            case "W": modifiers.append("weak")
            case "N": modifiers.append("nonatomic")
            case "D": modifiers.append("dynamic")
            default:
                if field.hasPrefix("G") { modifiers.append("getter=\(field.dropFirst())") }
                if field.hasPrefix("S") { modifiers.append("setter=\(field.dropFirst())") }
            }
        }
        let attributesText = modifiers.isEmpty ? "" : " (\(modifiers.joined(separator: ", ")))"
        let spacing = type.hasSuffix("*") ? "" : " "
        return "@property\(attributesText) \(type)\(spacing)\(name);"
    }
}

public enum ObjCRuntime {
    public static func isRelativeMethodList(_ b: [UInt8], at offset: Int, le: Bool) -> Bool {
        guard offset >= 0, offset + 4 <= b.count else { return false }
        return (MachOInspector.readU32(b, offset, le) & 0x8000_0000) != 0
    }

    /// 解析 64 位「传统指针格式」method_list_t。
    /// - Parameters:
    ///   - listOffset: method_list_t 在缓冲区中的绝对偏移。
    ///   - resolvePointer: 把一个 vmaddr 指针解析成字符串(用于 SEL/types)。
    public static func parseMethodListTraditional(
        _ b: [UInt8], at listOffset: Int, le: Bool, isClassMethod: Bool,
        resolvePointer: (UInt64) -> String?
    ) -> [ObjCMethod] {
        guard listOffset + 8 <= b.count else { return [] }
        let entsize = Int(MachOInspector.readU32(b, listOffset, le) & 0x0000_FFFF)
        let count = Int(MachOInspector.readU32(b, listOffset + 4, le))
        let isRelative = isRelativeMethodList(b, at: listOffset, le: le)
        guard !isRelative, entsize >= 24, count > 0, count < 100_000 else { return [] }

        var methods: [ObjCMethod] = []
        var p = listOffset + 8
        for _ in 0..<count {
            guard p + 24 <= b.count else { break }
            let namePtr = MachOInspector.readU64(b, p, le)
            let typePtr = MachOInspector.readU64(b, p + 8, le)
            let sel = resolvePointer(namePtr) ?? ""
            let types = resolvePointer(typePtr) ?? ""
            if !sel.isEmpty {
                methods.append(ObjCMethod(selector: sel, typeEncoding: types, isClassMethod: isClassMethod))
            }
            p += entsize
        }
        return methods
    }
}

// MARK: - 原生 ObjC 元数据遍历

struct NativeObjCParseResult {
    var classes: [ObjCClass]
    var skippedCount: Int
    var skipReasons: [String]
}

public struct ObjCClass: Sendable {
    public var name: String
    public var superName: String?
    public var protocols: [String]
    public var instanceMethods: [ObjCMethod]
    public var classMethods: [ObjCMethod]
    public var ivars: [(type: String, name: String)]
    public var properties: [ObjCProperty]

    public init(name: String, superName: String?, instanceMethods: [ObjCMethod],
                classMethods: [ObjCMethod], ivars: [(type: String, name: String)],
                protocols: [String] = [], properties: [ObjCProperty] = []) {
        self.name = name
        self.superName = superName
        self.protocols = protocols
        self.instanceMethods = instanceMethods
        self.classMethods = classMethods
        self.ivars = ivars
        self.properties = properties
    }

    public func header() -> String {
        let protocolText = protocols.isEmpty ? "" : " <\(protocols.joined(separator: ", "))>"
        var lines = ["@interface \(name)\(superName.map { " : \($0)" } ?? "")\(protocolText)"]
        if !ivars.isEmpty {
            lines.append("{")
            for iv in ivars { lines.append("    \(iv.type) \(iv.name);") }
            lines.append("}")
        }
        lines.append(contentsOf: properties.map(\.declaration))
        lines.append(contentsOf: classMethods.map { $0.declaration })
        lines.append(contentsOf: instanceMethods.map { $0.declaration })
        lines.append("@end")
        return lines.joined(separator: "\n")
    }
}

/// 未加密、传统指针格式的 arm64/x86_64 二进制的 ObjC 元数据遍历器(尽力而为)。
struct NativeObjCParser {
    let b: [UInt8]
    let le: Bool
    let sliceOffset: Int
    let segments: [MachOSegment]

    func fileOffset(forVMAddr vmaddr: UInt64) -> Int? {
        guard vmaddr != 0 else { return nil }
        for seg in segments where seg.filesize > 0 {
            if vmaddr >= seg.vmaddr, vmaddr < seg.vmaddr + seg.filesize {
                return sliceOffset + Int(seg.fileoff + (vmaddr - seg.vmaddr))
            }
        }
        return nil
    }

    func readPtr(atVMAddr vmaddr: UInt64) -> UInt64? {
        guard let off = fileOffset(forVMAddr: vmaddr), off + 8 <= b.count else { return nil }
        return MachOInspector.readU64(b, off, le)
    }

    func cString(atVMAddr vmaddr: UInt64) -> String? {
        guard let off = fileOffset(forVMAddr: vmaddr), off < b.count else { return nil }
        return MachOInspector.cString(b, off, max: 4096)
    }

    func section(_ seg: String, _ sect: String) -> MachOSection? {
        for s in segments {
            for x in s.sections where x.segname == seg && x.sectname == sect { return x }
        }
        // sectname 唯一时忽略段名匹配
        for s in segments { for x in s.sections where x.sectname == sect { return x } }
        return nil
    }

    mutating func parse() -> NativeObjCParseResult {
        guard let listSect = section("__DATA", "__objc_classlist")
                ?? section("__DATA_CONST", "__objc_classlist") else {
            return NativeObjCParseResult(
                classes: [],
                skippedCount: 0,
                skipReasons: [L("classdump.skip.noClassList")]
            )
        }
        let base = sliceOffset + Int(listSect.offset)
        let n = Int(listSect.size / 8)
        guard n > 0, n < 200_000 else {
            return NativeObjCParseResult(
                classes: [],
                skippedCount: 0,
                skipReasons: [L("classdump.skip.emptyClassList")]
            )
        }
        var classes: [ObjCClass] = []
        var skippedCount = 0
        var skipReasons: [String] = []
        for i in 0..<n {
            let p = base + i * 8
            guard p + 8 <= b.count else { break }
            let classVM = MachOInspector.readU64(b, p, le)
            if let parsedClass = parseClass(atVMAddr: classVM) {
                classes.append(parsedClass.value)
                skippedCount += parsedClass.skippedCount
                skipReasons.append(contentsOf: parsedClass.skipReasons)
            } else {
                skippedCount += 1
                skipReasons.append(L("classdump.skip.unresolvableClassPointer"))
            }
        }
        return NativeObjCParseResult(
            classes: classes,
            skippedCount: skippedCount,
            skipReasons: Array(Set(skipReasons)).sorted()
        )
    }

    private func classRO(ofClassVM classVM: UInt64) -> Int? {
        guard let classOff = fileOffset(forVMAddr: classVM), classOff + 40 <= b.count else { return nil }
        let dataVM = MachOInspector.readU64(b, classOff + 32, le) & ~UInt64(0x7)
        return fileOffset(forVMAddr: dataVM)
    }

    private func parseClass(atVMAddr classVM: UInt64) -> (value: ObjCClass, skippedCount: Int, skipReasons: [String])? {
        guard let classOff = fileOffset(forVMAddr: classVM), classOff + 40 <= b.count else { return nil }
        let superVM = MachOInspector.readU64(b, classOff + 8, le)
        guard let roOff = classRO(ofClassVM: classVM), roOff + 72 <= b.count else { return nil }

        let nameVM = MachOInspector.readU64(b, roOff + 24, le)
        guard let name = cString(atVMAddr: nameVM), !name.isEmpty else { return nil }

        var superName: String?
        if superVM != 0, let sOff = classRO(ofClassVM: superVM), sOff + 32 <= b.count {
            superName = cString(atVMAddr: MachOInspector.readU64(b, sOff + 24, le))
        }

        let instance = methods(atVMAddr: MachOInspector.readU64(b, roOff + 32, le), isClass: false)
        let protocols = parseProtocols(atVMAddr: MachOInspector.readU64(b, roOff + 40, le))
        let ivars = parseIvars(atVMAddr: MachOInspector.readU64(b, roOff + 48, le))
        let properties = parseProperties(atVMAddr: MachOInspector.readU64(b, roOff + 64, le))

        // 元类的方法即类方法
        let isaVM = MachOInspector.readU64(b, classOff, le)
        var classMethods = (methods: [ObjCMethod](), skippedCount: 0, reason: String?.none)
        if let metaRO = classRO(ofClassVM: isaVM), metaRO + 40 <= b.count {
            classMethods = methods(atVMAddr: MachOInspector.readU64(b, metaRO + 32, le), isClass: true)
        }

        let reasons = [instance.reason, classMethods.reason].compactMap { $0 }
        return (
            ObjCClass(name: name, superName: superName,
                      instanceMethods: instance.methods, classMethods: classMethods.methods, ivars: ivars,
                      protocols: protocols, properties: properties),
            instance.skippedCount + classMethods.skippedCount,
            reasons
        )
    }

    private func methods(atVMAddr listVM: UInt64, isClass: Bool) -> (methods: [ObjCMethod], skippedCount: Int, reason: String?) {
        guard listVM != 0 else { return ([], 0, nil) }
        guard let off = fileOffset(forVMAddr: listVM), off + 8 <= b.count else {
            return ([], 1, L("classdump.skip.unresolvableMethodListPointer"))
        }
        let count = Int(MachOInspector.readU32(b, off + 4, le))
        if ObjCRuntime.isRelativeMethodList(b, at: off, le: le) {
            return ([], max(1, count), L("classdump.skip.relativeMethodList"))
        }
        let parsed = ObjCRuntime.parseMethodListTraditional(b, at: off, le: le, isClassMethod: isClass) { ptr in
            self.cString(atVMAddr: ptr)
        }
        let skipped = max(0, count - parsed.count)
        return (parsed, skipped, skipped > 0 ? L("classdump.skip.partialTraditionalMethods") : nil)
    }

    private func parseIvars(atVMAddr listVM: UInt64) -> [(type: String, name: String)] {
        guard listVM != 0, let off = fileOffset(forVMAddr: listVM), off + 8 <= b.count else { return [] }
        let entsize = Int(MachOInspector.readU32(b, off, le))
        let count = Int(MachOInspector.readU32(b, off + 4, le))
        guard entsize >= 32, count > 0, count < 100_000 else { return [] }
        var result: [(String, String)] = []
        var p = off + 8
        for _ in 0..<count {
            guard p + 32 <= b.count else { break }
            let nameVM = MachOInspector.readU64(b, p + 8, le)
            let typeVM = MachOInspector.readU64(b, p + 16, le)
            let name = cString(atVMAddr: nameVM) ?? ""
            let enc = cString(atVMAddr: typeVM) ?? "@"
            let type = ObjCTypeDecoder.types(from: enc).first ?? "id"
            if !name.isEmpty { result.append((type, name)) }
            p += entsize
        }
        return result
    }

    private func parseProperties(atVMAddr listVM: UInt64) -> [ObjCProperty] {
        guard listVM != 0, let off = fileOffset(forVMAddr: listVM), off + 8 <= b.count else { return [] }
        let entsize = Int(MachOInspector.readU32(b, off, le) & 0x0000_FFFF)
        let count = Int(MachOInspector.readU32(b, off + 4, le))
        guard entsize >= 16, count > 0, count < 100_000 else { return [] }
        var result: [ObjCProperty] = []
        var p = off + 8
        for _ in 0..<count {
            guard p + 16 <= b.count else { break }
            let name = cString(atVMAddr: MachOInspector.readU64(b, p, le)) ?? ""
            let attributes = cString(atVMAddr: MachOInspector.readU64(b, p + 8, le)) ?? ""
            if !name.isEmpty {
                result.append(ObjCProperty(name: name, attributes: attributes))
            }
            p += entsize
        }
        return result
    }

    private func parseProtocols(atVMAddr listVM: UInt64) -> [String] {
        guard listVM != 0, let off = fileOffset(forVMAddr: listVM), off + 8 <= b.count else { return [] }
        let count = Int(MachOInspector.readU64(b, off, le))
        guard count > 0, count < 100_000 else { return [] }
        var result: [String] = []
        for index in 0..<count {
            let entry = off + 8 + index * 8
            guard entry + 8 <= b.count else { break }
            let protocolVM = MachOInspector.readU64(b, entry, le)
            guard let protocolOff = fileOffset(forVMAddr: protocolVM), protocolOff + 16 <= b.count else { continue }
            let nameVM = MachOInspector.readU64(b, protocolOff + 8, le)
            if let name = cString(atVMAddr: nameVM), !name.isEmpty {
                result.append(name)
            }
        }
        return result
    }
}

// MARK: - ClassDumpService

public enum ClassDumpError: LocalizedError {
    case notMachO
    case encrypted
    case unsupportedBuiltIn(String)
    case needsExternalTool(String)
    case noExternalTool(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notMachO: return L("classdump.error.notMachO")
        case .encrypted: return L("classdump.error.encrypted")
        case let .unsupportedBuiltIn(reason): return L("classdump.error.unsupportedBuiltIn", reason)
        case let .needsExternalTool(reason): return L("classdump.error.needsExternalTool", reason)
        case let .noExternalTool(hint): return L("classdump.error.noExternalTool", hint)
        case let .commandFailed(out): return L("classdump.error.commandFailed", out)
        }
    }
}

public struct ClassHeader: Sendable, Hashable {
    public let name: String
    public let contents: String

    public init(name: String, contents: String) {
        self.name = name
        self.contents = contents
    }
}

public enum ClassDumpCompleteness: String, Sendable, Equatable {
    case complete = "完整"
    case partial = "部分"
    case unsupported = "不支持"
}

public struct ClassDumpCapabilityReport: Sendable, Equatable {
    public let architectures: [String]
    public let isEncrypted: Bool
    public let hasChainedFixups: Bool
    public let discoveredClassCount: Int
    public let exportedClassCount: Int
    public let methodCount: Int
    public let propertyCount: Int
    public let protocolCount: Int
    public let skippedCount: Int
    public let skipReasons: [String]
    public let coverage: Double
    public let completeness: ClassDumpCompleteness

    public init(
        architectures: [String],
        isEncrypted: Bool,
        hasChainedFixups: Bool,
        discoveredClassCount: Int,
        exportedClassCount: Int,
        methodCount: Int,
        propertyCount: Int,
        protocolCount: Int,
        skippedCount: Int,
        skipReasons: [String],
        coverage: Double,
        completeness: ClassDumpCompleteness
    ) {
        self.architectures = architectures
        self.isEncrypted = isEncrypted
        self.hasChainedFixups = hasChainedFixups
        self.discoveredClassCount = discoveredClassCount
        self.exportedClassCount = exportedClassCount
        self.methodCount = methodCount
        self.propertyCount = propertyCount
        self.protocolCount = protocolCount
        self.skippedCount = skippedCount
        self.skipReasons = skipReasons
        self.coverage = coverage
        self.completeness = completeness
    }
}

public struct HeaderDumpResult: Sendable {
    public var headers: String
    public var classNames: [String]
    public var classHeaders: [ClassHeader]
    public var usedExternalTool: ExternalTool?
    public var warnings: [String]
    public var facts: MachOFacts
    public var capabilityReport: ClassDumpCapabilityReport

    public init(
        headers: String,
        classNames: [String],
        classHeaders: [ClassHeader],
        usedExternalTool: ExternalTool?,
        warnings: [String],
        facts: MachOFacts,
        capabilityReport: ClassDumpCapabilityReport? = nil
    ) {
        self.headers = headers
        self.classNames = classNames
        self.classHeaders = classHeaders
        self.usedExternalTool = usedExternalTool
        self.warnings = warnings
        self.facts = facts
        self.capabilityReport = capabilityReport ?? ClassDumpCapabilityReport(
            architectures: facts.archs,
            isEncrypted: facts.isEncrypted,
            hasChainedFixups: facts.hasChainedFixups,
            discoveredClassCount: classNames.count,
            exportedClassCount: classHeaders.isEmpty ? classNames.count : classHeaders.count,
            methodCount: 0,
            propertyCount: 0,
            protocolCount: 0,
            skippedCount: 0,
            skipReasons: warnings,
            coverage: classNames.isEmpty ? 0 : 1,
            completeness: classNames.isEmpty ? .unsupported : (warnings.isEmpty ? .complete : .partial)
        )
    }
}

public enum ClassDumpExportMode: String, CaseIterable, Sendable {
    case aggregate
    case oneFilePerClass
}

public struct ClassDumpExportSummary: Sendable {
    public let files: [URL]
    public let classCount: Int
    public let warnings: [String]
}

struct ExternalHeaderDump {
    let headers: String
    let classHeaders: [ClassHeader]
}

/// 从 Mach-O / .app / .ipa / dylib 导出 Objective-C 头文件。
/// 分级:未加密 + 传统指针格式走原生解析;arm64e / chained fixups / Swift 回退外部 class-dump/dsdump。
public enum ClassDumpService {
    public static func preflightCapability(fileAt url: URL) throws -> ClassDumpCapabilityReport {
        guard let facts = MachOInspector.facts(fileAt: url) else { throw ClassDumpError.notMachO }
        var reasons: [String] = []
        if facts.isEncrypted { reasons.append(L("classdump.reason.fairPlayNeedsDecrypted")) }
        if facts.isArm64e { reasons.append(L("classdump.reason.arm64eMayNeedExternal")) }
        if facts.hasChainedFixups { reasons.append(L("classdump.reason.chainedFixupsUnsupported")) }
        if facts.hasSwift { reasons.append(L("classdump.reason.swiftOutOfScope")) }
        let completeness: ClassDumpCompleteness
        if facts.isEncrypted || facts.isArm64e || facts.hasChainedFixups {
            completeness = .unsupported
        } else {
            completeness = .partial
            reasons.append(L("classdump.reason.metadataNotTraversedYet"))
        }
        return ClassDumpCapabilityReport(
            architectures: facts.archs,
            isEncrypted: facts.isEncrypted,
            hasChainedFixups: facts.hasChainedFixups,
            discoveredClassCount: 0,
            exportedClassCount: 0,
            methodCount: 0,
            propertyCount: 0,
            protocolCount: 0,
            skippedCount: 0,
            skipReasons: reasons,
            coverage: 0,
            completeness: completeness
        )
    }

    public static func capabilityReport(
        facts: MachOFacts,
        classes: [ObjCClass],
        exportedClassCount: Int,
        skippedCount: Int,
        skipReasons: [String]
    ) -> ClassDumpCapabilityReport {
        var reasons = skipReasons
        if facts.hasSwift { reasons.append(L("classdump.reason.swiftMetadataDetected")) }
        if facts.hasChainedFixups { reasons.append(L("classdump.reason.chainedFixupsUnsupported")) }
        if facts.isArm64e { reasons.append(L("classdump.reason.arm64eUnsupported")) }
        if facts.isEncrypted { reasons.append("FairPlay cryptid=1") }
        reasons = Array(Set(reasons)).sorted()
        let discovered = classes.count + max(0, skippedCount)
        let coverage = discovered > 0 ? min(1, Double(exportedClassCount) / Double(discovered)) : 0
        let meaningful = classes.filter {
            !$0.instanceMethods.isEmpty || !$0.classMethods.isEmpty || !$0.properties.isEmpty
                || !$0.protocols.isEmpty || !$0.ivars.isEmpty
        }
        let completeness: ClassDumpCompleteness
        if facts.isEncrypted || facts.hasChainedFixups || facts.isArm64e || classes.isEmpty || meaningful.isEmpty {
            completeness = .unsupported
        } else if !reasons.isEmpty || skippedCount > 0 || exportedClassCount < classes.count {
            completeness = .partial
        } else {
            completeness = .complete
        }
        return ClassDumpCapabilityReport(
            architectures: facts.archs,
            isEncrypted: facts.isEncrypted,
            hasChainedFixups: facts.hasChainedFixups,
            discoveredClassCount: discovered,
            exportedClassCount: exportedClassCount,
            methodCount: classes.reduce(0) { $0 + $1.instanceMethods.count + $1.classMethods.count },
            propertyCount: classes.reduce(0) { $0 + $1.properties.count },
            protocolCount: classes.reduce(0) { $0 + $1.protocols.count },
            skippedCount: skippedCount,
            skipReasons: reasons,
            coverage: coverage,
            completeness: completeness
        )
    }

    public static func inspect(fileAt url: URL) throws -> MachOFacts {
        let (binary, cleanup) = try resolveBinary(from: url)
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        guard let facts = MachOInspector.facts(fileAt: binary) else { throw ClassDumpError.notMachO }
        return facts
    }

    /// 定位待分析的主可执行文件;返回二进制 URL 与需清理的临时目录(若有)。
    public static func resolveBinary(from url: URL) throws -> (binary: URL, cleanup: URL?) {
        let ext = url.pathExtension.lowercased()
        if ext == "ipa" {
            let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "cd-ipa")
            try IpaService.unzip(url, to: work.appendingPathComponent("x"))
            let app = try IpaService.locateApp(in: work.appendingPathComponent("x"))
            return (try mainExecutable(ofApp: app), work)
        }
        if ext == "app" || (FileSystemHelper.isDirectory(url) && ext == "app") {
            return (try mainExecutable(ofApp: url), nil)
        }
        if FileSystemHelper.isDirectory(url) {
            // .framework 或其它目录:取里面第一个 Mach-O
            if let m = FileSystemHelper.firstFile(in: url, where: { MachOIdentifier.isMachO(fileAt: $0) }) {
                return (m, nil)
            }
            throw ClassDumpError.notMachO
        }
        guard MachOIdentifier.isMachO(fileAt: url) else { throw ClassDumpError.notMachO }
        return (url, nil)
    }

    static func mainExecutable(ofApp app: URL) throws -> URL {
        let plist = (try? IpaService.infoPlist(appBundle: app)) ?? [:]
        let exec = (plist["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
        let url = app.appendingPathComponent(exec)
        guard MachOIdentifier.isMachO(fileAt: url) else { throw ClassDumpError.notMachO }
        return url
    }

    /// 主入口:自动选择原生 / 外部工具。
    public static func dump(
        fileAt url: URL,
        arch: String? = nil,
        preferExternal: Bool = false,
        allowExternalFallback: Bool = true
    ) throws -> HeaderDumpResult {
        let (binary, cleanup) = try resolveBinary(from: url)
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }

        guard let facts = MachOInspector.facts(fileAt: binary) else { throw ClassDumpError.notMachO }
        if facts.isEncrypted { throw ClassDumpError.encrypted }

        if !preferExternal, facts.nativeObjCDumpSupported {
            let native = try nativeDumpDetailed(fileAt: binary, arch: arch, facts: facts)
            if native.report.completeness != .unsupported {
                return HeaderDumpResult(
                    headers: native.headers,
                    classNames: native.classes.map(\.name),
                    classHeaders: native.classes.map { ClassHeader(name: $0.name, contents: $0.header() + "\n") },
                    usedExternalTool: nil,
                    warnings: native.report.skipReasons,
                    facts: facts,
                    capabilityReport: native.report
                )
            }
            // 原生没解析到类:回退外部工具(带上原因)。
        }

        // 外部工具回退
        let reasonBits = [facts.hasChainedFixups ? "chained fixups(arm64e/iOS15+)" : nil,
                          facts.hasSwift ? L("classdump.reason.containsSwiftTypes") : nil].compactMap { $0 }
        if allowExternalFallback, let tool = availableExternalDumper() {
            let external = try externalDumpDetailed(
                fileAt: binary,
                tool: tool,
                arch: arch ?? facts.archs.first
            )
            guard !external.headers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClassDumpError.commandFailed(L("classdump.error.externalToolNoDeclarations"))
            }
            let classNames = external.classHeaders.map(\.name)
            let externalReport = ClassDumpCapabilityReport(
                architectures: facts.archs, isEncrypted: false,
                hasChainedFixups: facts.hasChainedFixups,
                discoveredClassCount: classNames.count, exportedClassCount: classNames.count,
                methodCount: 0, propertyCount: 0, protocolCount: 0,
                skippedCount: 0,
                skipReasons: [L("classdump.warning.externalNoCoverageStats")],
                coverage: classNames.isEmpty ? 0 : 1, completeness: .partial
            )
            return HeaderDumpResult(headers: external.headers, classNames: classNames,
                                    classHeaders: external.classHeaders,
                                    usedExternalTool: tool,
                                    warnings: reasonBits.isEmpty ? [] : [L(
                                        "classdump.warning.fellBackToExternal",
                                        reasonBits.joined(separator: L("classdump.reasonSeparator"))
                                    )],
                                    facts: facts, capabilityReport: externalReport)
        }
        let why = reasonBits.isEmpty
            ? L("classdump.reason.nativeFoundNoClasses")
            : reasonBits.joined(separator: L("classdump.reasonSeparator"))
        if !allowExternalFallback {
            throw ClassDumpError.unsupportedBuiltIn(why)
        }
        throw ClassDumpError.noExternalTool(L("classdump.error.buildExternalToolYourself", why))
    }

    /// 原生解析(仅未加密 + 传统指针格式)。
    public static func nativeDump(fileAt url: URL, arch: String?, facts: MachOFacts) throws -> (String, [String], [String]) {
        let detailed = try nativeDumpDetailed(fileAt: url, arch: arch, facts: facts)
        return (detailed.headers, detailed.classes.map(\.name), detailed.report.skipReasons)
    }

    static func nativeDumpDetailed(
        fileAt url: URL,
        arch: String?,
        facts: MachOFacts
    ) throws -> (headers: String, classes: [ObjCClass], report: ClassDumpCapabilityReport) {
        let b = [UInt8](try Data(contentsOf: url))
        let idx = MachOInspector.sliceIndex(b, arch: arch)
        guard let parsed = MachOInspector.segments(b, sliceIndex: idx) else { throw ClassDumpError.notMachO }
        var parser = NativeObjCParser(b: b, le: parsed.le, sliceOffset: parsed.sliceOffset, segments: parsed.segments)
        let parsedObjC = parser.parse()
        let classes = parsedObjC.classes
        let report = capabilityReport(
            facts: facts,
            classes: classes,
            exportedClassCount: classes.count,
            skippedCount: parsedObjC.skippedCount,
            skipReasons: parsedObjC.skipReasons
        )
        let header = L("classdump.header.generatedBy") + "\n"
            + L(
                "classdump.header.fileSummary",
                url.lastPathComponent,
                arch ?? facts.archs.first ?? "?",
                classes.count
            ) + "\n\n"
            + classes.map { $0.header() }.joined(separator: "\n\n")
        return (header, classes, report)
    }

    static func nativeClassHeaders(fileAt url: URL, arch: String?) -> [ClassHeader] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let b = [UInt8](data)
        let idx = MachOInspector.sliceIndex(b, arch: arch)
        guard let parsed = MachOInspector.segments(b, sliceIndex: idx) else { return [] }
        var parser = NativeObjCParser(b: b, le: parsed.le, sliceOffset: parsed.sliceOffset, segments: parsed.segments)
        return parser.parse().classes.map { ClassHeader(name: $0.name, contents: $0.header() + "\n") }
    }

    @discardableResult
    public static func export(
        _ result: HeaderDumpResult,
        to directory: URL,
        baseName: String,
        mode: ClassDumpExportMode
    ) throws -> ClassDumpExportSummary {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeBase = safeHeaderFileName(baseName.isEmpty ? "Headers" : baseName)
        var files: [URL] = []

        switch mode {
        case .aggregate:
            let output = FileSystemHelper.uniqueOutputURL(
                basedOn: directory.appendingPathComponent("\(safeBase)-Headers.h")
            )
            try result.headers.write(to: output, atomically: true, encoding: .utf8)
            files.append(output)
        case .oneFilePerClass:
            guard !result.classHeaders.isEmpty else {
                let output = FileSystemHelper.uniqueOutputURL(
                    basedOn: directory.appendingPathComponent("\(safeBase)-Headers.h")
                )
                try result.headers.write(to: output, atomically: true, encoding: .utf8)
                files.append(output)
                return ClassDumpExportSummary(
                    files: files,
                    classCount: result.classNames.count,
                    warnings: result.warnings + [L("classdump.warning.cannotSplitExternalResult")]
                )
            }
            var usedNames: Set<String> = []
            for header in result.classHeaders {
                var filename = safeHeaderFileName(header.name)
                var suffix = 2
                while usedNames.contains(filename.lowercased()) {
                    filename = "\(safeHeaderFileName(header.name))-\(suffix)"
                    suffix += 1
                }
                usedNames.insert(filename.lowercased())
                let output = FileSystemHelper.uniqueOutputURL(
                    basedOn: directory.appendingPathComponent(filename).appendingPathExtension("h")
                )
                try header.contents.write(to: output, atomically: true, encoding: .utf8)
                files.append(output)
            }
            let umbrella = FileSystemHelper.uniqueOutputURL(
                basedOn: directory.appendingPathComponent("\(safeBase)-Headers.h")
            )
            let imports = files.map { "#import \"\($0.lastPathComponent)\"" }.joined(separator: "\n") + "\n"
            try imports.write(to: umbrella, atomically: true, encoding: .utf8)
            files.append(umbrella)
        }

        return ClassDumpExportSummary(
            files: files,
            classCount: result.classNames.count,
            warnings: result.warnings
        )
    }

    public static func safeHeaderFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return result.isEmpty ? "Header" : String(result.prefix(120))
    }

    public static func availableExternalDumper() -> ExternalTool? {
        if ExternalTool.classDump.isAvailable { return .classDump }
        if ExternalTool.dsdump.isAvailable { return .dsdump }
        return nil
    }

    public static func externalDump(fileAt url: URL, tool: ExternalTool, arch: String?) throws -> String {
        try externalDumpDetailed(fileAt: url, tool: tool, arch: arch).headers
    }

    static func externalDumpDetailed(
        fileAt url: URL,
        tool: ExternalTool,
        arch: String?
    ) throws -> ExternalHeaderDump {
        switch tool {
        case .classDump:
            let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "classdump-output")
            defer { try? FileManager.default.removeItem(at: work) }
            let output = work.appendingPathComponent("Headers", isDirectory: true)
            try FileManager.default.createDirectory(
                at: output,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let result = try ExternalTool.classDump.run(["-H", "-o", output.path, url.path])
            guard result.succeeded else {
                throw ClassDumpError.commandFailed(result.combinedOutput)
            }

            let classHeaders = try generatedHeaders(in: output)
            if classHeaders.isEmpty {
                let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard stdout.contains("@interface") || stdout.contains("@protocol") else {
                    throw ClassDumpError.commandFailed(
                        result.combinedOutput.isEmpty
                            ? L("classdump.error.noHeadersInOutputDirectory")
                            : result.combinedOutput
                    )
                }
                return ExternalHeaderDump(headers: stdout + "\n", classHeaders: [])
            }
            let aggregate = classHeaders.map {
                "// MARK: - \($0.name)\n\n\($0.contents)"
            }.joined(separator: "\n\n")
            return ExternalHeaderDump(headers: aggregate, classHeaders: classHeaders)
        case .dsdump:
            var args = ["--objc", url.path]
            if let arch { args += ["-a", arch] }
            let r = try ExternalTool.dsdump.run(args)
            guard r.succeeded, !r.stdout.isEmpty else { throw ClassDumpError.commandFailed(r.combinedOutput) }
            return ExternalHeaderDump(headers: r.stdout, classHeaders: [])
        default:
            throw ClassDumpError.needsExternalTool(L("classdump.error.unsupportedTool", tool.commandName))
        }
    }

    private static func generatedHeaders(in directory: URL) throws -> [ClassHeader] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ClassDumpError.commandFailed(L("classdump.error.cannotReadOutputDirectory"))
        }

        let maximumHeaderCount = 100_000
        let maximumTotalBytes: Int64 = 256 * 1_024 * 1_024
        var totalBytes: Int64 = 0
        var urls: [URL] = []
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "h" {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            totalBytes += Int64(values.fileSize ?? 0)
            guard urls.count < maximumHeaderCount, totalBytes <= maximumTotalBytes else {
                throw ClassDumpError.commandFailed(L("classdump.error.outputExceedsSafetyLimit"))
            }
            urls.append(file)
        }

        return try urls.sorted { $0.path < $1.path }.map { file in
            let contents = try String(contentsOf: file, encoding: .utf8)
            return ClassHeader(
                name: file.deletingPathExtension().lastPathComponent,
                contents: contents.hasSuffix("\n") ? contents : contents + "\n"
            )
        }
    }
}
