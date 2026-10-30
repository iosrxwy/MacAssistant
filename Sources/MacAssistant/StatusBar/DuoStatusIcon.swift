import AppKit
import SwiftUI

/// 菜单栏三合一图标。
///
/// 外圈电量、中间 Wi-Fi、底部音量，构图对齐 iPhone Duo，几何取自
/// Status Trio（https://github.com/lingyired/status-trio ，Copyright 2026 lingyired，Apache-2.0）。
/// 外圈和音量点按同一套 120 单位坐标重新绘制。中间信号用系统 SF Symbol，不捆绑其渲染器。
enum DuoStatusIcon {
    static let menuPointSize: CGFloat = 18

    static func image(
        status: DuoMenuStatus,
        pointSize: CGFloat,
        appearance: NSAppearance,
        scale: CGFloat
    ) -> NSImage {
        let resolvedScale = max(1, scale)
        let pixels = max(1, Int((pointSize * resolvedScale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }
        rep.size = NSSize(width: pointSize, height: pointSize)
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(bitmapImageRep: rep)
        graphics?.imageInterpolation = .high
        NSGraphicsContext.current = graphics
        appearance.performAsCurrentDrawingAppearance {
            draw(status: status, in: CGRect(x: 0, y: 0, width: pointSize, height: pointSize))
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    static func draw(status: DuoMenuStatus, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let ink = menuInk()
        let foreground = ink.color.cgColor
        context.saveGState()
        context.clear(rect)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / Art.canvas, y: -(rect.height / Art.canvas))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        drawBattery(status, foreground: foreground, lightInk: ink.light, in: context)
        drawVolume(status, foreground: foreground, in: context)
        context.restoreGState()
        drawCenterSymbol(status.link, color: ink.color, in: rect)
    }

    /// 浅色菜单栏用深色墨水，深色或蓝色菜单栏用接近系统模板图标的白。
    /// 两种都是不透明色，避免半透明叠在菜单栏上发灰，也避免纯白发硬。
    private static func menuInk() -> (color: NSColor, light: Bool) {
        let match = NSAppearance.currentDrawing().bestMatch(from: [
            .darkAqua, .aqua, .vibrantDark, .vibrantLight
        ])
        let light = match == .darkAqua || match == .vibrantDark
        if light {
            return (NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1), true)
        }
        return (NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1), false)
    }

    private static func drawBattery(
        _ status: DuoMenuStatus,
        foreground: CGColor,
        lightInk: Bool,
        in context: CGContext
    ) {
        let gap: CGFloat = status.batteryTone == .charging ? Art.boltGap : 0
        let track = Art.batteryPath(from: 0, to: 1, gap: gap)
        context.setLineWidth(Art.ringWidth)
        context.setStrokeColor(foreground.copy(alpha: Art.inactive) ?? foreground)
        context.addPath(track)
        context.strokePath()

        let progress = Double(min(100, max(0, status.batteryPercent))) / 100
        if progress > 0 {
            context.setLineWidth(Art.ringWidth)
            context.setStrokeColor(batteryColor(status.batteryTone, foreground: foreground, lightInk: lightInk))
            context.addPath(Art.batteryPath(from: 0, to: progress, gap: gap))
            context.strokePath()
        }

        guard status.batteryTone == .charging else { return }
        context.setFillColor(batteryColor(.charging, foreground: foreground, lightInk: lightInk))
        context.addPath(Art.bolt())
        context.fillPath()
    }

    /// 中间信号用 SF Symbol。SF Symbol 的墨水不在 `NSImage.size` 中心（Status Trio #30），
    /// 所以按可见像素的中心对齐到圆环几何中心，而不是按图片外框居中。
    private static func drawCenterSymbol(_ link: DuoLink, color: NSColor, in rect: CGRect) {
        let name: String
        let variable: Double
        switch link {
        case .wifi(let bars, true):
            name = "wifi"
            variable = Double(min(3, max(0, bars))) / 3
        case .wifi(_, false):
            name = "wifi.exclamationmark"
            variable = 1
        case .wifiIdle:
            name = "wifi"
            variable = 0
        case .wifiOff, .offline:
            name = "wifi.slash"
            variable = 1
        case .ethernet:
            name = "cable.connector"
            variable = 1
        }

        let side = rect.width * (60 / Art.canvas)
        let weight = NSImage.SymbolConfiguration(pointSize: max(8, side), weight: .bold)
        let hierarchical = NSImage.SymbolConfiguration(hierarchicalColor: color)
        guard let image = NSImage(
            systemSymbolName: name,
            variableValue: variable,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(weight.applying(hierarchical)),
              image.size.width > 0, image.size.height > 0 else { return }
        image.isTemplate = false

        let target = CGPoint(
            x: rect.minX + rect.width * (Art.centerX / Art.canvas),
            y: rect.maxY - rect.height * (Art.batteryCenter.y / Art.canvas)
        )
        let ink = inkCenter(of: image, key: "\(name)|bold|\(variable)|\(Int((side * 10).rounded()))")
        let scaleX = side / image.size.width
        let scaleY = side / image.size.height
        let origin = CGPoint(x: target.x - ink.x * scaleX, y: target.y - ink.y * scaleY)
        image.draw(
            in: CGRect(origin: origin, size: CGSize(width: side, height: side)),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    private static var inkCache: [String: CGPoint] = [:]

    /// 可见墨水中心，坐标系和 `NSImage.draw(in:)` 一致：左下角为原点。
    /// 阈值压得很低，浅色的未点亮弧也算进墨水框，避免一格信号时整颗图标往下掉。
    private static func inkCenter(of image: NSImage, key: String) -> CGPoint {
        if let cached = inkCache[key] { return cached }
        let fallback = CGPoint(x: image.size.width / 2, y: image.size.height / 2)
        let measured = measureInkCenter(of: image) ?? fallback
        inkCache[key] = measured
        return measured
    }

    private static func measureInkCenter(of image: NSImage) -> CGPoint? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let pixelsWide = max(1, Int((image.size.width * 4).rounded()))
        let pixelsHigh = max(1, Int((image.size.height * 4).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = image.size
        if let data = rep.bitmapData {
            memset(data, 0, rep.bytesPerRow * pixelsHigh)
        }
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(bitmapImageRep: rep)
        graphics?.imageInterpolation = .none
        NSGraphicsContext.current = graphics
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        let bytesPerPixel = max(1, rep.bitsPerPixel / 8)
        let alphaIndex = rep.bitmapFormat.contains(.alphaFirst) ? 0 : bytesPerPixel - 1
        var minX = pixelsWide
        var minY = pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<pixelsHigh {
            let row = data.advanced(by: y * rep.bytesPerRow)
            for x in 0..<pixelsWide {
                let alpha = row[x * bytesPerPixel + alphaIndex]
                guard alpha > 8 else { continue }
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGPoint(
            x: (CGFloat(minX + maxX) / 2) / CGFloat(pixelsWide) * image.size.width,
            y: (CGFloat(minY + maxY) / 2) / CGFloat(pixelsHigh) * image.size.height
        )
    }

    private static func drawVolume(_ status: DuoMenuStatus, foreground: CGColor, in context: CGContext) {
        let quiet = foreground.copy(alpha: Art.inactive) ?? foreground
        let activeCount = status.volumeScalar == nil ? 0 : status.volumeBars
        for (index, point) in Art.volumeDots.enumerated() {
            context.setFillColor(index < activeCount ? foreground : quiet)
            let radius = Art.volumeRadius
            context.fillEllipse(in: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
    }

    private static func batteryColor(_ tone: DuoBatteryTone, foreground: CGColor, lightInk: Bool) -> CGColor {
        switch tone {
        case .charging:
            return lightInk
                ? CGColor(red: 48 / 255, green: 209 / 255, blue: 88 / 255, alpha: 1)
                : CGColor(red: 28 / 255, green: 148 / 255, blue: 62 / 255, alpha: 1)
        case .lowPower:
            return lightInk
                ? CGColor(red: 255 / 255, green: 214 / 255, blue: 10 / 255, alpha: 1)
                : CGColor(red: 184 / 255, green: 134 / 255, blue: 0, alpha: 1)
        case .critical:
            return lightInk
                ? CGColor(red: 255 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)
                : CGColor(red: 215 / 255, green: 0, blue: 21 / 255, alpha: 1)
        case .normal, .absent:
            return foreground
        }
    }
}

private enum Art {
    static let canvas: CGFloat = 120
    static let centerX: CGFloat = 59.5
    static let batteryCenter = CGPoint(x: centerX, y: 61.48715261785473)
    static let batteryRadius: CGFloat = 51.5
    static let batteryStart = 148.69008689281117 * CGFloat.pi / 180
    static let batterySweep = 242.6198262143777 * CGFloat.pi / 180
    static let ringWidth: CGFloat = 8
    static let boltGap: CGFloat = 50
    static let inactive: CGFloat = 0.22
    static let volumeRadius: CGFloat = 5.5
    static let volumeDots = [
        CGPoint(x: 33, y: 104.2),
        CGPoint(x: 50.5, y: 111.2),
        CGPoint(x: 68.5, y: 111.7),
        CGPoint(x: 86, y: 105.8)
    ]

    static func batteryPath(from start: Double, to end: Double, gap: CGFloat) -> CGPath {
        let clampedStart = min(1, max(0, start))
        let clampedEnd = min(1, max(0, end))
        guard clampedEnd > clampedStart else { return CGMutablePath() }
        let path = CGMutablePath()
        guard gap > 0 else {
            path.addPath(arc(from: clampedStart, to: clampedEnd))
            return path
        }

        let gapFraction = min(1, Double(gap / (batteryRadius * batterySweep)))
        let gapStart = (1 - gapFraction) / 2
        let gapEnd = gapStart + gapFraction
        let firstEnd = min(clampedEnd, gapStart)
        if firstEnd > clampedStart {
            path.addPath(arc(from: clampedStart, to: firstEnd))
        }
        let secondStart = max(clampedStart, gapEnd)
        if clampedEnd > secondStart {
            path.addPath(arc(from: secondStart, to: clampedEnd))
        }
        return path
    }

    static func bolt() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 63.4, y: 3.2))
        path.addLine(to: CGPoint(x: 55.2, y: 14.4))
        path.addLine(to: CGPoint(x: 60.4, y: 14.4))
        path.addLine(to: CGPoint(x: 55.8, y: 24.8))
        path.addLine(to: CGPoint(x: 67.2, y: 12.2))
        path.addLine(to: CGPoint(x: 61.4, y: 12.2))
        path.closeSubpath()
        return path
    }

    private static func arc(from start: Double, to end: Double) -> CGPath {
        let path = CGMutablePath()
        path.addArc(
            center: batteryCenter,
            radius: batteryRadius,
            startAngle: batteryStart + batterySweep * CGFloat(start),
            endAngle: batteryStart + batterySweep * CGFloat(end),
            clockwise: false
        )
        return path
    }
}

struct DuoStatusIconView: View {
    var status: DuoMenuStatus
    var pointSize: CGFloat = DuoStatusIcon.menuPointSize
    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            ?? NSAppearance(named: .aqua)!
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        Image(nsImage: DuoStatusIcon.image(
            status: status,
            pointSize: pointSize,
            appearance: appearance,
            scale: scale
        ))
        .interpolation(.high)
        .frame(width: pointSize, height: pointSize)
        .accessibilityHidden(true)
    }
}
