import SwiftUI
import MacAssistantKit

struct MenuBarStatusView: View {
    @ObservedObject private var duo = DuoStatusBarController.shared

    var body: some View {
        FeatureScaffold(title: L("duo.title"), subtitle: L("duo.page")) {
            Card {
                HStack(alignment: .center, spacing: 16) {
                    DuoStatusIconView(status: duo.status, pointSize: 72)
                        .accessibilityIdentifier("menubar.preview")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(DuoStatusText.batteryTitle(duo.status))
                            .font(.title2.weight(.semibold))
                        Text(DuoStatusText.batterySubtitle(duo.status))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(L("duo.legend"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: enabledBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel(L("duo.enabled"))
                        .accessibilityIdentifier("menubar.enabled")
                }
            }

            DuoStatusDetail(model: duo, actions: duo.actions, bluetooth: duo.bluetooth, placement: .page)

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("duo.where.title"))
                        .font(.headline)
                    Text(L("duo.where.detail"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { duo.isEnabled },
            set: { duo.setEnabled($0) }
        )
    }

}
