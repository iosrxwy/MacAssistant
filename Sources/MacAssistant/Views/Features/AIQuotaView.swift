import AppKit
import MacAssistantKit
import SwiftUI

enum AIQuotaFormat {
    static func menuTitle(_ snapshots: [AIQuotaSnapshot]) -> String {
        let ready = snapshots.compactMap { snapshot -> (String, Int)? in
            guard snapshot.state == .ready, let percent = snapshot.headline?.remainingPercent else { return nil }
            return (snapshot.id.displayName, percent)
        }
        guard let worst = ready.min(by: { $0.1 < $1.1 }) else { return "" }
        if ready.count == 1 { return "\(worst.1)%" }
        return "\(worst.0) \(worst.1)%"
    }

    static func countdown(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return L("aiquota.reset.now") }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return hours > 0 ? L("aiquota.time.dayHour", days, hours) : L("aiquota.time.day", days)
        }
        if hours > 0 {
            return minutes > 0 ? L("aiquota.time.hourMinute", hours, minutes) : L("aiquota.time.hour", hours)
        }
        return L("aiquota.time.minute", max(minutes, 1))
    }

    /// 重置的具体时间，跟界面语言走。没有日期时返回空字符串。
    static func resetMoment(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
        return formatter.string(from: date)
    }

    private static var displayLocale: Locale {
        switch LocalizationSettings.current {
        case .system:
            return .autoupdatingCurrent
        default:
            return Locale(identifier: LocalizationSettings.current.rawValue)
        }
    }

    static func windowTitle(_ window: AIQuotaWindow) -> String {
        if let key = window.titleKey, !key.isEmpty { return L(key) }
        return window.title
    }

    static func stateText(_ state: AIQuotaState) -> String {
        switch state {
        case .loading: return L("aiquota.loading")
        case .ready: return ""
        case .notSignedIn: return L("aiquota.notSignedIn")
        case .needsKeychain: return L("aiquota.needsKeychain")
        case .expired: return L("aiquota.expired")
        case .unavailable: return L("aiquota.unavailable")
        case .failed: return L("aiquota.failed")
        }
    }

    static func accent(_ id: AIQuotaProviderID) -> Color {
        switch id {
        case .cursor: return Color(red: 0.45, green: 0.38, blue: 0.95)
        case .codex: return Color(red: 0.18, green: 0.72, blue: 0.48)
        case .gemini: return Color(red: 0.22, green: 0.48, blue: 0.96)
        case .claude: return Color(red: 0.86, green: 0.48, blue: 0.32)
        case .grok: return Color(red: 0.20, green: 0.45, blue: 0.95)
        case .grokBot: return Color(red: 0.95, green: 0.55, blue: 0.20)
        case .muse: return Color(red: 0.55, green: 0.36, blue: 0.95)
        }
    }

    static func remainingColor(_ remaining: Double) -> Color {
        if remaining <= 0.05 { return .red }
        if remaining <= 0.2 { return .orange }
        return .primary
    }

    static func waterTint(_ remaining: Double, accent: Color) -> Color {
        if remaining <= 0.05 { return .red }
        if remaining <= 0.2 { return .orange }
        return accent
    }
}

/// 水位采样。`level` 是剩余比例，0 在底部。SwiftUI 用 `topOrigin`，AppKit 图标层用底边原点。
enum QuotaWaterline {
    static func phase(at date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate * 3.3)
    }

    static func dockTint(_ remaining: Double) -> Color {
        if remaining <= 0.05 { return .red }
        if remaining <= 0.2 { return .orange }
        return Color(red: 0.08, green: 0.34, blue: 0.72)
    }

    static func surface(in rect: CGRect, level: CGFloat, phase: CGFloat, topOrigin: Bool, steps: Int = 42) -> [CGPoint] {
        let clamped = min(1, max(0, level))
        let amplitude = amplitude(span: rect.height, level: clamped)
        let base = topOrigin
            ? rect.minY + rect.height * (1 - clamped)
            : rect.minY + rect.height * clamped
        var points: [CGPoint] = []
        points.reserveCapacity(steps + 1)
        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps)
            let x = rect.minX + rect.width * t
            let wave = sin(t * .pi * 2 * 1.5 + phase) * amplitude
                + sin(t * .pi * 2 * 2.5 + phase * 1.5) * amplitude * 0.38
            points.append(CGPoint(x: x, y: base + wave))
        }
        return points
    }

    static func amplitude(span: CGFloat, level: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, level))
        let base = min(3.2, max(1.4, span * 0.028))
        let room = min(clamped, 1 - clamped) * span
        return min(base, max(0, room * 0.45))
    }

    static func tankPath(in rect: CGRect, points: [CGPoint]) -> Path? {
        guard let first = points.first else { return nil }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY + 2))
        path.addLine(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + 2))
        path.closeSubpath()
        return path
    }

    static func crestPath(_ points: [CGPoint]) -> Path? {
        guard let first = points.first else { return nil }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    static func paintBar(
        context: inout GraphicsContext,
        size: CGSize,
        level: Double,
        phase: CGFloat,
        tint: Color,
        onDark: Bool
    ) {
        let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
        context.fill(track, with: .color(onDark ? Color.white.opacity(0.14) : Color.primary.opacity(0.08)))
        let clamped = min(1, max(0, level))
        guard clamped > 0.004 else { return }
        context.clip(to: track)
        let fillWidth = size.width * CGFloat(clamped)
        let amp = min(2.6, max(1.1, size.height * 0.22))
        let steps = 36
        func crestY(_ t: CGFloat) -> CGFloat {
            amp * 0.45
                + sin(t * .pi * 2 * 1.5 + phase) * amp
                + sin(t * .pi * 2 * 2.5 + phase * 1.5) * amp * 0.35
        }
        var water = Path()
        water.move(to: CGPoint(x: 0, y: size.height + 1))
        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps)
            water.addLine(to: CGPoint(x: fillWidth * t, y: crestY(t)))
        }
        water.addLine(to: CGPoint(x: fillWidth, y: size.height + 1))
        water.closeSubpath()
        context.fill(
            water,
            with: .linearGradient(
                Gradient(colors: [tint.opacity(0.72), tint]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        guard let crest = crestPath((0...steps).map { index in
            let t = CGFloat(index) / CGFloat(steps)
            return CGPoint(x: fillWidth * t, y: crestY(t))
        }) else { return }
        context.stroke(crest, with: .color(.white.opacity(0.42)), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
        context.stroke(crest, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        let cycle = phase / (.pi * 2)
        let travel = cycle - floor(cycle)
        context.fill(
            Path(CGRect(x: fillWidth * travel - 16, y: 0, width: 22, height: size.height)),
            with: .color(.white.opacity(0.16))
        )
    }
}

struct WaterLevelBar: View, Animatable {
    var fraction: Double
    var tint: Color
    var onDark = false
    var height: CGFloat = 12

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                QuotaWaterline.paintBar(
                    context: &context,
                    size: size,
                    level: fraction,
                    phase: QuotaWaterline.phase(at: timeline.date),
                    tint: tint,
                    onDark: onDark
                )
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(Int((min(1, max(0, fraction)) * 100).rounded()))%")
    }
}

struct WaterLevelMark: View {
    var image: NSImage
    var fraction: Double
    var percentText: String
    var size: CGFloat

    @State private var shown = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = QuotaWaterline.phase(at: timeline.date)
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                Canvas { context, canvasSize in
                    let rect = CGRect(origin: .zero, size: canvasSize)
                    let tint = QuotaWaterline.dockTint(fraction)
                    let front = QuotaWaterline.surface(in: rect, level: CGFloat(shown), phase: phase, topOrigin: true)
                    let back = QuotaWaterline.surface(in: rect, level: CGFloat(shown), phase: phase + 1.7, topOrigin: true)
                    if let backPath = QuotaWaterline.tankPath(in: rect, points: back) {
                        context.fill(backPath, with: .color(tint.opacity(0.24)))
                    }
                    if let frontPath = QuotaWaterline.tankPath(in: rect, points: front) {
                        context.fill(
                            frontPath,
                            with: .linearGradient(
                                Gradient(colors: [tint.opacity(0.30), tint.opacity(0.66)]),
                                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                            )
                        )
                    }
                    if let crest = QuotaWaterline.crestPath(front) {
                        context.stroke(
                            crest,
                            with: .color(.white.opacity(0.40)),
                            style: StrokeStyle(lineWidth: max(4.5, size * 0.055), lineCap: .round, lineJoin: .round)
                        )
                        context.stroke(
                            crest,
                            with: .color(.white.opacity(0.95)),
                            style: StrokeStyle(lineWidth: max(1.6, size * 0.02), lineCap: .round, lineJoin: .round)
                        )
                    }
                }
                Text(percentText)
                    .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, size * 0.1)
            }
        }
        .frame(width: size, height: size)
        .mask {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.05)) { shown = fraction }
        }
        .onChange(of: fraction) { value in
            withAnimation(.easeOut(duration: 0.7)) { shown = value }
        }
        .accessibilityLabel(percentText)
    }
}

struct AIQuotaView: View {
    @ObservedObject private var quota = AIQuotaCenter.shared

    var body: some View {
        FeatureScaffold(title: SidebarItem.aiQuota.title, subtitle: L("aiquota.subtitle")) {
            VStack(alignment: .leading, spacing: 16) {
                if quota.dockHoverEnabled, !quota.accessibilityTrusted {
                    accessibilityBanner
                }
                if quota.snapshots.contains(where: { $0.state == .needsKeychain }) {
                    keychainBanner
                }
                AIQuotaPanel(showsPower: false, onOpenPage: nil)
                settings
                Text(L("aiquota.privacy"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accessibilityBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("aiquota.accessibility.title")).font(.headline)
                Text(L("aiquota.accessibility.body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L("aiquota.accessibility.button")) {
                quota.requestAccessibility()
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var keychainBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "key")
                .foregroundStyle(.orange)
            Text(L("aiquota.needsKeychain"))
                .font(.callout)
            Spacer(minLength: 8)
            Button(L("aiquota.authorize")) {
                quota.refresh(interactive: true)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("aiquota.settings")).font(.headline)
            toggle(L("aiquota.menuBar"), L("aiquota.menuBar.detail"), $quota.menuBarEnabled)
            toggle(L("aiquota.dockHover"), L("aiquota.dockHover.detail"), $quota.dockHoverEnabled)
            toggle(L("aiquota.dockDetail"), L("aiquota.dockDetail.detail"), $quota.dockDetailEnabled)
            toggle(L("aiquota.dockAlways"), L("aiquota.dockAlways.detail"), $quota.dockAlwaysEnabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toggle(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

struct AIQuotaPopover: View {
    var onOpenPage: () -> Void

    var body: some View {
        AIQuotaPanel(showsPower: true, onOpenPage: onOpenPage)
            .padding(10)
            .frame(width: 720, height: 490)
    }
}

struct AIQuotaPanel: View {
    @ObservedObject private var quota = AIQuotaCenter.shared
    var showsPower: Bool
    var onOpenPage: (() -> Void)?
    @State private var selection: AIQuotaProviderID?

    private var rows: [AIQuotaSnapshot] {
        quota.snapshots.filter { $0.state == .ready && $0.headline != nil }
    }

    private var selected: AIQuotaSnapshot? {
        let id = selection ?? rows.first?.id
        return rows.first { $0.id == id } ?? rows.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    list
                        .frame(width: 248)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            Divider()
            footer
        }
        .frame(minHeight: rows.isEmpty ? 180 : 320)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if quota.refreshing {
                ProgressView()
                Text(L("aiquota.refreshing"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(L("aiquota.emptyDetail"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(24)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(rows) { snapshot in
                    Button {
                        selection = snapshot.id
                    } label: {
                        row(snapshot)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func row(_ snapshot: AIQuotaSnapshot) -> some View {
        let active = selected?.id == snapshot.id
        let accent = AIQuotaFormat.accent(snapshot.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                icon(snapshot.id, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.id.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let headline = snapshot.headline {
                        Text(resetLine(headline, includeMoment: false))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let resets = snapshot.resets, resets.availableCount > 0 {
                        Text(L("aiquota.resets.short", resets.availableCount))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let percent = snapshot.headline?.remainingPercent {
                    Text("\(percent)%")
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(AIQuotaFormat.remainingColor(snapshot.headline?.remainingFraction ?? 1))
                        .frame(width: 48, alignment: .trailing)
                }
            }
            if let headline = snapshot.headline {
                WaterLevelBar(
                    fraction: headline.remainingFraction,
                    tint: AIQuotaFormat.waterTint(headline.remainingFraction, accent: accent),
                    height: 7
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? accent.opacity(0.16) : Color.clear)
        }
        .contentShape(Rectangle())
    }

    private func resetLine(_ window: AIQuotaWindow, includeMoment: Bool) -> String {
        let title = AIQuotaFormat.windowTitle(window)
        var parts = [title]
        let countdown = AIQuotaFormat.countdown(window.resetsAt)
        if !countdown.isEmpty { parts.append(countdown) }
        if includeMoment {
            let moment = AIQuotaFormat.resetMoment(window.resetsAt)
            if !moment.isEmpty { parts.append(moment) }
        }
        return parts.joined(separator: " · ")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let snapshot = selected, let headline = snapshot.headline {
                HStack(alignment: .center, spacing: 14) {
                    WaterLevelMark(
                        image: AIQuotaIcons.image(for: snapshot.id),
                        fraction: headline.remainingFraction,
                        percentText: "\(headline.remainingPercent)%",
                        size: 76
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(snapshot.id.displayName).font(.title3.weight(.semibold))
                            if let plan = snapshot.plan, !plan.isEmpty {
                                Text(plan)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(AIQuotaFormat.accent(snapshot.id).opacity(0.16), in: Capsule())
                            }
                        }
                        Text(L("aiquota.remaining", headline.remainingPercent))
                            .font(.title2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(AIQuotaFormat.remainingColor(headline.remainingFraction))
                        Text(resetLine(headline, includeMoment: true))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        quota.refresh(interactive: false)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L("aiquota.refresh"))
                    .disabled(quota.refreshing)
                }
                VStack(spacing: 12) {
                    ForEach(snapshot.windows) { window in
                        windowRow(window, accent: AIQuotaFormat.accent(snapshot.id), showsMoment: true)
                    }
                }
                if let resets = snapshot.resets, resets.availableCount > 0 {
                    resetsBlock(resets, onDark: false)
                }
                Text(snapshot.note ?? usedLine(snapshot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func windowRow(_ window: AIQuotaWindow, accent: Color, showsMoment: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            QuotaMeterColumns(
                title: AIQuotaFormat.windowTitle(window),
                percent: window.remainingPercent,
                remaining: window.remainingFraction,
                countdown: AIQuotaFormat.countdown(window.resetsAt),
                onDark: false
            )
            WaterLevelBar(
                fraction: window.remainingFraction,
                tint: AIQuotaFormat.waterTint(window.remainingFraction, accent: accent)
            )
            .animation(.easeOut(duration: 0.9), value: window.remainingFraction)
            if showsMoment, let moment = momentText(window.resetsAt) {
                Text(moment)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func resetsBlock(_ resets: AIQuotaResets, onDark: Bool) -> some View {
        let secondary: Color = onDark ? .white.opacity(0.62) : .secondary
        let upcoming = resets.expiries.filter { $0.timeIntervalSinceNow > -60 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("aiquota.resets.title"))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("aiquota.resets.count", resets.availableCount))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .frame(width: QuotaMeterColumns.valueWidth, alignment: .trailing)
            }
            ForEach(Array(upcoming.enumerated()), id: \.offset) { _, date in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L("aiquota.resets.expires"))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(AIQuotaFormat.resetMoment(date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .frame(width: QuotaMeterColumns.valueWidth, alignment: .trailing)
                }
            }
        }
    }

    private func momentText(_ date: Date?) -> String? {
        let moment = AIQuotaFormat.resetMoment(date)
        return moment.isEmpty ? nil : L("aiquota.reset.at", moment)
    }

    private func usedLine(_ snapshot: AIQuotaSnapshot) -> String {
        guard let window = snapshot.headline else { return "" }
        return L("aiquota.used", window.usedPercent)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(quota.refreshing ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(quota.refreshing ? L("aiquota.refreshing") : L("aiquota.running"))
                    .font(.caption)
            }
            Button(L("aiquota.refresh")) {
                quota.refresh(interactive: false)
            }
            .disabled(quota.refreshing)
            Spacer()
            if let onOpenPage {
                Button {
                    onOpenPage()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help(L("aiquota.openPage"))
            }
            if showsPower {
                Button {
                    quota.menuBarEnabled = false
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help(L("aiquota.menuBar"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func icon(_ id: AIQuotaProviderID, size: CGFloat) -> some View {
        Image(nsImage: AIQuotaIcons.image(for: id))
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

struct AIQuotaHoverCard: View {
    var snapshot: AIQuotaSnapshot

    /// 标题是图标上的剩余，每一行是设置页那种已用。两条说的是同一池子。
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !snapshot.windows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.windows.prefix(4)) { window in
                        poolRow(window)
                    }
                }
            }
            if let resets = snapshot.resets, resets.availableCount > 0 {
                resetsLine(resets)
            }
            if let note = snapshot.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }

    static func preferredHeight(for snapshot: AIQuotaSnapshot) -> CGFloat {
        let rows = min(snapshot.windows.count, 4)
        let plan: CGFloat = (snapshot.plan?.isEmpty == false) ? 16 : 0
        let header: CGFloat = snapshot.headline == nil ? 22 : 42
        let rowBlock: CGFloat = rows == 0 ? 0 : CGFloat(rows) * 28 + CGFloat(rows - 1) * 10
        let note: CGFloat = (snapshot.note?.isEmpty == false) ? 34 : 0
        let resets: CGFloat = (snapshot.resets?.availableCount ?? 0) > 0 ? 20 : 0
        let sections = 1 + (rows > 0 ? 1 : 0) + (note > 0 ? 1 : 0) + (resets > 0 ? 1 : 0)
        let gaps = CGFloat(max(sections - 1, 0)) * 12
        return 28 + plan + header + rowBlock + note + resets + gaps + 6
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let plan = snapshot.plan, !plan.isEmpty {
                Text(plan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(AIQuotaFormat.accent(snapshot.id))
                    .frame(width: 6, height: 6)
                Text(snapshot.id.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let window = snapshot.headline {
                    Text(L("aiquota.remaining", window.remainingPercent))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(AIQuotaFormat.remainingColor(window.remainingFraction))
                        .lineLimit(1)
                }
            }
            if let window = snapshot.headline {
                let countdown = AIQuotaFormat.countdown(window.resetsAt)
                if !countdown.isEmpty {
                    Text(countdown)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 14)
                }
            }
        }
    }

    private func poolRow(_ window: AIQuotaWindow) -> some View {
        let accent = AIQuotaFormat.accent(snapshot.id)
        let tint = AIQuotaFormat.waterTint(window.remainingFraction, accent: accent)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(AIQuotaFormat.windowTitle(window))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(L("aiquota.used", window.usedPercent))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HoverQuotaBar(fraction: window.usedFraction, tint: tint)
        }
    }

    private func resetsLine(_ resets: AIQuotaResets) -> some View {
        let soonest = resets.expiries.first { $0.timeIntervalSinceNow > -60 }
        let moment = AIQuotaFormat.resetMoment(soonest)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L("aiquota.resets.short", resets.availableCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !moment.isEmpty {
                Text(L("aiquota.reset.at", moment))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// 悬停卡片上的已用条。平的细线，不要液面。1% 是一个小点，不是快满的剩余条。
private struct HoverQuotaBar: View {
    var fraction: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let clamped = min(1, max(0, fraction))
            let fill = clamped > 0.001 ? max(3, geo.size.width * clamped) : 0
            Capsule()
                .fill(Color.primary.opacity(0.10))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: fill)
                }
        }
        .frame(height: 3)
        .accessibilityLabel("\(Int((min(1, max(0, fraction)) * 100).rounded()))%")
    }
}

/// 窗口名靠左，剩余百分比和重置倒计时各占一列靠右，行与行对齐。
private struct QuotaMeterColumns: View {
    var title: String
    var percent: Int
    var remaining: Double
    var countdown: String
    var onDark: Bool

    static let percentWidth: CGFloat = 52
    static let countdownWidth: CGFloat = 108
    static var valueWidth: CGFloat { percentWidth + 10 + countdownWidth }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(percent)%")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(AIQuotaFormat.remainingColor(remaining))
                .frame(width: Self.percentWidth, alignment: .trailing)
            Text(countdown.isEmpty ? " " : countdown)
                .font(.caption.monospacedDigit())
                .foregroundStyle(onDark ? Color.white.opacity(0.62) : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: Self.countdownWidth, alignment: .trailing)
        }
    }
}

enum AIQuotaIcons {
    private static var cache: [AIQuotaProviderID: NSImage] = [:]

    static func image(for id: AIQuotaProviderID) -> NSImage {
        if let cached = cache[id] { return cached }
        let image = load(id)
        cache[id] = image
        return image
    }

    private static func load(_ id: AIQuotaProviderID) -> NSImage {
        for bundle in id.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 64, height: 64)
                return icon
            }
        }
        if let name = id.artworkName, let bundled = AIQuotaArtwork.image(named: name) {
            bundled.size = NSSize(width: 64, height: 64)
            return bundled
        }
        let symbol = NSImage(systemSymbolName: "app", accessibilityDescription: id.displayName) ?? NSImage()
        symbol.size = NSSize(width: 64, height: 64)
        return symbol
    }
}
