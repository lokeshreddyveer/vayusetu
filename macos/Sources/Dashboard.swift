import AppKit
import SwiftUI
import NetworkExtension

struct MacBrandArtwork: View {
    private static let artwork = Bundle.main.url(forResource: "BrandArtwork", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    var body: some View {
        if let image = Self.artwork { Image(nsImage: image).resizable().scaledToFit() }
        else { Image(systemName: "wind").resizable().scaledToFit().foregroundStyle(VSDesign.accent) }
    }
}

struct MacDashboard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var network: NetworkDiagnostics
    let connect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var connected: Bool { tunnel.status == .connected }
    var signal: Color { connected ? .green : tunnel.stage == .failed || tunnel.stage == .blocked ? .orange : VSDesign.accent }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your connection, composed.").font(.system(size: 28, weight: .semibold, design: .rounded))
                            Text("WireGuard and encrypted DNS, together.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Label(tunnel.statusText, systemImage: connected ? "checkmark.circle.fill" : "circle.fill")
                            .font(.caption.weight(.medium)).foregroundStyle(signal).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(signal.opacity(0.09), in: Capsule())
                    }
                    if geometry.size.width >= 780 {
                        HStack(alignment: .top, spacing: 20) { connectionCard.frame(width: 310); configuration.frame(maxWidth: .infinity) }
                    } else { connectionCard; configuration }
                    HStack(spacing: 14) {
                        metric("Network", value: network.path, icon: "network")
                        metric("Downloaded", value: bytes(tunnel.stats?.received), icon: "arrow.down")
                        metric("Uploaded", value: bytes(tunnel.stats?.sent), icon: "arrow.up")
                    }
                    VSProtectionGrid(store: store, tunnel: tunnel)
                    VSHomeActions(store: store, tunnel: tunnel, network: network)
                    if !tunnel.message.isEmpty { Label(tunnel.message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange).textSelection(.enabled) }
                    if !TunnelController.available { Text("This copy cannot activate a VPN. Open the signed VayuSetuVPN app from Applications.").font(.footnote).foregroundStyle(.secondary) }
                }.padding(24).frame(width: geometry.size.width, alignment: .leading)
            }.scrollIndicators(.hidden).background(VSDesign.background)
        }.navigationTitle("Overview")
    }
    var connectionCard: some View {
        VStack(spacing: 16) {
            MacBrandArtwork().frame(width: 220, height: 152).accessibilityHidden(true)
            Button {
                if tunnel.running || tunnel.busy { Task { await tunnel.disconnect() } } else { connect() }
            } label: {
                ZStack {
                    Circle().stroke(signal.opacity(0.10), lineWidth: 1).frame(width: 122, height: 122)
                    Circle().fill(signal.opacity(0.09)).overlay(Circle().stroke(signal.opacity(0.35), lineWidth: 1)).frame(width: 100, height: 100)
                    Image(systemName: "power").font(.system(size: 34, weight: .light)).foregroundStyle(signal)
                    if tunnel.busy { ProgressView().offset(y: 65) }
                }
            }.buttonStyle(.plain).disabled(!TunnelController.available || !tunnel.ready)
                .accessibilityLabel(tunnel.running || tunnel.busy ? "Disconnect VPN" : "Connect VPN")
            VStack(spacing: 6) {
                Text(tunnel.statusText).font(.title3.weight(.semibold))
                Text(connected ? "Tunnel established. Verification pending." : "Choose a profile and resolver to begin.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if connected { TimelineView(.periodic(from: .now, by: 1)) { _ in Text(tunnel.duration).font(.caption.monospacedDigit()).foregroundStyle(.secondary) } }
        }.padding(24).frame(maxWidth: .infinity).macPanel().animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: connected)
    }
    var configuration: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                Text("CONNECTION STACK").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                NavigationLink { VSProfilesScreen(store: store, tunnel: tunnel) } label: { VSRow(title: store.active?.name ?? "Choose a VPN profile", subtitle: store.active == nil ? "Import your WireGuard configuration" : "WireGuard · saved profile", icon: "key.horizontal", chevron: true) }.buttonStyle(.plain)
                Divider()
                NavigationLink { VSDNSScreen(store: store, tunnel: tunnel) } label: { VSRow(title: store.endpoint.isEmpty ? "Choose an encrypted resolver" : store.dnsName, subtitle: store.endpoint.isEmpty ? "DNS-over-HTTPS or DNS-over-TLS" : DNSService.transport(store.endpoint) + " · configured", icon: "network", chevron: true) }.buttonStyle(.plain)
                Divider()
                NavigationLink { VSModeScreen(store: store, tunnel: tunnel) } label: {
                    HStack { Text("VPN → DNS").font(.subheadline.weight(.medium)); Spacer(); Text("Routing mode").font(.caption).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                }.buttonStyle(.plain)
            }.padding(22).macPanel()
            VStack(alignment: .leading, spacing: 12) {
                HStack { Label("Connection checks", systemImage: "waveform.path.ecg").font(.headline); Spacer() }
                Text("Measure connectivity separately from protection. A working tunnel alone does not verify DNS routing or leak isolation.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                NavigationLink { VSChecksScreen(store: store, tunnel: tunnel, network: network) } label: { Label("Open diagnostics", systemImage: "arrow.up.right") }.buttonStyle(VSActionStyle())
            }.padding(22).macPanel()
        }
    }
    func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit().lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).macPanel()
    }
    func bytes(_ value: UInt64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .binary) } ?? "—" }
}
extension View {
    func macPanel() -> some View {
        background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.primary.opacity(0.055), lineWidth: 1))
    }
}
