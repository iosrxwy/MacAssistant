import SwiftUI

// MARK: - Liquid Glass 兼容层
//
// macOS 26 的 Liquid Glass 只在两个前提同时成立时启用:运行的系统是 26+,且用户没有打开
// "减弱透明度"。部署目标仍是 macOS 13,所有新 API 都包在 `if #available(macOS 26.0, *)` 里。
//
// 层级遵循系统规则：导航与交互控件使用 Liquid Glass，内容卡片保持清晰；
// 卡片内的行、字段、代码块和徽章只用分层语义色。
//
// 每个入口都带一份 `legacyFill`,即 macOS 26 之前原样使用的取色,保证旧系统零回归。

/// 运行时是否应该走 Liquid Glass 分支。
///
/// 单独抽出来是为了让"减弱透明度"这条辅助功能开关只在一个地方判断。
private func usesLiquidGlass(reduceTransparency: Bool) -> Bool {
    guard !reduceTransparency else { return false }
    if #available(macOS 26.0, *) { return true }
    return false
}

// MARK: - 内容层

private struct ContentSurfaceBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    let stroke: Color?

    func body(content: Content) -> some View {
        content
            .background(shape.fill(fill))
            .overlay {
                if let stroke { shape.strokeBorder(stroke) }
            }
    }
}

// MARK: - 内嵌层

private struct InsetSurfaceBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    let legacyFill: Color
    let glassFill: AnyShapeStyle
    let stroke: Color?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background(shape.fill(fill))
            .overlay {
                if let stroke {
                    shape.strokeBorder(stroke)
                }
            }
    }

    private var fill: AnyShapeStyle {
        usesLiquidGlass(reduceTransparency: reduceTransparency) ? glassFill : AnyShapeStyle(legacyFill)
    }
}

extension View {
    /// 内容卡片保持清晰；Liquid Glass 留给导航、工具栏和交互控件。
    func contentSurfaceBackground(
        _ shape: some InsettableShape,
        fill: Color,
        stroke: Color? = nil
    ) -> some View {
        modifier(ContentSurfaceBackground(shape: shape, fill: fill, stroke: stroke))
    }

    /// 内嵌层背景:玻璃层内部的行、字段、代码块、徽章。
    ///
    /// 这里不上玻璃(玻璃不能采样玻璃),只把填充色换成能透出下层玻璃的分层语义色。
    ///
    /// - Parameters:
    ///   - legacyFill: macOS 26 之前原样使用的取色。
    ///   - glassFill: macOS 26 下的填充;默认 `.quaternary`,足够区分层次又不糊住玻璃。
    func insetSurfaceBackground(
        _ shape: some InsettableShape,
        legacyFill: Color,
        glassFill: AnyShapeStyle = AnyShapeStyle(.quaternary),
        stroke: Color? = nil
    ) -> some View {
        modifier(
            InsetSurfaceBackground(
                shape: shape,
                legacyFill: legacyFill,
                glassFill: glassFill,
                stroke: stroke
            )
        )
    }

    /// 页面底板。macOS 26 下交还给系统,让 split view 的新材质透出来。
    func featureSurfaceBackground() -> some View {
        modifier(FeatureSurfaceBackground())
    }

    /// 滚动内容在工具栏/边缘处的渐隐。macOS 26 之前无对应行为。
    @ViewBuilder
    func softScrollEdgeEffect() -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
#else
        self
#endif
    }

    /// 主操作按钮样式。macOS 26 用系统玻璃按钮,旧系统保持调用方原有样式。
    @ViewBuilder
    func glassActionButtonStyle(prominent: Bool = false) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            self
        }
#else
        self
#endif
    }
}

private struct FeatureSurfaceBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesLiquidGlass(reduceTransparency: reduceTransparency) {
            // 给玻璃一个中性采样底，避免浅色壁纸把整页染成高饱和青蓝色。
            content.background(Color(nsColor: .windowBackgroundColor).opacity(0.62))
        } else {
            content.background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

// MARK: - 玻璃分组

/// 把同一屏内的多个玻璃元素并入一个采样区,拿到正确的融合与更好的渲染性能。
///
/// macOS 26 之前(或"减弱透明度"开启时)是纯透传,不引入任何布局变化。
struct GlassGroup<Content: View>: View {
    /// 形变阈值。必须小于内部布局容器的间距,否则静止状态下相邻玻璃就会粘连。
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), usesLiquidGlass(reduceTransparency: reduceTransparency) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
#else
        content()
#endif
    }
}
