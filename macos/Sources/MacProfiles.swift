import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VayuSetuCore

/// VPN profiles for the Mac: a list on the left, the selected profile's details and actions on the right.
/// It calls the same store functions as the iPhone's Profiles screen.
struct MacProfiles: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    let activate: (@escaping () -> Void) -> Void
    private enum Item: Hashable { case wireGuard(UUID), manual(UUID), noVPN }
    @State private var focus: Item?
    @State private var draft: VSProfileDraft?
    @State private var manualDraft: ManualVPNDraft?
    @State private var nativeExport: ManualVPNDraft?
    @State private var qrProfile: SavedProfile?
    @State private var importing = false
    @State private var exporting = false
    @State private var document = EncryptedBackupDocument()
    @State private var search = ""
    @State private var deletingNative: ManualVPNDraftSummary?

    private var locked: Bool { tunnel.running || tunnel.busy || store.connectionOperation }
    private var wireGuard: [SavedProfile] { store.profiles.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    private var manual: [ManualVPNDraftSummary] { store.manualDrafts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        MacPage(title: "VPN Profiles", subtitle: "Import a VPN you already have. VayuSetu does not provide VPN servers.") {
            HStack(alignment: .top, spacing: 20) {
                list.frame(width: 360)
                detail.frame(maxWidth: .infinity)
            }
        }
        .toolbar { ToolbarItem { addMenu } }
        .onAppear { if focus == nil { focus = current } }
        .sheet(item: $draft) { item in NavigationStack { VSProfileEditor(store: store, tunnel: tunnel, draft: item) }.frame(minWidth: 560, minHeight: 600).vsDialogHost() }
        .sheet(item: $manualDraft) { item in NavigationStack { VSManualProtocolEditor(store: store, original: item) }.frame(minWidth: 560, minHeight: 620).vsDialogHost() }
        .sheet(item: $nativeExport) { item in NavigationStack { VSNativeProfileExportScreen(profile: item).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { nativeExport = nil } } } }.frame(minWidth: 480, minHeight: 420) }
        .sheet(item: $qrProfile) { profile in NavigationStack { VSProfileQRScreen(name: profile.name, configuration: { try store.configuration(for: profile) }) }.frame(minWidth: 460, minHeight: 540) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "conf") ?? .plainText, .plainText]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                // Keep the security-scoped URL alive while reading, then send the
                // contents through the review editor. This gives the user the exact
                // parser error and avoids a half-saved Keychain/profile pair.
                let text = try WireGuardImportReview.read(url)
                let importedName = url.deletingPathExtension().lastPathComponent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                draft = VSProfileDraft(name: String((importedName.isEmpty ? "Imported profile" : importedName).prefix(80)), text: text)
            } catch { store.notice = (error as? AppIssue)?.message ?? "Profile import did not finish." }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: "VayuSetu-redacted.conf") { _ in document = EncryptedBackupDocument() }
        .vsConfirm(isPresented: Binding(get: { store.pendingDeletion != nil }, set: { if !$0 { store.pendingDeletion = nil } }), title: "Delete profile and its keys?", message: "The original imported file is preserved.", confirm: "Delete Profile", destructive: true, icon: "trash.fill") { if let profile = store.pendingDeletion { store.delete(profile) }; store.pendingDeletion = nil }
        .vsConfirm(isPresented: Binding(get: { deletingNative != nil }, set: { if !$0 { deletingNative = nil } }), title: "Delete this IKEv2 profile?", message: "Its saved credentials are removed too.", confirm: "Delete Profile", destructive: true, icon: "trash.fill") {
            if let profile = deletingNative { Task { do { try await store.deleteManualDraft(profile) } catch { store.notice = (error as? AppIssue)?.message ?? "Deletion failed." } } }; deletingNative = nil
        }
    }

    private var current: Item? {
        if let id = store.selected { return .wireGuard(id) }
        if let id = store.selectedManualProfile { return .manual(id) }
        return store.dnsOnlyChosen ? .noVPN : nil
    }

    // MARK: Toolbar
    private var addMenu: some View {
        Menu {
            Button("New WireGuard profile…") { edit(nil) }
            Button("Import configuration file…") { importing = true }
            Button("Paste configuration from clipboard") { importClipboard() }
            Divider()
            Button("New IKEv2 / IPsec profile…") { manualDraft = ManualVPNDraft(protocolKind: .ikev2) }
        } label: { Label("Add profile", systemImage: "plus") }
            .disabled(tunnel.busy || store.connectionOperation).help("Add a VPN profile")
    }

    // MARK: List
    private var list: some View {
        MacPanel("Your profiles", icon: "key.horizontal", trailing: { Text("\(store.profiles.count + store.manualDrafts.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search profiles", text: $search).textFieldStyle(.plain) }
                    .padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                row(.noVPN, icon: "globe", title: "No VPN profile", detail: "DNS only, no remote VPN", state: store.dnsOnlyChosen ? "Selected" : nil)
                if !wireGuard.isEmpty { section("WireGuard") }
                ForEach(wireGuard) { profile in row(.wireGuard(profile.id), icon: "point.3.connected.trianglepath.dotted", title: profile.name, detail: lastUsed(profile.id) ?? (profile.endpoints.first ?? "WireGuard"), state: state(profile.id)) }
                if !manual.isEmpty { section("IKEv2 / IPsec") }
                ForEach(manual) { item in row(.manual(item.id), icon: "lock.shield", title: item.name, detail: lastUsed(item.id) ?? "IKEv2 · DNS set by the server", state: state(item.id)) }
                if store.profiles.isEmpty && store.manualDrafts.isEmpty {
                    Text("No profiles yet. Use the + button in the toolbar to import a WireGuard file, paste a configuration or add an IKEv2 server.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
                }
            }
        }
    }
    private func section(_ text: String) -> some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary).padding(.top, 6) }
    private func state(_ id: UUID) -> String? {
        if tunnel.running && tunnel.configuredProfile == id { return tunnel.status == .connected ? "Connected" : "Connecting…" }
        return store.selected == id || store.selectedManualProfile == id ? "Selected" : nil
    }
    private func lastUsed(_ id: UUID) -> String? { store.lastUsed[id.uuidString].map { "Last used " + $0.formatted(.relative(presentation: .named)) } }
    private func row(_ item: Item, icon: String, title: String, detail: String, state: String?) -> some View {
        Button { focus = item } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(VSDesign.accent).frame(width: 30, height: 30).background(VSDesign.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 6)
                if let state { MacChip(text: state, tint: state == "Connected" ? .green : state == "Selected" ? VSDesign.accent : .orange) }
            }.padding(8).contentShape(Rectangle())
                .background(focus == item ? VSDesign.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }.buttonStyle(.plain)
            .contextMenu { actions(for: item) }
    }

    // MARK: Detail
    @ViewBuilder private var detail: some View {
        switch focus ?? current {
        case .wireGuard(let id): if let profile = store.profiles.first(where: { $0.id == id }) { wireGuardDetail(profile) } else { empty }
        case .manual(let id): if let item = store.manualDrafts.first(where: { $0.id == id }) { manualDetail(item) } else { empty }
        case .noVPN: noVPNDetail
        case nil: empty
        }
    }
    private var empty: some View {
        MacPanel("Details", icon: "info.circle") {
            VStack(spacing: 8) { Image(systemName: "key.horizontal").font(.system(size: 30)).foregroundStyle(.secondary); Text("Select a profile").font(.headline); Text("Its details and actions appear here.").font(.subheadline).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 220)
        }
    }
    private var noVPNDetail: some View {
        MacPanel("DNS only", icon: "globe") {
            VStack(alignment: .leading, spacing: 12) {
                Text("No remote VPN").font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("VayuSetu runs a local encrypted-DNS tunnel on this Mac. Your traffic is not sent through a VPN server.").foregroundStyle(.secondary)
                Button(store.dnsOnlyChosen ? "Selected" : "Use DNS only") { store.selectNoVPNProfile() }.buttonStyle(MacHoverButtonStyle(prominent: !store.dnsOnlyChosen)).disabled(store.dnsOnlyChosen || locked)
            }
        }
    }
    private func wireGuardDetail(_ profile: SavedProfile) -> some View {
        let live = tunnel.running && tunnel.configuredProfile == profile.id
        return VStack(spacing: 20) {
            MacPanel(profile.name, icon: "point.3.connected.trianglepath.dotted", trailing: { MacChip(text: live ? (tunnel.status == .connected ? "Connected" : "Connecting…") : "WireGuard", tint: live ? .green : .secondary) }) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Button { live ? disconnect() : connect(profile) } label: { Label(live ? "Disconnect" : "Connect", systemImage: live ? "stop.circle" : "bolt.fill") }
                            .buttonStyle(MacHoverButtonStyle(prominent: !live)).disabled(!live && locked)
                        Button { edit(profile) } label: { Label("Edit", systemImage: "pencil") }.buttonStyle(MacHoverButtonStyle()).disabled(store.profileInUse(profile) || tunnel.busy)
                        Menu { actions(for: .wireGuard(profile.id)) } label: { Label("More", systemImage: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    Divider()
                    facts(profile)
                }
            }
            if store.profileInUse(profile) { Label("This profile is in use. Disconnect to edit or delete it.", systemImage: "lock").font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private func facts(_ profile: SavedProfile) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
            fact("Server", profile.endpoints.joined(separator: ", ").isEmpty ? "—" : profile.endpoints.joined(separator: ", "))
            fact("Tunnel address", profile.addresses.joined(separator: ", "))
            fact("DNS in profile", profile.dns.isEmpty ? "None" : profile.dns.joined(separator: ", "))
            fact("Peers", "\(profile.peerCount)")
            fact("Routes", profile.fullTunnel ? "All traffic" : "Selected networks")
            fact("Added", profile.created.formatted(date: .abbreviated, time: .omitted))
            if let used = lastUsed(profile.id) { fact("Use", used) }
        }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing); Text(value).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func manualDetail(_ item: ManualVPNDraftSummary) -> some View {
        let live = tunnel.running && tunnel.configuredProfile == item.id
        return MacPanel(item.name, icon: "lock.shield", trailing: { MacChip(text: live ? "Connected" : "IKEv2", tint: live ? .green : .secondary) }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button { live ? disconnect() : connectManual(item) } label: { Label(live ? "Disconnect" : "Connect", systemImage: live ? "stop.circle" : "bolt.fill") }.buttonStyle(MacHoverButtonStyle(prominent: !live)).disabled(!live && locked)
                    Button { editManual(item) } label: { Label("Edit", systemImage: "pencil") }.buttonStyle(MacHoverButtonStyle()).disabled(live || tunnel.busy)
                    Menu { actions(for: .manual(item.id)) } label: { Label("More", systemImage: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                }
                Divider()
                Text("IKEv2/IPsec uses Apple's native adapter. DNS is set by the VPN server, so VayuSetu cannot apply or verify your resolver on this connection.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions
    @ViewBuilder private func actions(for item: Item) -> some View {
        switch item {
        case .wireGuard(let id):
            if let profile = store.profiles.first(where: { $0.id == id }) {
                Button("Use this profile") { store.selectProfile(profile) }.disabled(locked)
                Button("Edit…") { edit(profile) }.disabled(store.profileInUse(profile) || tunnel.busy)
                Button("Duplicate") { store.duplicate(profile) }.disabled(tunnel.busy)
                Button("Show QR code…") { qrProfile = profile }
                Button("Export without secrets…") { document = EncryptedBackupDocument(data: Data(store.redactedConfiguration(profile).utf8)); exporting = true }
                Divider()
                Button("Delete…", role: .destructive) { store.pendingDeletion = profile }.disabled(store.profileInUse(profile) || tunnel.busy)
            }
        case .manual(let id):
            if let item = store.manualDrafts.first(where: { $0.id == id }) {
                Button("Use this profile") { store.selectManual(item) }.disabled(locked)
                Button("Edit…") { editManual(item) }.disabled(tunnel.busy)
                Button("Export / back up…") { do { nativeExport = try store.manualDraft(item) } catch { store.notice = "Could not read the profile from Keychain." } }
                Divider()
                Button("Delete…", role: .destructive) { deletingNative = item }.disabled(tunnel.busy)
            }
        case .noVPN:
            Button("Use DNS only") { store.selectNoVPNProfile() }.disabled(locked)
        }
    }
    private func connect(_ profile: SavedProfile) { activate { store.selectAndConnectWireGuard(profile) } }
    private func connectManual(_ item: ManualVPNDraftSummary) { activate { store.selectAndConnectManual(item) } }
    private func disconnect() { Task { await store.powerOffNetwork() } }
    private func edit(_ profile: SavedProfile?) {
        do { draft = VSProfileDraft(profile: profile, name: profile?.name ?? "", text: try profile.map { try store.configuration(for: $0) } ?? "[Interface]\nPrivateKey = \nAddress = \n\n[Peer]\nPublicKey = \nEndpoint = \nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n") }
        catch { store.notice = "Could not read the profile from Keychain." }
    }
    private func editManual(_ item: ManualVPNDraftSummary) { do { manualDraft = try store.manualDraft(item) } catch { store.notice = "Could not read the profile from Keychain." } }
    private func importClipboard() {
        guard let text = VSDesign.clipboard(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { store.notice = "No configuration found on the clipboard."; return }
        guard text.utf8.count <= 128_000 else { store.notice = "Configuration exceeds the 128 KB import limit."; return }
        draft = VSProfileDraft(name: "Imported profile", text: text)
    }
}
