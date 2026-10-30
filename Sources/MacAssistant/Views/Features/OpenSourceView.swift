import SwiftUI
import AppKit
import MacAssistantKit

struct OpenSourceView: View {
    private struct Credit: Identifiable {
        let id: String
        let title: String
        let url: URL
    }

    private var credits: [Credit] {
        [
            Credit(id: "altSign", title: L("about.thirdParty.altSign"), url: ProductLinks.altSignProject),
            Credit(id: "altStore", title: L("about.thirdParty.altStore"), url: ProductLinks.altStoreGitHub),
            Credit(id: "xtool", title: L("about.thirdParty.xtool"), url: ProductLinks.xtoolProject),
            Credit(id: "libimobiledevice", title: L("about.thirdParty.libimobiledevice"), url: ProductLinks.libimobiledevice),
            Credit(id: "theos", title: L("about.thirdParty.theos"), url: ProductLinks.theosProject),
            Credit(id: "zsign", title: L("about.thirdParty.zsign"), url: ProductLinks.zsignProject),
            Credit(id: "atbClone", title: L("about.thirdParty.atbClone"), url: ProductLinks.atbCloneProject),
            Credit(id: "classDump", title: L("about.thirdParty.classDump"), url: ProductLinks.classDumpProject),
            Credit(id: "dsdump", title: L("about.thirdParty.dsdump"), url: ProductLinks.dsdumpProject),
            Credit(id: "statusTrio", title: L("about.thirdParty.statusTrio"), url: ProductLinks.statusTrioProject),
            Credit(id: "moonvy", title: L("about.thirdParty.moonvy"), url: ProductLinks.moonvyFolderDressing),
        ]
    }

    var body: some View {
        FeatureScaffold(
            title: SidebarItem.opensource.title,
            subtitle: L("opensource.subtitle")
        ) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("opensource.license.title"))
                        .font(.headline)
                    Text(L("about.license"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("about.thirdParty"))
                        .font(.headline)
                    Text(L("about.thirdParty.detail"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                            if index > 0 {
                                Divider()
                            }
                            Button {
                                NSWorkspace.shared.open(credit.url)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(credit.title)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(credit.title)
                            .accessibilityHint(credit.url.absoluteString)
                            .accessibilityIdentifier("opensource.credit.\(credit.id)")
                        }
                    }
                }
            }
        }
    }
}
