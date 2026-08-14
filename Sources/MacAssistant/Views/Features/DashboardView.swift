import SwiftUI
import MacAssistantKit

struct DashboardView: View {
    @State private var snapshot = SystemInfoService.snapshot()

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 14)]

    var body: some View {
        FeatureScaffold(title: L("dashboard.title"), subtitle: L("dashboard.subtitle")) {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(snapshot.items) { item in
                    Card {
                        HStack(spacing: 12) {
                            Image(systemName: item.systemImage)
                                .font(.title2)
                                .frame(width: 34, height: 34)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label).font(.caption).foregroundStyle(.secondary)
                                Text(item.value).font(.callout.weight(.semibold))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("dashboard.usage")).font(.headline)
                    usageBar(title: L("dashboard.memory"), fraction: snapshot.memoryUsedFraction, text: snapshot.memoryUsedText, tint: .blue)
                    usageBar(title: L("dashboard.disk"), fraction: snapshot.diskUsedFraction, text: snapshot.diskUsedText, tint: .purple)
                    if let level = snapshot.batteryLevel {
                        usageBar(title: L("dashboard.battery"), fraction: level,
                                 text: "\(Int(level * 100))%\(snapshot.batteryState.map { " · \($0)" } ?? "")",
                                 tint: level < 0.2 ? .red : .green)
                    }
                }
            }
        } trailing: {
            Button {
                snapshot = SystemInfoService.snapshot()
            } label: {
                Label(L("dashboard.refresh"), systemImage: "arrow.clockwise")
            }
        }
    }

    private func usageBar(title: String, fraction: Double, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Gauge(value: min(1, max(0, fraction))) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(tint)
        }
    }
}
