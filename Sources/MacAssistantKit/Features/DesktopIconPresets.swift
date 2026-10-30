#if canImport(AppKit)
import AppKit
#endif
import CoreImage
import Foundation
import UniformTypeIdentifiers

public enum DesktopIconPresetGroup: String, Sendable {
    case ai
    case costume
    case cute
    case color
    case type
    case software
}

/// 文件夹配色、常用类型，以及内置的 AI 文件夹、造型和粘土风贴纸。
/// 配色和类型仍按系统文件夹上色后叠符号；AI、造型和贴纸用整张透明图替换图标。
public struct DesktopIconPreset: Identifiable, Hashable, Sendable {
    public let group: DesktopIconPresetGroup
    public let key: String
    public let red: Double
    public let green: Double
    public let blue: Double
    public let keepOriginalColor: Bool
    public let symbolName: String?

    public var id: String { "\(group.rawValue).\(key)" }

    public var title: String {
        if group == .ai || group == .cute || group == .costume {
            return L("desktopicon.preset.\(group.rawValue).\(key)")
        }
        switch id {
        case "color.system": return L("desktopicon.preset.color.system")
        case "color.red": return L("desktopicon.preset.color.red")
        case "color.orange": return L("desktopicon.preset.color.orange")
        case "color.yellow": return L("desktopicon.preset.color.yellow")
        case "color.green": return L("desktopicon.preset.color.green")
        case "color.mint": return L("desktopicon.preset.color.mint")
        case "color.blue": return L("desktopicon.preset.color.blue")
        case "color.indigo": return L("desktopicon.preset.color.indigo")
        case "color.purple": return L("desktopicon.preset.color.purple")
        case "color.pink": return L("desktopicon.preset.color.pink")
        case "color.brown": return L("desktopicon.preset.color.brown")
        case "color.graphite": return L("desktopicon.preset.color.graphite")
        case "color.nightGreen": return L("desktopicon.preset.color.nightGreen")
        case "color.picker": return L("desktopicon.preset.color.custom")
        case "type.documents": return L("desktopicon.preset.type.documents")
        case "type.code": return L("desktopicon.preset.type.code")
        case "type.scripts": return L("desktopicon.preset.type.scripts")
        case "type.downloads": return L("desktopicon.preset.type.downloads")
        case "type.photos": return L("desktopicon.preset.type.photos")
        case "type.videos": return L("desktopicon.preset.type.videos")
        case "type.music": return L("desktopicon.preset.type.music")
        case "type.archive": return L("desktopicon.preset.type.archive")
        case "type.work": return L("desktopicon.preset.type.work")
        case "type.projects": return L("desktopicon.preset.type.projects")
        case "type.design": return L("desktopicon.preset.type.design")
        case "type.tools": return L("desktopicon.preset.type.tools")
        case "type.backup": return L("desktopicon.preset.type.backup")
        case "type.cloud": return L("desktopicon.preset.type.cloud")
        case "type.private": return L("desktopicon.preset.type.private")
        case "type.favorite": return L("desktopicon.preset.type.favorite")
        case "software.repair": return L("desktopicon.preset.software.repair")
        case "software.cleanup": return L("desktopicon.preset.software.cleanup")
        case "software.memory": return L("desktopicon.preset.software.memory")
        case "software.network": return L("desktopicon.preset.software.network")
        case "software.packages": return L("desktopicon.preset.software.packages")
        case "software.dylib": return L("desktopicon.preset.software.dylib")
        case "software.ipa": return L("desktopicon.preset.software.ipa")
        case "software.inject": return L("desktopicon.preset.software.inject")
        case "software.binary": return L("desktopicon.preset.software.binary")
        case "software.clone": return L("desktopicon.preset.software.clone")
        case "software.signing": return L("desktopicon.preset.software.signing")
        case "software.symbols": return L("desktopicon.preset.software.symbols")
        case "software.plugins": return L("desktopicon.preset.software.plugins")
        case "software.build": return L("desktopicon.preset.software.build")
        default:
            return isCustomColor ? L("desktopicon.preset.color.custom") : key
        }
    }

    public var isCustomColor: Bool {
        group == .color && key.hasPrefix("custom.")
    }

    public var customColorID: UUID? {
        guard isCustomColor else { return nil }
        return UUID(uuidString: String(key.dropFirst("custom.".count)))
    }

    public static func custom(id: UUID, red: Double, green: Double, blue: Double) -> DesktopIconPreset {
        .init(group: .color, key: "custom.\(id.uuidString)", red: red, green: green, blue: blue)
    }

    public init(
        group: DesktopIconPresetGroup,
        key: String,
        red: Double,
        green: Double,
        blue: Double,
        keepOriginalColor: Bool = false,
        symbolName: String? = nil
    ) {
        self.group = group
        self.key = key
        self.red = red
        self.green = green
        self.blue = blue
        self.keepOriginalColor = keepOriginalColor
        self.symbolName = symbolName
    }
}

public enum DesktopIconPresets {
    /// 常见 AI 产品配色的文件夹。资源在 `Resources/AIIcons/<key>.png`，原创绘制，不是官方标志文件。
    public static let ai: [DesktopIconPreset] = [
        ai("codex", 0.22, 0.22, 0.24),
        ai("gpt", 0.96, 0.96, 0.97),
        ai("claude", 0.96, 0.91, 0.84),
        ai("grok", 0.12, 0.12, 0.13),
        ai("grokBot", 0.91, 0.91, 0.93),
        ai("deepseek", 0.95, 0.95, 0.96),
        ai("kimi", 0.10, 0.10, 0.11),
        ai("glm", 0.18, 0.18, 0.18),
        ai("muse", 0.45, 0.50, 0.86)
    ]

    /// 文件夹外形的造型。资源在 `Resources/FolderCostumes/<key>.png`。
    public static let costumes: [DesktopIconPreset] = [
        costume("puppy", 0.86, 0.68, 0.36),
        costume("kitten", 0.93, 0.88, 0.78),
        costume("pear", 0.72, 0.78, 0.28),
        costume("fridge", 0.78, 0.80, 0.82),
        costume("moon", 0.62, 0.64, 0.66),
        costume("spider", 0.12, 0.10, 0.12),
        costume("berry", 0.86, 0.28, 0.32),
        costume("gift", 0.94, 0.72, 0.78)
    ]

    /// 原创粘土风贴纸。资源在 `Resources/CuteIcons/<key>.png`，透明底，点选后整张替换图标。
    public static let cute: [DesktopIconPreset] = [
        cute("cat", 0.96, 0.90, 0.82),
        cute("bunny", 0.96, 0.90, 0.84),
        cute("bear", 0.80, 0.55, 0.28),
        cute("peach", 0.95, 0.62, 0.45),
        cute("heart", 0.95, 0.62, 0.70),
        cute("star", 0.93, 0.75, 0.28),
        cute("cloud", 0.86, 0.80, 0.95),
        cute("moon", 0.96, 0.90, 0.78),
        cute("flower", 0.98, 0.68, 0.76),
        cute("rainbow", 0.98, 0.74, 0.72),
        cute("coffee", 0.95, 0.88, 0.80),
        cute("book", 0.78, 0.70, 0.90),
        cute("music", 0.96, 0.74, 0.78),
        cute("camera", 0.55, 0.82, 0.72),
        cute("gift", 0.98, 0.72, 0.76),
        cute("rocket", 0.96, 0.90, 0.82)
    ]

    public static let colors: [DesktopIconPreset] = [
        .init(group: .color, key: "system", red: 0.31, green: 0.56, blue: 0.83, keepOriginalColor: true),
        .init(group: .color, key: "red", red: 0.83, green: 0.33, blue: 0.31),
        .init(group: .color, key: "orange", red: 0.88, green: 0.54, blue: 0.24),
        .init(group: .color, key: "yellow", red: 0.90, green: 0.75, blue: 0.29),
        .init(group: .color, key: "green", red: 0.35, green: 0.66, blue: 0.42),
        .init(group: .color, key: "mint", red: 0.25, green: 0.66, blue: 0.63),
        .init(group: .color, key: "blue", red: 0.31, green: 0.56, blue: 0.83),
        .init(group: .color, key: "indigo", red: 0.36, green: 0.44, blue: 0.75),
        .init(group: .color, key: "purple", red: 0.55, green: 0.39, blue: 0.72),
        .init(group: .color, key: "pink", red: 0.83, green: 0.42, blue: 0.60),
        .init(group: .color, key: "brown", red: 0.63, green: 0.47, blue: 0.31),
        .init(group: .color, key: "graphite", red: 0.29, green: 0.29, blue: 0.30),
        .init(group: .color, key: "nightGreen", red: 0.10, green: 0.24, blue: 0.20)
    ]

    public static let types: [DesktopIconPreset] = [
        .init(group: .type, key: "documents", red: 0.42, green: 0.52, blue: 0.60, symbolName: "doc.text.fill"),
        .init(group: .type, key: "code", red: 0.36, green: 0.44, blue: 0.75, symbolName: "chevron.left.forwardslash.chevron.right"),
        .init(group: .type, key: "scripts", red: 0.29, green: 0.66, blue: 0.56, symbolName: "terminal.fill"),
        .init(group: .type, key: "downloads", red: 0.25, green: 0.66, blue: 0.63, symbolName: "arrow.down.circle.fill"),
        .init(group: .type, key: "photos", red: 0.83, green: 0.42, blue: 0.48, symbolName: "photo.fill"),
        .init(group: .type, key: "videos", red: 0.55, green: 0.39, blue: 0.72, symbolName: "film.fill"),
        .init(group: .type, key: "music", red: 0.83, green: 0.42, blue: 0.60, symbolName: "music.note"),
        .init(group: .type, key: "archive", red: 0.79, green: 0.63, blue: 0.23, symbolName: "archivebox.fill"),
        .init(group: .type, key: "work", red: 0.35, green: 0.42, blue: 0.48, symbolName: "briefcase.fill"),
        .init(group: .type, key: "projects", red: 0.35, green: 0.66, blue: 0.42, symbolName: "square.stack.3d.up.fill"),
        .init(group: .type, key: "design", red: 0.88, green: 0.48, blue: 0.37, symbolName: "paintbrush.pointed.fill"),
        .init(group: .type, key: "tools", red: 0.88, green: 0.54, blue: 0.24, symbolName: "wrench.and.screwdriver.fill"),
        .init(group: .type, key: "backup", red: 0.29, green: 0.66, blue: 0.78, symbolName: "externaldrive.fill"),
        .init(group: .type, key: "cloud", red: 0.42, green: 0.64, blue: 0.91, symbolName: "cloud.fill"),
        .init(group: .type, key: "private", red: 0.29, green: 0.29, blue: 0.30, symbolName: "lock.fill"),
        .init(group: .type, key: "favorite", red: 0.83, green: 0.33, blue: 0.31, symbolName: "heart.fill")
    ]

    /// 和侧栏功能同名同符号，方便给修复、注入、符号表这类工程目录用。
    public static let software: [DesktopIconPreset] = [
        .init(group: .software, key: "repair", red: 0.88, green: 0.54, blue: 0.24, symbolName: "bandage"),
        .init(group: .software, key: "cleanup", red: 0.40, green: 0.52, blue: 0.46, symbolName: "trash.fill"),
        .init(group: .software, key: "memory", red: 0.36, green: 0.44, blue: 0.75, symbolName: "memorychip"),
        .init(group: .software, key: "network", red: 0.29, green: 0.66, blue: 0.78, symbolName: "network"),
        .init(group: .software, key: "packages", red: 0.79, green: 0.63, blue: 0.23, symbolName: "shippingbox.fill"),
        .init(group: .software, key: "dylib", red: 0.25, green: 0.58, blue: 0.70, symbolName: "link"),
        .init(group: .software, key: "ipa", red: 0.83, green: 0.42, blue: 0.48, symbolName: "app.gift.fill"),
        .init(group: .software, key: "inject", red: 0.55, green: 0.39, blue: 0.72, symbolName: "syringe"),
        .init(group: .software, key: "binary", red: 0.29, green: 0.29, blue: 0.30, symbolName: "cpu"),
        .init(group: .software, key: "clone", red: 0.42, green: 0.52, blue: 0.60, symbolName: "rectangle.on.rectangle"),
        .init(group: .software, key: "signing", red: 0.35, green: 0.66, blue: 0.42, symbolName: "checkmark.seal.fill"),
        .init(group: .software, key: "symbols", red: 0.31, green: 0.42, blue: 0.62, symbolName: "function"),
        .init(group: .software, key: "plugins", red: 0.83, green: 0.42, blue: 0.60, symbolName: "puzzlepiece.extension.fill"),
        .init(group: .software, key: "build", red: 0.88, green: 0.48, blue: 0.37, symbolName: "hammer.fill")
    ]

    public static var all: [DesktopIconPreset] { ai + costumes + cute + colors + types + software }

    private static func ai(_ key: String, _ red: Double, _ green: Double, _ blue: Double) -> DesktopIconPreset {
        .init(group: .ai, key: key, red: red, green: green, blue: blue)
    }

    private static func costume(_ key: String, _ red: Double, _ green: Double, _ blue: Double) -> DesktopIconPreset {
        .init(group: .costume, key: key, red: red, green: green, blue: blue)
    }

    private static func cute(_ key: String, _ red: Double, _ green: Double, _ blue: Double) -> DesktopIconPreset {
        .init(group: .cute, key: key, red: red, green: green, blue: blue)
    }

    /// 颜色行末尾「自选颜色」按钮的预览：当前色文件夹 + 调色板符号。
    public static func customPicker(red: Double, green: Double, blue: Double) -> DesktopIconPreset {
        .init(group: .color, key: "picker", red: red, green: green, blue: blue, symbolName: "paintpalette.fill")
    }

    public static func preset(id: String, customs: [DesktopIconCustomColor] = []) -> DesktopIconPreset? {
        if let match = all.first(where: { $0.id == id }) { return match }
        return customs.first { $0.preset.id == id }?.preset
    }

    #if canImport(AppKit)
    public static func image(for preset: DesktopIconPreset, pixelSize: Int = 1024) -> NSImage {
        ImageCache.shared.image(for: cacheKey(for: preset, pixelSize: pixelSize)) {
            render(preset, pixelSize: pixelSize)
        }
    }

    private static func cacheKey(for preset: DesktopIconPreset, pixelSize: Int) -> String {
        let color = String(format: "%.4f-%.4f-%.4f", preset.red, preset.green, preset.blue)
        return "\(preset.id)|\(color)|\(preset.symbolName ?? "")@\(pixelSize)"
    }
    #endif
}

/// 用户用颜色选择器留下的配色，出现在系统预设后面。
public struct DesktopIconCustomColor: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var red: Double
    public var green: Double
    public var blue: Double

    public var preset: DesktopIconPreset {
        .custom(id: id, red: red, green: green, blue: blue)
    }

    public init(id: UUID = UUID(), red: Double, green: Double, blue: Double) {
        self.id = id
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum DesktopIconCustomColorStore {
    public static let limit = 8

    public static func load(storeDirectory: URL? = nil) -> [DesktopIconCustomColor] {
        let file = colorsFile(in: storeDirectory)
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([DesktopIconCustomColor].self, from: data)) ?? []
    }

    @discardableResult
    public static func upsert(_ color: DesktopIconCustomColor, storeDirectory: URL? = nil) throws -> DesktopIconCustomColor {
        var records = load(storeDirectory: storeDirectory)
        if let index = records.firstIndex(where: { $0.id == color.id }) {
            records[index] = color
        } else if let existing = records.first(where: { isSimilar($0, color) }) {
            return existing
        } else {
            records.append(color)
            if records.count > limit {
                records = Array(records.suffix(limit))
            }
        }
        try write(records, storeDirectory: storeDirectory)
        return color
    }

    public static func remove(id: UUID, storeDirectory: URL? = nil) throws {
        var records = load(storeDirectory: storeDirectory)
        records.removeAll { $0.id == id }
        try write(records, storeDirectory: storeDirectory)
    }

    private static func isSimilar(_ lhs: DesktopIconCustomColor, _ rhs: DesktopIconCustomColor) -> Bool {
        abs(lhs.red - rhs.red) < 0.02
            && abs(lhs.green - rhs.green) < 0.02
            && abs(lhs.blue - rhs.blue) < 0.02
    }

    private static func colorsFile(in storeDirectory: URL?) -> URL {
        let directory = storeDirectory ?? DesktopIconService.defaultStoreDirectory()
        return directory.appendingPathComponent("custom-colors.json")
    }

    private static func write(_ records: [DesktopIconCustomColor], storeDirectory: URL?) throws {
        let directory = storeDirectory ?? DesktopIconService.defaultStoreDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: colorsFile(in: storeDirectory), options: .atomic)
    }
}

#if canImport(AppKit)
/// 按系统文件夹正面（去掉顶上的标签）给符号居中。
enum DesktopIconPresetLayout {
    static func faceRect(in bitmap: NSBitmapImageRep, pixelSize: Int) -> CGRect {
        guard let bounds = opaqueBounds(in: bitmap) else {
            return fallbackFace(pixelSize: pixelSize)
        }
        let bodyTop = folderBodyTop(in: bitmap, bounds: bounds)
        let height = CGFloat(bounds.maxY - bodyTop)
        guard height > 4 else { return fallbackFace(pixelSize: pixelSize) }
        return CGRect(
            x: CGFloat(bounds.minX),
            y: CGFloat(pixelSize - bounds.maxY),
            width: CGFloat(bounds.maxX - bounds.minX),
            height: height
        )
    }

    static func centeredSymbolRect(face: CGRect, symbolSize: CGSize) -> CGRect {
        let maxSide = min(face.width, face.height) * 0.46
        let scale = maxSide / max(max(symbolSize.width, symbolSize.height), 1)
        let width = symbolSize.width * scale
        let height = symbolSize.height * scale
        return CGRect(
            x: face.midX - width / 2,
            y: face.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func fallbackFace(pixelSize: Int) -> CGRect {
        let size = CGFloat(pixelSize)
        return CGRect(x: size * 0.18, y: size * 0.16, width: size * 0.64, height: size * 0.50)
    }

    private static func opaqueBounds(in bitmap: NSBitmapImageRep) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        guard let data = bitmap.bitmapData else { return nil }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let samples = max(bitmap.samplesPerPixel, 1)
        let rowBytes = bitmap.bytesPerRow
        let alphaIndex = samples - 1
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        let step = max(1, width / 320)
        for y in stride(from: 0, to: height, by: step) {
            let row = data.advanced(by: y * rowBytes)
            for x in stride(from: 0, to: width, by: step) {
                if row[x * samples + alphaIndex] > 40 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX else { return nil }
        return (minX, minY, maxX, maxY)
    }

    private static func folderBodyTop(
        in bitmap: NSBitmapImageRep,
        bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)
    ) -> Int {
        guard let data = bitmap.bitmapData else { return bounds.minY }
        let samples = max(bitmap.samplesPerPixel, 1)
        let rowBytes = bitmap.bytesPerRow
        let alphaIndex = samples - 1
        let step = max(1, bitmap.pixelsWide / 320)
        let targetSpan = Double(bounds.maxX - bounds.minX) * 0.78
        for y in stride(from: bounds.minY, through: bounds.maxY, by: step) {
            let row = data.advanced(by: y * rowBytes)
            var rowMin = bounds.maxX
            var rowMax = bounds.minX
            for x in stride(from: bounds.minX, through: bounds.maxX, by: step) {
                if row[x * samples + alphaIndex] > 40 {
                    rowMin = min(rowMin, x)
                    rowMax = max(rowMax, x)
                }
            }
            if rowMax > rowMin, Double(rowMax - rowMin) >= targetSpan {
                return y
            }
        }
        return bounds.minY
    }
}

private enum DesktopIconPresetRenderer {
    static func render(_ preset: DesktopIconPreset, pixelSize: Int) -> NSImage {
        if let directory = artworkDirectory(for: preset.group),
           let artwork = renderArtwork(named: preset.key, directory: directory, pixelSize: pixelSize) {
            return artwork
        }
        let folder = rasterizeFolder(pixelSize: pixelSize)
        let tinted = preset.keepOriginalColor
            ? folder
            : colorize(folder, tint: preset.nsColor, pixelSize: pixelSize)
        guard let symbolName = preset.symbolName else { return image(from: tinted, pixelSize: pixelSize) }
        return overlaySymbol(
            symbolName,
            on: tinted,
            ink: preset.badgeInk,
            pixelSize: pixelSize
        )
    }

    private static func artworkDirectory(for group: DesktopIconPresetGroup) -> String? {
        switch group {
        case .ai: return "AIIcons"
        case .costume: return "FolderCostumes"
        case .cute: return "CuteIcons"
        case .color, .type, .software: return nil
        }
    }

    private static func renderArtwork(named name: String, directory: String, pixelSize: Int) -> NSImage? {
        let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: directory)
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        guard let url, let source = NSImage(contentsOf: url), source.isValid else { return nil }
        let canvas = makeCanvas(pixelSize: pixelSize)
        draw(source, in: canvas, pixelSize: pixelSize)
        return image(from: canvas, pixelSize: pixelSize)
    }

    private static func rasterizeFolder(pixelSize: Int) -> NSBitmapImageRep {
        let icon = NSWorkspace.shared.icon(for: .folder)
        let drawable = icon.copy() as? NSImage ?? icon
        drawable.isTemplate = false
        drawable.size = NSSize(width: pixelSize, height: pixelSize)
        let representation = makeCanvas(pixelSize: pixelSize)
        draw(drawable, in: representation, pixelSize: pixelSize)
        return representation
    }

    private static func colorize(_ source: NSBitmapImageRep, tint: NSColor, pixelSize: Int) -> NSBitmapImageRep {
        guard let ciImage = CIImage(bitmapImageRep: source) else { return source }
        let color = CIColor(color: tint.usingColorSpace(.sRGB) ?? tint) ?? CIColor(red: 0.31, green: 0.56, blue: 0.83)
        let monochrome = ciImage.applyingFilter("CIColorMonochrome", parameters: [
            kCIInputColorKey: color,
            kCIInputIntensityKey: 0.90
        ])
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let cgImage = context.createCGImage(monochrome, from: monochrome.extent) else {
            return sourceAtopFallback(source, tint: tint, pixelSize: pixelSize)
        }
        let canvas = makeCanvas(pixelSize: pixelSize)
        draw(NSImage(cgImage: cgImage, size: NSSize(width: pixelSize, height: pixelSize)), in: canvas, pixelSize: pixelSize)
        return canvas
    }

    private static func sourceAtopFallback(_ source: NSBitmapImageRep, tint: NSColor, pixelSize: Int) -> NSBitmapImageRep {
        let canvas = makeCanvas(pixelSize: pixelSize)
        draw(NSImage(size: NSSize(width: pixelSize, height: pixelSize), flipped: false) { _ in
            source.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
            return true
        }, in: canvas, pixelSize: pixelSize)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return canvas }
        NSGraphicsContext.current = context
        context.compositingOperation = .sourceAtop
        (tint.usingColorSpace(.sRGB) ?? tint).withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()
        return canvas
    }

    private static func overlaySymbol(
        _ symbolName: String,
        on folder: NSBitmapImageRep,
        ink: NSColor,
        pixelSize: Int
    ) -> NSImage {
        let canvas = makeCanvas(pixelSize: pixelSize)
        draw(image(from: folder, pixelSize: pixelSize), in: canvas, pixelSize: pixelSize)

        let pointSize = CGFloat(pixelSize) * 0.28
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else {
            return image(from: canvas, pixelSize: pixelSize)
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else {
            return image(from: canvas, pixelSize: pixelSize)
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let face = DesktopIconPresetLayout.faceRect(in: folder, pixelSize: pixelSize)
        let dest = DesktopIconPresetLayout.centeredSymbolRect(face: face, symbolSize: symbol.size)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = CGFloat(pixelSize) * 0.014
        shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(pixelSize) * 0.006)
        shadow.shadowColor = NSColor.black.withAlphaComponent(ink.luminance > 0.5 ? 0.18 : 0.28)
        shadow.set()
        symbol.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 0.94)
        return image(from: canvas, pixelSize: pixelSize)
    }

    private static func makeCanvas(pixelSize: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
    }

    private static func draw(_ image: NSImage, in representation: NSBitmapImageRep, pixelSize: Int) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    private static func image(from representation: NSBitmapImageRep, pixelSize: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        image.addRepresentation(representation)
        image.isTemplate = false
        return image
    }
}

private extension DesktopIconPreset {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    var badgeInk: NSColor {
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.62
            ? NSColor(srgbRed: 0.16, green: 0.15, blue: 0.14, alpha: 0.88)
            : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 0.92)
    }
}

private extension NSColor {
    var luminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}

private final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let lock = NSLock()
    private var images: [String: NSImage] = [:]

    func image(for key: String, make: () -> NSImage) -> NSImage {
        lock.lock()
        if let existing = images[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()
        let created = make()
        lock.lock()
        images[key] = created
        lock.unlock()
        return created
    }
}

private func render(_ preset: DesktopIconPreset, pixelSize: Int) -> NSImage {
    DesktopIconPresetRenderer.render(preset, pixelSize: pixelSize)
}
#endif
