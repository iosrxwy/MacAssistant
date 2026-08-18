import SwiftUI
import AppKit
import MacAssistantKit

private enum AboutLayout {
    /// 正文块统一宽度：说明文字、更新区与折叠项共用同一条左右边界。
    static let contentWidth: CGFloat = 520
}

struct AboutView: View {
    @ObservedObject var updates: UpdateCoordinator
    @AppStorage(LocalizationSettings.defaultsKey) private var language = AppLanguage.system.rawValue

    /// 与检查更新用的是同一个版本号来源,避免页面显示和比较结果对不上。
    private var version: String { updates.currentVersion }

    /// 只有 Info.plist 里 MacAssistantBuildKind 明确带 Developer ID 且不含 ad-hoc 标记才算已公证发行版。
    /// 缺失、未知或含 ad-hoc 的一律按开发构建处理:宁可多给一次拦截提示,也绝不把未公证产物显示成已公证。
    private var isNotarizedRelease: Bool {
        guard let kind = Bundle.main.object(forInfoDictionaryKey: "MacAssistantBuildKind") as? String else {
            return false
        }
        let lower = kind.lowercased()
        return lower.contains("developer id") && !lower.contains("ad-hoc")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .accessibilityLabel(L("about.icon.accessibility"))

            VStack(spacing: 5) {
                Text(L("root.appName"))
                    .font(.title2.weight(.semibold))
                Text(L("about.tagline"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(L("about.version", version))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L("about.developer"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)

            buildKindSection

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    publishButtons
                }
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        githubButton
                        twitterButton
                    }
                    telegramButton
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            languageSection
            updateSection

            Text(L("about.license"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AboutLayout.contentWidth)

            // 页面其余内容都是居中的短文本，折叠项的标签却必然靠左。收进卡片后左对齐
            // 是容器内的正常行为，不会显得偏离整页的居中轴线。
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    DisclosureGroup(L("about.thirdParty")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("about.thirdParty.detail"))
                            VStack(alignment: .leading, spacing: 6) {
                                Button(L("about.thirdParty.altSign")) {
                                    NSWorkspace.shared.open(ProductLinks.altSignProject)
                                }
                                Button(L("about.thirdParty.altStore")) {
                                    NSWorkspace.shared.open(ProductLinks.altStoreGitHub)
                                }
                                Button(L("about.thirdParty.xtool")) {
                                    NSWorkspace.shared.open(ProductLinks.xtoolProject)
                                }
                                Button(L("about.thirdParty.libimobiledevice")) {
                                    NSWorkspace.shared.open(ProductLinks.libimobiledevice)
                                }
                                Button(L("about.thirdParty.theos")) {
                                    NSWorkspace.shared.open(ProductLinks.theosProject)
                                }
                                Button(L("about.thirdParty.zsign")) {
                                    NSWorkspace.shared.open(ProductLinks.zsignProject)
                                }
                                Button(L("about.thirdParty.ipatool")) {
                                    NSWorkspace.shared.open(ProductLinks.ipatoolProject)
                                }
                                Button(L("about.thirdParty.classDump")) {
                                    NSWorkspace.shared.open(ProductLinks.classDumpProject)
                                }
                                Button(L("about.thirdParty.dsdump")) {
                                    NSWorkspace.shared.open(ProductLinks.dsdumpProject)
                                }
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }

                    Divider().padding(.vertical, 10)

                    DisclosureGroup(L("about.privacy")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("about.privacy.detail"))
                            Button(L("about.privacy.apple")) {
                                NSWorkspace.shared.open(ProductLinks.applePlatformSecurity)
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                }
                .font(.callout)
            }
            .frame(maxWidth: AboutLayout.contentWidth)

            }
            .frame(maxWidth: .infinity)
            .padding(32)
        }
        .featureSurfaceBackground()
        .navigationTitle(SidebarItem.about.title)
    }

    @ViewBuilder
    private var publishButtons: some View {
        githubButton
        twitterButton
        telegramButton
    }

    private var githubButton: some View {
        Button {
            NSWorkspace.shared.open(ProductLinks.github)
        } label: {
            Label("GitHub · iosrxwy", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .accessibilityLabel(L("about.github.accessibility"))
        .accessibilityHint(ProductLinks.github.absoluteString)
        .accessibilityIdentifier("about.github")
    }

    private var twitterButton: some View {
        Button {
            NSWorkspace.shared.open(ProductLinks.twitter)
        } label: {
            Label(L("about.twitter"), systemImage: "at")
        }
        .accessibilityLabel(L("about.twitter.accessibility"))
        .accessibilityHint(ProductLinks.twitter.absoluteString)
        .accessibilityIdentifier("about.twitter")
    }

    private var telegramButton: some View {
        Button {
            NSWorkspace.shared.open(ProductLinks.releaseChannel)
        } label: {
            Label(L("about.channel"), systemImage: "paperplane")
        }
        .accessibilityLabel(L("about.channel.accessibility"))
        .accessibilityHint(ProductLinks.releaseChannel.absoluteString)
        .accessibilityIdentifier("about.telegram")
    }

    private var languageSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Label(L("about.language.title"), systemImage: "globe")
                Picker("", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200)
                .accessibilityLabel(L("about.language.title"))
                .accessibilityIdentifier("about.language")
            }
            Text(L("about.language.detail"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: AboutLayout.contentWidth)
    }

    private var updateSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button {
                    Task { await updates.runManualCheck() }
                } label: {
                    if updates.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L("about.checkForUpdates"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(updates.isChecking)
                .accessibilityLabel(L("about.checkForUpdates.accessibility"))
                .accessibilityIdentifier("about.checkForUpdates")

                Toggle(L("about.automaticUpdateCheck"), isOn: $updates.automaticCheckEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityHint(L("about.automaticUpdateCheck.hint"))
                    .accessibilityIdentifier("about.automaticUpdateCheck")
            }

            Text(updates.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("about.updateStatus")

            Text(L("about.updatePrivacy"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: AboutLayout.contentWidth)
    }

    /// 如实区分构建种类:已公证发行版给出中性提示;开发构建（ad-hoc、未公证）明确警告
    /// macOS 可能拦截,并指引用户到「系统设置 → 隐私与安全性 → 仍要打开」。
    @ViewBuilder
    private var buildKindSection: some View {
        if isNotarizedRelease {
            Label(L("about.buildKind.notarized"), systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityIdentifier("about.buildKind")
        } else {
            VStack(spacing: 4) {
                Label(L("about.buildKind.development"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(L("about.buildKind.development.hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: AboutLayout.contentWidth)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("about.buildKind")
        }
    }
}
