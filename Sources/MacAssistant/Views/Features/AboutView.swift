import SwiftUI
import AppKit
import MacAssistantKit

private enum AboutLayout {
    /// 正文块统一宽度：说明文字、更新区与折叠项共用同一条左右边界。
    static let contentWidth: CGFloat = 520
}

struct AboutView: View {
    @ObservedObject var updates: UpdateCoordinator

    /// 与检查更新用的是同一个版本号来源,避免页面显示和比较结果对不上。
    private var version: String { updates.currentVersion }

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
                Text("开发者 iosrxwy")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(ProductLinks.github)
                } label: {
                    Label("GitHub · iosrxwy", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityLabel(L("about.github.accessibility"))
                .accessibilityHint(ProductLinks.github.absoluteString)
                .accessibilityIdentifier("about.github")

                Button {
                    NSWorkspace.shared.open(ProductLinks.releaseChannel)
                } label: {
                    Label(L("about.channel"), systemImage: "paperplane")
                }
                .accessibilityLabel(L("about.channel.accessibility"))
                .accessibilityHint(ProductLinks.releaseChannel.absoluteString)
                .accessibilityIdentifier("about.telegram")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

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

    private var updateSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button {
                    Task { await updates.runManualCheck() }
                } label: {
                    if updates.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(updates.isChecking)
                .accessibilityLabel("检查是否有新版本")
                .accessibilityIdentifier("about.checkForUpdates")

                Toggle("自动检查更新", isOn: $updates.automaticCheckEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityHint("开启后每天最多自动检查一次")
                    .accessibilityIdentifier("about.automaticUpdateCheck")
            }

            Text(updates.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("about.updateStatus")

            Text("仅向 GitHub 查询版本号，不上传任何信息；不会自动下载或安装。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: AboutLayout.contentWidth)
    }
}
