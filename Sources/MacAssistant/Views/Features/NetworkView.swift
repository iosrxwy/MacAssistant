import SwiftUI
import MacAssistantKit

struct NetworkView: View {
    @State private var interfaces = NetworkService.localInterfaces()
    @State private var ports: [ListeningPort] = []
    @State private var publicIP = L("networkview.tapToFetch")
    @State private var loadingPublic = false
    @State private var pingHost = "apple.com"
    @State private var pingOutput = ""
    @State private var pinging = false

    var body: some View {
        FeatureScaffold(title: L("networkview.title"), subtitle: L("networkview.subtitle")) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("networkview.localIP")).font(.headline)
                    if interfaces.isEmpty {
                        Text(L("networkview.noInterfaces")).foregroundStyle(.secondary)
                    }
                    ForEach(interfaces) { iface in
                        HStack {
                            Label(iface.name, systemImage: "cable.connector").frame(width: 120, alignment: .leading)
                            Text(iface.ipv4).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            CopyButton(text: iface.ipv4)
                        }
                    }
                    Divider()
                    HStack {
                        Label(L("networkview.publicIP"), systemImage: "globe").frame(width: 130, alignment: .leading)
                        Text(publicIP).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button {
                            loadingPublic = true
                            DispatchQueue.global().async {
                                let ip = NetworkService.publicIP() ?? L("networkview.fetchFailed")
                                DispatchQueue.main.async { publicIP = ip; loadingPublic = false }
                            }
                        } label: {
                            Label(loadingPublic ? L("networkview.fetching") : L("networkview.fetch"), systemImage: "arrow.down.circle")
                        }.disabled(loadingPublic)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L("networkview.listeningPorts")).font(.headline)
                        Spacer()
                        Button {
                            ports = NetworkService.listeningPorts()
                        } label: { Label(L("networkview.refresh"), systemImage: "arrow.clockwise") }
                    }
                    if ports.isEmpty {
                        Text(L("networkview.portsEmpty")).foregroundStyle(.secondary)
                    } else {
                        ForEach(ports) { port in
                            HStack {
                                Text(port.command).frame(width: 140, alignment: .leading).lineLimit(1)
                                Text("pid \(port.pid)").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                Text(port.node).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                                Text(port.name).font(.callout.monospaced()).textSelection(.enabled)
                                Spacer()
                            }
                            .font(.callout)
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("networkview.ping")).font(.headline)
                    HStack {
                        TextField(L("networkview.ping.placeholder"), text: $pingHost).textFieldStyle(.roundedBorder)
                        Button {
                            pinging = true
                            pingOutput = ""
                            let host = pingHost
                            DispatchQueue.global().async {
                                let out = (try? NetworkService.ping(host: host))?.combinedOutput ?? L("networkview.pingFailed")
                                DispatchQueue.main.async { pingOutput = out; pinging = false }
                            }
                        } label: { Label(pinging ? L("networkview.pinging") : L("networkview.start"), systemImage: "dot.radiowaves.left.and.right") }
                            .disabled(pinging || pingHost.isEmpty)
                    }
                    if !pingOutput.isEmpty { ConsoleView(text: pingOutput, minHeight: 120) }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("networkview.flushDNS")).font(.headline)
                    Text(L("networkview.flushDNS.detail")).font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Text(NetworkService.flushDNSCommand)
                            .font(.footnote.monospaced()).textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .primary.opacity(0.05))
                        CopyButton(text: NetworkService.flushDNSCommand)
                    }
                }
            }
        } trailing: {
            Button {
                interfaces = NetworkService.localInterfaces()
                ports = NetworkService.listeningPorts()
            } label: { Label(L("networkview.refresh"), systemImage: "arrow.clockwise") }
        }
    }
}
