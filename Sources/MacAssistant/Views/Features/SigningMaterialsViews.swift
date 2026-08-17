import SwiftUI
import MacAssistantKit

/// 选中证书后展开主题 / Team / 序列号。真正的「权限」在描述文件 entitlements 里。
struct CertificateDetailsDisclosure: View {
    let identity: SigningIdentity

    var body: some View {
        let details = SigningService.certificateDetails(for: identity)
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("signingtab.certificate.subject", details.subject))
                if let team = details.teamID {
                    Text(L("signingtab.certificate.team", team))
                }
                if let serial = details.serial {
                    Text(L("signingtab.certificate.serial", serial))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, 2)
        } label: {
            Label(L("signingtab.certificate.details"), systemImage: "person.text.rectangle")
                .font(.caption)
        }
    }
}

/// 读本地 .mobileprovision，展开已知能力的有/无列表。
struct ProfileCapabilitiesLoader: View {
    let profileURL: URL
    @State private var statuses: [ProfileCapabilityStatus] = []
    @State private var loadFailed = false
    @State private var expanded = true

    var body: some View {
        Group {
            if !statuses.isEmpty {
                ProfileCapabilitiesDisclosure(statuses: statuses, expanded: $expanded)
            } else if loadFailed {
                Text(L("signingtab.capabilities.loadFailed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: profileURL.path) {
            do {
                let info = try SigningService.readProfile(at: profileURL)
                statuses = try ProfileCapabilityCatalog.inspect(profile: info)
                loadFailed = false
                expanded = true
            } catch {
                statuses = []
                loadFailed = true
            }
        }
    }
}

struct ProfileCapabilitiesDisclosure: View {
    let statuses: [ProfileCapabilityStatus]
    @Binding var expanded: Bool

    private var presentCount: Int { statuses.filter(\.isGranted).count }
    private var absentCount: Int { statuses.count - presentCount }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(orderedStatuses) { status in
                    capabilityRow(status)
                }
            }
            .padding(.top, 4)
        } label: {
            Label(
                L("signingtab.capabilities.summary", presentCount, absentCount),
                systemImage: "list.bullet.rectangle"
            )
            .font(.caption)
        }
    }

    /// 已有在前，没有在后；组内保持目录顺序。
    private var orderedStatuses: [ProfileCapabilityStatus] {
        let present = statuses.filter(\.isGranted)
        let absent = statuses.filter { !$0.isGranted }
        return present + absent
    }

    private func capabilityRow(_ status: ProfileCapabilityStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: status.isGranted ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(status.isGranted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.displayName)
                if let detail = status.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Text(status.isGranted ? L("signingtab.capabilities.present") : L("signingtab.capabilities.absent"))
                .foregroundStyle(status.isGranted ? Color.green : Color.secondary)
        }
        .font(.caption)
    }
}
