import SwiftUI
import AppKit
import MacAssistantKit

struct AboutView: View {
    @ObservedObject var updates: UpdateCoordinator
    @AppStorage(LocalizationSettings.defaultsKey) private var language = AppLanguage.system.rawValue
    @AppStorage(AppearancePreference.defaultsKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage(SidebarAppearance.defaultsKey) private var sidebarRaw = SidebarAppearance.material.rawValue
    @AppStorage(IconAppearance.defaultsKey) private var iconRaw = IconAppearance.monochrome.rawValue
    @AppStorage(IconAppearance.customDefaultsKey) private var iconCustomHex = "4f8fd4"
    @ObservedObject private var duo = DuoStatusBarController.shared

    /// 与检查更新用的是同一个版本号来源,避免页面显示和比较结果对不上。
    private var version: String { updates.currentVersion }

    /// 只有 Info.plist 里 MacAssistantBuildKind 明确带 Developer ID 且不含 ad-hoc 标记才算已公证发行版。
    /// 缺失、未知或含 ad-hoc 的一律按开发构建处理:宁可多给一次拦截提示,也绝不把未公证产物显示成已公证。
    private var isNotarizedRelease: Bool {
        let lower = buildKindText.lowercased()
        return lower.contains("developer id") && !lower.contains("ad-hoc")
    }

    private var isLocalCertificateBuild: Bool {
        buildKindText.lowercased().contains("local certificate")
    }

    private var buildKindText: String {
        (Bundle.main.object(forInfoDictionaryKey: "MacAssistantBuildKind") as? String) ?? ""
    }

    var body: some View {
        FeatureScaffold(title: SidebarItem.about.title, subtitle: L("about.tagline")) {
            Card {
                identityHeader
            }
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    languageRow
                    Divider().padding(.vertical, 12)
                    appearanceRow
                    Divider().padding(.vertical, 12)
                    sidebarAppearanceRow
                    Divider().padding(.vertical, 12)
                    iconAppearanceRow
                    Divider().padding(.vertical, 12)
                    duoStatusRow
                    Divider().padding(.vertical, 12)
                    updateBlock
                }
            }
            Card {
                SceneBackdropPicker()
            }
            Card {
                privacyBlock
            }
            footer
        }
    }

    /// 仓库最早提交在 2026，版权跨度从那时起到今年。
    private var copyrightText: String {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: Date())
        return L("about.copyright", startYear, currentYear)
    }

    private var identityHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityLabel(L("about.icon.accessibility"))

            VStack(alignment: .leading, spacing: 3) {
                Text(L("root.appName"))
                    .font(.title2.weight(.semibold))
                Text("\(L("about.version", version))  ·  \(L("about.developer"))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                buildKindBadge
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 18) {
                socialLink(
                    glyph: .github,
                    title: L("about.github"),
                    url: ProductLinks.github,
                    accessibilityLabel: L("about.github.accessibility"),
                    identifier: "about.github"
                )
                socialLink(
                    glyph: .x,
                    title: L("about.twitter"),
                    url: ProductLinks.twitter,
                    accessibilityLabel: L("about.twitter.accessibility"),
                    identifier: "about.twitter"
                )
                socialLink(
                    glyph: .telegram,
                    title: L("about.channel"),
                    url: ProductLinks.releaseChannel,
                    accessibilityLabel: L("about.channel.accessibility"),
                    identifier: "about.telegram"
                )
            }
            Text(copyrightText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    private func socialLink(
        glyph: BrandIcon.Glyph,
        title: String,
        url: URL,
        accessibilityLabel: String,
        identifier: String
    ) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                BrandIcon(glyph: glyph, size: 12)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout)
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(url.absoluteString)
        .accessibilityIdentifier(identifier)
    }

    private func settingsLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16, alignment: .center)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.body.weight(.medium))
        }
    }

    private var sidebarTranslucentBinding: Binding<Bool> {
        Binding(
            get: { SidebarAppearance.resolved(sidebarRaw) == .translucent },
            set: { sidebarRaw = ($0 ? SidebarAppearance.translucent : SidebarAppearance.material).rawValue }
        )
    }

    private var sidebarAppearanceRow: some View {
        HStack(spacing: 12) {
            settingsLabel(L("about.sidebar.title"), systemImage: "sidebar.left")
            Spacer(minLength: 12)
            Toggle("", isOn: sidebarTranslucentBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(L("about.sidebar.title"))
                .accessibilityHint(L("about.sidebar.detail"))
                .accessibilityIdentifier("about.sidebar")
        }
    }

    private var duoEnabledBinding: Binding<Bool> {
        Binding(
            get: { duo.isEnabled },
            set: { duo.setEnabled($0) }
        )
    }

    private var duoStatusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                settingsLabel(L("duo.title"), systemImage: "wifi")
                Spacer(minLength: 12)
                DuoStatusIconView(status: duo.status, pointSize: 26)
                    .accessibilityIdentifier("about.duo.preview")
                Toggle("", isOn: duoEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel(L("duo.enabled"))
                    .accessibilityHint(L("duo.detail"))
                    .accessibilityIdentifier("about.duo.enabled")
            }
            Text(L("duo.detail"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var iconAppearanceRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsLabel(L("about.iconStyle.title"), systemImage: "paintpalette")
            IconAppearanceSwatches(raw: $iconRaw, customHex: $iconCustomHex)
                .accessibilityLabel(L("about.iconStyle.title"))
                .accessibilityIdentifier("about.iconStyle")
        }
    }

    private var languageRow: some View {
        HStack(spacing: 12) {
            settingsLabel(L("about.language.title"), systemImage: "globe")
            Spacer(minLength: 12)
            Picker("", selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel(L("about.language.title"))
            .accessibilityIdentifier("about.language")
        }
    }

    private var appearanceRow: some View {
        HStack(spacing: 12) {
            settingsLabel(L("about.appearance.title"), systemImage: "circle.lefthalf.filled")
            Spacer(minLength: 12)
            Picker("", selection: $appearanceRaw) {
                ForEach(AppearancePreference.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel(L("about.appearance.title"))
            .accessibilityIdentifier("about.appearance")
        }
    }

    private var updateBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                settingsLabel(L("about.updates.title"), systemImage: "arrow.triangle.2.circlepath")
                Spacer(minLength: 12)
                if updates.isDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await updates.runManualCheck() }
                    } label: {
                        if updates.isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L("about.checkForUpdates"))
                        }
                    }
                    .disabled(updates.isChecking)
                    .accessibilityLabel(L("about.checkForUpdates.accessibility"))
                    .accessibilityIdentifier("about.checkForUpdates")
                }
            }

            HStack(spacing: 12) {
                settingsLabel(L("about.automaticUpdateCheck"), systemImage: "clock.arrow.circlepath")
                Spacer(minLength: 12)
                Toggle("", isOn: $updates.automaticCheckEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel(L("about.automaticUpdateCheck"))
                    .accessibilityHint(L("about.automaticUpdateCheck.hint"))
                    .accessibilityIdentifier("about.automaticUpdateCheck")
            }

            if let status = updates.statusText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .finished = updates.downloadState {
                        Button(L("about.revealDownload")) {
                            updates.revealDownloadedFile()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .accessibilityIdentifier("about.updateStatus")
            }
        }
    }

    private var privacyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("about.privacy"))
                .font(.headline)
            Text(L("about.privacy.detail"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buildKindBadge: some View {
        if isNotarizedRelease {
            Label(L("about.buildKind.notarized"), systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityIdentifier("about.buildKind")
        } else if isLocalCertificateBuild {
            Label(L("about.buildKind.localCertificate"), systemImage: "signature")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("about.buildKind")
        } else {
            Label(L("about.buildKind.development"), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("about.buildKind")
        }
    }
}

/// 黑白 / 彩色 + 文件改色同一套圆点 + 系统调色板。
private struct IconAppearanceSwatches: View {
    @Binding var raw: String
    @Binding var customHex: String
    @AppStorage(IconAppearance.colorSeedDefaultsKey) private var colorSeed = 0

    private let swatchSize: CGFloat = 20
    private var current: IconAppearance { IconAppearance.resolved(raw) }

    private let columns = [GridItem(.adaptive(minimum: 22, maximum: 26), spacing: 7)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
            modeSwatch(.monochrome, fill: AnyView(monochromeFill))
            modeSwatch(.color, fill: AnyView(rainbowFill))
            ForEach(IconAppearance.palettePresets) { preset in
                paletteSwatch(preset)
            }
            customSwatch
        }
    }

    private var monochromeFill: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.white, Color(white: 0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.8)
            }
    }

    private var rainbowFill: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [.red, .orange, .yellow, .green, .mint, .blue, .indigo, .purple, .red],
                    center: .center
                )
            )
    }

    private func modeSwatch(_ appearance: IconAppearance, fill: AnyView) -> some View {
        swatchButton(
            selected: current == appearance,
            title: appearance.title,
            identifier: "about.iconStyle.\(appearance.rawValue)"
        ) {
            if appearance == .color {
                colorSeed = SidebarIconShuffle.nextSeed()
            }
            raw = appearance.rawValue
        } fill: {
            fill
        }
    }

    private func paletteSwatch(_ preset: DesktopIconPreset) -> some View {
        let appearance = IconAppearance.palette(preset.key)
        return swatchButton(
            selected: current == appearance,
            title: appearance.title,
            identifier: "about.iconStyle.palette.\(preset.key)"
        ) {
            raw = appearance.rawValue
        } fill: {
            Circle().fill(Color(red: preset.red, green: preset.green, blue: preset.blue))
        }
    }

    private var customSwatch: some View {
        let appearance = IconAppearance.custom(hex: customHex)
        let rgb = appearance.rgb ?? (0.31, 0.56, 0.83)
        let selected = current.customHex != nil
        return swatchButton(
            selected: selected,
            title: IconAppearance.custom(red: rgb.0, green: rgb.1, blue: rgb.2).title,
            identifier: "about.iconStyle.custom"
        ) {
            raw = appearance.rawValue
            presentCustomPicker(red: rgb.0, green: rgb.1, blue: rgb.2)
        } fill: {
            Circle()
                .fill(Color(red: rgb.0, green: rgb.1, blue: rgb.2))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(customBadgeInk(rgb))
                }
        }
    }

    private func customBadgeInk(_ rgb: (Double, Double, Double)) -> Color {
        let luminance = 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
        return luminance > 0.62 ? Color(white: 0.16).opacity(0.88) : Color.white.opacity(0.92)
    }

    private func swatchButton<Fill: View>(
        selected: Bool,
        title: String,
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder fill: () -> Fill
    ) -> some View {
        Button(action: action) {
            fill()
                .frame(width: swatchSize, height: swatchSize)
                .overlay {
                    if selected {
                        Circle()
                            .strokeBorder(Color.appAccent, lineWidth: 2)
                            .padding(-3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }

    private func presentCustomPicker(red: Double, green: Double, blue: Double) {
        let initial = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        IconTintColorPanel.shared.present(color: initial) { color in
            let rgb = color.usingColorSpace(.sRGB) ?? color
            let picked = IconAppearance.custom(
                red: Double(rgb.redComponent),
                green: Double(rgb.greenComponent),
                blue: Double(rgb.blueComponent)
            )
            raw = picked.rawValue
            if let hex = picked.customHex {
                customHex = hex
            }
        }
    }
}

private final class IconTintColorPanel: NSObject {
    static let shared = IconTintColorPanel()
    var handler: ((NSColor) -> Void)?

    func present(color: NSColor, handler: @escaping (NSColor) -> Void) {
        self.handler = handler
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        handler?(sender.color)
    }
}
