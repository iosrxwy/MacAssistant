import SwiftUI
import AppKit

// MARK: - 品牌强调色
//
// 系统默认蓝会同时落在侧栏选中行、分段控件选中段和主按钮上，在 Liquid Glass 的半透明
// 底子上叠出好几块高饱和平涂色。这里改用低饱和的黛青，明度压低、饱和度收窄，大面积
// 平涂时不抢内容，也更贴合玻璃材质的冷色调。
//
// 深浅色各给一组取值：深色模式下背景变暗，同一个色会显得发闷，需要把明度提上去。

extension Color {
    static let appAccent = Color(nsColor: .appAccent)
}

extension NSColor {
    static let appAccent = NSColor(name: "AppAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.42, green: 0.75, blue: 0.74, alpha: 1)
            : NSColor(srgbRed: 0.11, green: 0.45, blue: 0.47, alpha: 1)
    }
}
