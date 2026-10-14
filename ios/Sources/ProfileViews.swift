import SwiftUI
import UniformTypeIdentifiers
import VayuSetuCore
#if os(iOS)
import AVFoundation
import VisionKit
#endif

struct VSProfileDraft: Identifiable {
    let id = UUID()
    var profile: SavedProfile?
    var name: String
    var text: String
}
private enum VSStoredProfile: Identifiable {
    case wireGuard(SavedProfile), native(ManualVPNDraftSummary)
    var id: UUID { switch self { case .wireGuard(let value): return value.id; case .native(let value): return value.id } }
    var name: String { switch self { case .wireGuard(let value): return value.name; case .native(let value): return value.name } }
    var protocolName: String { switch self { case .wireGuard: return "WireGuard"; case .native(let value): return value.protocolKind.rawValue } }
    var created: Date? { if case .wireGuard(let value) = self { return value.created }; return nil }
    var endpoints: [String] { if case .wireGuard(let value) = self { return value.endpoints }; return [] }
}
private struct ProfilesRouteKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues { var openProfilesTab: (() -> Void)? { get { self[ProfilesRouteKey.self] } set { self[ProfilesRouteKey.self] = newValue } } }

struct VSProfilesScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    var isRootTab = false
    @ScaledMetric(relativeTo: .title) private var headerSize = 28
    @State private var search = ""
    @AppStorage("profiles-sort-order") private var sort = "Recently Used"
    @State private var protocolFilter = "All Profiles"
    @FocusState private var searchFocused: Bool
    @State private var switching: SavedProfile?
    @State private var importing = false
    @State private var draft: VSProfileDraft?
    @State private var inspecting: UUID?
    @State private var exporting = false
    @State private var document = EncryptedBackupDocument()
    @State private var showingConnectionDetails = false
    @State private var showingAddProfile = false
    @State private var pendingAddMethod: String?
    @State private var manualDraft: ManualVPNDraft?
    @State private var nativeExport: ManualVPNDraft?
    @State private var switchingNative: ManualVPNDraftSummary?
    @State private var deletingNative: ManualVPNDraftSummary?
    @State private var showingQRScanner = false
    @StateObject private var diagnosticsNetwork = NetworkDiagnostics()
    @State private var scannedConfiguration: String?
    #if os(iOS)
    @State private var qrProfile: SavedProfile?
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openProfilesTab) private var openProfilesTab
    @Environment(\.dismiss) private var dismiss
    var locked: Bool { tunnel.running || tunnel.busy }
    var items: [SavedProfile] {
        store.profiles.filter { profile in
            let matches = search.isEmpty || profile.name.localizedCaseInsensitiveContains(search) || "WireGuard".localizedCaseInsensitiveContains(search) || profile.endpoints.contains { $0.localizedCaseInsensitiveContains(search) }
            let connected = tunnel.status == .connected && tunnel.configuredProfile == profile.id
            let recent = (store.lastUsed[profile.id.uuidString] ?? .distantPast) >= Date().addingTimeInterval(-30 * 86400)
            return matches && (protocolFilter == "Connected" ? connected : protocolFilter == "Recently Used" ? recent : true)
        }.sorted { a, b in
            if sort == "Name A–Z" || sort == "Name" || sort == "Protocol" {
                let order = a.name.localizedCaseInsensitiveCompare(b.name)
                return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
            }
            if sort == "Name Z–A" {
                let order = a.name.localizedCaseInsensitiveCompare(b.name)
                return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedDescending
            }
            let lhs = sort == "Recently Used" || sort == "Last used" ? store.lastUsed[a.id.uuidString] ?? .distantPast : a.created
            let rhs = sort == "Recently Used" || sort == "Last used" ? store.lastUsed[b.id.uuidString] ?? .distantPast : b.created
            return lhs == rhs ? a.id.uuidString < b.id.uuidString : lhs > rhs
        }
    }
    var body: some View {
        AnyView(content
            #if os(iOS)
            .navigationTitle(isRootTab ? "" : "Profiles")
            .vsInlineTitle()
            .toolbar(isRootTab ? .hidden : .visible, for: .navigationBar)
            .navigationDestination(isPresented: Binding(get: { inspecting != nil }, set: { if !$0 { inspecting = nil } })) {
                if let profile = store.profiles.first(where: { $0.id == inspecting }) { profileDetail(profile).vsHeader("Profile Details") }
            }
            .navigationDestination(isPresented: $showingConnectionDetails) { VSConnectionDetailsScreen(store: store, tunnel: tunnel) }
            // A pushed copy would duplicate the tab's whole list on top of the current screen; go to the real tab instead.
            .onAppear { if !isRootTab, let openProfilesTab { dismiss(); openProfilesTab() } }
            #else
            .vsHeader("Profiles").searchable(text: $search, prompt: "Search profiles")
            .toolbar { ToolbarItem { addMenu } }
            #endif
            .vsConfirm(isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }), title: "Switch VPN profile?", message: "Switching briefly disconnects the current VPN. The app waits for shutdown before connecting the selected profile.", confirm: "Switch Profile", icon: "arrow.triangle.2.circlepath") { if let profile = switching { store.selectAndConnectWireGuard(profile) }; switching = nil }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingQRScanner, onDismiss: {
                if let text = scannedConfiguration { scannedConfiguration = nil; draft = VSProfileDraft(name: "Scanned WireGuard profile", text: text) }
            }) {
                NavigationStack { VSQRImportScreen { text in scannedConfiguration = text; showingQRScanner = false } }
            }
            .sheet(isPresented: $showingAddProfile, onDismiss: finishAddSelection) {
                NavigationStack { VSAddProfileScreen { method in pendingAddMethod = method; showingAddProfile = false } }.vsSheetChrome([.fraction(0.9), .large])
            }
            #endif
            .vsConfirm(isPresented: Binding(get: { switchingNative != nil }, set: { if !$0 { switchingNative = nil } }), title: "Switch to this IKEv2 profile?", message: "The current VPN disconnects before the selected IKEv2 profile connects.", confirm: "Switch Profile", icon: "arrow.triangle.2.circlepath") { if let profile = switchingNative { store.selectAndConnectManual(profile) }; switchingNative = nil }
            .vsConfirm(isPresented: Binding(get: { deletingNative != nil }, set: { if !$0 { deletingNative = nil } }), title: "Delete this IKEv2 profile?", message: "Its saved credentials are removed too.", confirm: "Delete Profile", destructive: true, icon: "trash.fill") { if let profile = deletingNative { Task { do { try await store.deleteManualDraft(profile) } catch { store.notice = (error as? AppIssue)?.message ?? "Deletion failed." } } }; deletingNative = nil }
            .sheet(item: $nativeExport) { item in NavigationStack { VSNativeProfileExportScreen(profile: item).vsSheetChrome([.medium, .large]).toolbar { ToolbarItem(placement: .cancellationAction) { VSCloseButton(label: "Done") { nativeExport = nil } } } } }
            .sheet(item: $manualDraft) { item in NavigationStack { VSManualProtocolEditor(store: store, original: item) }.vsDialogHost().vsSheetChrome() }
            .sheet(item: $draft) { item in NavigationStack { VSProfileEditor(store: store, tunnel: tunnel, draft: item) }.vsDialogHost().vsSheetChrome() }
            #if os(iOS)
            .sheet(item: $qrProfile) { profile in NavigationStack { VSProfileQRScreen(name: profile.name, configuration: { try store.configuration(for: profile) }) }.vsSheetChrome([.large]) }
            #endif
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "conf") ?? .plainText, .plainText]) { result in
                do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } };
                    #if os(iOS)
                    let text = try WireGuardImportReview.read(url)
                    draft = VSProfileDraft(name: url.deletingPathExtension().lastPathComponent, text: text)
                    #else
                    store.importProfile(url)
                    #endif
                }
                catch { store.notice = (error as? AppIssue)?.message ?? "Profile import did not finish." }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: "VayuSetu-redacted.conf") { _ in document = EncryptedBackupDocument() }
            .vsConfirm(isPresented: Binding(get: { store.pendingDeletion != nil }, set: { if !$0 { store.pendingDeletion = nil } }), title: "Delete profile and its keys?", message: "The original imported file is preserved.", confirm: "Delete Profile", destructive: true, icon: "trash.fill") { if let profile = store.pendingDeletion { store.delete(profile) }; store.pendingDeletion = nil })
    }
    private var addLabel: some View {
        Image(systemName: "plus").font(.system(size: 20, weight: .medium))
            .frame(width: 44, height: 44).background(VSDesign.surface, in: Circle())
            .overlay(Circle().stroke(VSDesign.separator, lineWidth: 1))
    }
    @ViewBuilder private var addMenu: some View {
        #if os(iOS)
        Button { showingAddProfile = true } label: { addLabel }
            .buttonStyle(VSPlainButtonStyle()).accessibilityLabel("Add profile").disabled(tunnel.busy || store.connectionOperation)
        #else
        Menu {
            Button("New Profile", systemImage: "square.and.pencil") { edit(nil) }
            Button("Import File", systemImage: "doc") { importing = true }
            Button("Import from Clipboard", systemImage: "doc.on.clipboard") { importClipboard() }
        } label: { addLabel }.buttonStyle(VSPlainButtonStyle()).accessibilityLabel("Add profile").disabled(tunnel.busy || store.connectionOperation)
        #endif
    }
    private func importClipboard() {
        guard let text = VSDesign.clipboard(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { store.notice = "No configuration found on the clipboard."; return }
        guard text.utf8.count <= 128_000 else { store.notice = "Configuration exceeds the 128 KB import limit."; return }
        draft = VSProfileDraft(name: "Imported profile", text: text)
    }
    private func finishAddSelection() {
        guard let method = pendingAddMethod else { return }; pendingAddMethod = nil
        switch method {
        case "file": importing = true
        case "clipboard": importClipboard()
        case "wireguard": edit(nil)
        case "openvpn": store.notice = "OpenVPN is unavailable while its engine and licensing are on hold."
        case "ikev2": manualDraft = ManualVPNDraft(protocolKind: .ikev2)
        case "qr": showingQRScanner = true
        default: break
        }
    }
    private var profilesHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profiles").font(.system(size: headerSize, weight: .semibold))
                Text("Manage your VPN connections").font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            addMenu
        }.padding(.top, 12)
    }
    #if os(iOS)
    private var hasConnectionCard: Bool {
        tunnel.running || tunnel.busy || !tunnel.ready || tunnel.stage == .failed || tunnel.stage == .blocked || !tunnel.history.isEmpty
    }
    private var connectionProfile: SavedProfile? {
        if tunnel.running { return store.profiles.first { $0.id == tunnel.configuredProfile } }
        return store.selectedManualProfile == nil ? store.active : nil
    }
    private var unifiedProfiles: [VSStoredProfile] {
        (store.profiles.map(VSStoredProfile.wireGuard) + store.manualDrafts.map(VSStoredProfile.native)).filter { profile in
            let matches = search.isEmpty || profile.name.localizedCaseInsensitiveContains(search) || profile.protocolName.localizedCaseInsensitiveContains(search) || profile.endpoints.contains { $0.localizedCaseInsensitiveContains(search) }
            let connected = tunnel.status == .connected && tunnel.configuredProfile == profile.id
            let recent = (store.lastUsed[profile.id.uuidString] ?? .distantPast) >= Date().addingTimeInterval(-30 * 86400)
            let filterMatches = protocolFilter == "Connected" ? connected : protocolFilter == "Recently Used" ? recent : ["WireGuard", "IKEv2", "OpenVPN"].contains(protocolFilter) ? profile.protocolName == protocolFilter : true
            return matches && filterMatches
        }.sorted { a, b in
            if sort == "Protocol", a.protocolName != b.protocolName { return a.protocolName < b.protocolName }
            if ["Name A–Z", "Name", "Name Z–A", "Protocol"].contains(sort) {
                let order = a.name.localizedCaseInsensitiveCompare(b.name)
                return order == .orderedSame ? a.id.uuidString < b.id.uuidString : sort == "Name Z–A" ? order == .orderedDescending : order == .orderedAscending
            }
            let lhs = sort == "Recently Added" ? a.created ?? .distantPast : store.lastUsed[a.id.uuidString] ?? .distantPast
            let rhs = sort == "Recently Added" ? b.created ?? .distantPast : store.lastUsed[b.id.uuidString] ?? .distantPast
            return lhs == rhs ? a.id.uuidString < b.id.uuidString : lhs > rhs
        }
    }
    private func nativeProfileRow(_ summary: ManualVPNDraftSummary) -> some View {
        let current = tunnel.configuredProfile == summary.id && tunnel.running
        return HStack(spacing: 4) {
            Button {
                guard summary.protocolKind == .ikev2, !current else { return }
                if tunnel.running { switchingNative = summary }
                else { store.selectAndConnectManual(summary) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "network").font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(summary.protocolKind.rawValue + (summary.protocolKind == .ikev2 ? " · Server-managed DNS" : " · Unavailable")).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            if current && tunnel.status == .connected { Circle().fill(.green).frame(width: 5, height: 5) }
                            Text(current ? tunnel.statusText : "Tap to connect").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                }.frame(maxWidth: .infinity, minHeight: 64, alignment: .center).contentShape(Rectangle())

            }.buttonStyle(VSPlainButtonStyle()).accessibilityIdentifier("NativeProfileRow")
                .disabled(summary.protocolKind == .openVPN || tunnel.busy || store.connectionOperation)
            Menu {
                Button("Edit Configuration", systemImage: "pencil") { do { manualDraft = try store.manualDraft(summary) } catch { store.notice = "Could not read the profile from Keychain." } }.disabled(tunnel.running || tunnel.busy || store.connectionOperation)
                Button("Export / Back Up Profile", systemImage: "square.and.arrow.up") { do { nativeExport = try store.manualDraft(summary) } catch { store.notice = "Could not read the profile from Keychain." } }
                Button("Delete Profile", systemImage: "trash", role: .destructive) { deletingNative = summary }.disabled(tunnel.running || tunnel.busy || store.connectionOperation)
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("IKEv2 profile actions").disabled(summary.protocolKind == .openVPN)
        }.padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 2)
    }
    private var activeConnectionCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let snapshot = store.protection(.vpn, now: context.date)
            VStack(alignment: .leading, spacing: 10) {
                Text(tunnel.running ? "ACTIVE CONNECTION" : "CONNECTION STATUS").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    Circle().fill(snapshot.tint).frame(width: 6, height: 6)
                    Text(tunnel.status == .disconnecting ? "Disconnecting" : snapshot.label).font(.subheadline.weight(.semibold)).foregroundStyle(snapshot.tint)
                    if tunnel.busy || tunnel.status == .connecting || tunnel.status == .reasserting { ProgressView().controlSize(.small).padding(.leading, 4) }
                }
                HStack(alignment: .top, spacing: 12) {
                    VSPrivacyGlyph(subsystem: .vpn).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        if !tunnel.running { Text("Selected profile").font(.caption).foregroundStyle(.secondary) }
                        Text(store.connectionName ?? "Profile unavailable").font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(store.connectionProtocol + (connectionProfile?.endpoints.first.map { " · " + $0 } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if tunnel.status == .connected {
                    Text(tunnel.observedConnectedDate == nil ? "Session duration unavailable" : "Connected for " + tunnel.duration)
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else if !tunnel.running && !tunnel.busy {
                    Text("No active VPN session").font(.caption).foregroundStyle(.secondary)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) { connectionOperationButton; connectionDetailsLink }
                } else {
                    HStack(spacing: 12) { connectionOperationButton; connectionDetailsLink }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(VSDesign.separator, lineWidth: 1))
        }
    }
    @ViewBuilder private var connectionOperationButton: some View {
        if tunnel.running {
            Button(tunnel.busy || tunnel.status == .disconnecting ? "Please wait…" : tunnel.status == .connecting || tunnel.status == .reasserting ? "Cancel Connection" : "Disconnect") {
                Task { await tunnel.disconnect() }
            }.buttonStyle(VSActionStyle()).disabled(tunnel.busy || tunnel.status == .disconnecting || store.connectionOperation)
        } else if tunnel.stage == .failed || tunnel.stage == .blocked {
            Button("Retry Selected Profile") { store.connect() }.buttonStyle(VSActionStyle()).disabled(tunnel.busy || store.connectionOperation || store.active == nil)
        } else if !tunnel.ready {
            Button("Refresh Status") { Task { await tunnel.load() } }.buttonStyle(VSActionStyle()).disabled(tunnel.busy)
        }
    }
    private var connectionDetailsLink: some View {
        Button { showingConnectionDetails = true } label: {
            HStack { Text("Details"); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(VSActionStyle()).accessibilityIdentifier("ProfilesConnectionDetails")
    }
    #endif
    var content: AnyView {
        if store.profiles.isEmpty && store.manualDrafts.isEmpty {
            return AnyView(VStack {
                #if os(iOS)
                profilesHeader.padding(.horizontal, 16)
                #endif
                ContentUnavailableView { Label("No profiles yet", systemImage: "square.stack.3d.up") } description: { Text("Import a WireGuard configuration from your VPN provider.") } actions: { Button("Add VPN Profile") {
                    #if os(iOS)
                    showingAddProfile = true
                    #else
                    importing = true
                    #endif
                }.buttonStyle(.borderedProminent).vsTapHaptic().disabled(tunnel.busy || store.connectionOperation) }.background(VSDesign.background) }.background(VSDesign.background))
        }
        #if os(macOS)
        return AnyView(HSplitView {
            profileList.frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
            if let profile = store.profiles.first(where: { $0.id == inspecting }) ?? store.active {
                profileDetail(profile).frame(minWidth: 280, maxWidth: .infinity)
            } else { ContentUnavailableView("Select a profile", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity) }
        })
        #else
        return AnyView(iosProfileList)
        #endif
    }
    #if os(iOS)
    private var iosProfileList: some View { profilesDashboard }
    private func rowStatus(_ profile: SavedProfile) -> String {
        if tunnel.configuredProfile == profile.id && tunnel.running { return tunnel.status == .connected ? "Connected" : tunnel.status == .disconnecting ? "Disconnecting" : "Connecting" }
        if store.selected == profile.id && store.selectedManualProfile == nil { return "Selected" }
        if let date = store.lastUsed[profile.id.uuidString] { return "Last used " + date.formatted(.relative(presentation: .named)) }
        return "Never used"
    }
    private func profileRow(_ profile: SavedProfile) -> some View {
        HStack(spacing: 4) {
            Button {
                guard !(tunnel.running && tunnel.configuredProfile == profile.id) else { return }
                if tunnel.running { switching = profile }
                else { store.selectAndConnectWireGuard(profile) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text("WireGuard · " + (profile.endpoints.first ?? "No endpoint")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            if tunnel.status == .connected && tunnel.configuredProfile == profile.id { Circle().fill(Color(red: 0.302, green: 0.871, blue: 0.663)).frame(width: 5, height: 5) }
                            Text(rowStatus(profile)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                }.frame(maxWidth: .infinity, minHeight: 64, alignment: .center).contentShape(Rectangle())
            }.buttonStyle(VSPlainButtonStyle()).accessibilityIdentifier("ProfileListRow").disabled(tunnel.busy || store.connectionOperation)
                .contextMenu { profileMenu(profile) }
            Menu { profileMenu(profile) } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary).frame(width: 44, height: 44)
            }.accessibilityLabel("Actions for " + profile.name)
        }.padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 2)
    }
    @ViewBuilder private func profileMenu(_ profile: SavedProfile) -> some View {
        if tunnel.running && tunnel.configuredProfile == profile.id {
            Button("Disconnect", systemImage: "power") { Task { await tunnel.disconnect() } }.disabled(tunnel.busy || store.connectionOperation)
        } else {
            Button("Connect", systemImage: "power") {
                if tunnel.running { switching = profile }
                else { store.selectAndConnectWireGuard(profile) }
            }.disabled(tunnel.busy || store.connectionOperation)
        }
        Button("View Details", systemImage: "info.circle") { inspecting = profile.id }
        if store.selected != profile.id {
            Button("Select Profile", systemImage: "checkmark.circle") { if tunnel.running { switching = profile } else { store.selectProfile(profile) } }.disabled(tunnel.busy || store.connectionOperation)
        }
        actions(profile)
    }
    #endif
    var profileList: some View {
        List {
            #if os(iOS)
            VSFormSection { profilesHeader.listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20)).listRowBackground(Color.clear).listRowSeparator(.hidden) }
            if hasConnectionCard {
                VSFormSection { activeConnectionCard.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowBackground(Color.clear).listRowSeparator(.hidden) }
            }
            VSFormSection {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search profiles", text: $search).autocorrectionDisabled()
                }.frame(minHeight: 44)
            }
            #endif
            VSFormSection { Picker("Sort", selection: $sort) { Text("Recent").tag("Recent"); Text("Name").tag("Name"); Text("Last used").tag("Last used") } }
            #if os(iOS)
            VSFormSection {
                Button { store.selectNoVPNProfile() } label: {
                    VSRow(title: "No VPN profile", subtitle: "DNS only · local DNS tunnel, no VPN server", icon: "network", selected: store.dnsOnlyChosen)
                }
                .buttonStyle(VSPlainButtonStyle()).disabled(tunnel.busy || store.connectionOperation)
                .listRowBackground(store.dnsOnlyChosen ? VSDesign.accent.opacity(0.08) : VSDesign.surface)
                .accessibilityIdentifier("ProfileNoVPN")
            } footer: { Text("Unselects every VPN profile and uses only DNS protection. Pick a profile again to use a VPN. A connected VPN is disconnected.") }
            #endif
            VSFormSection {
                ForEach(items) { profile in
                    Button {
                        #if os(macOS)
                        inspecting = profile.id
                        #else
                        if tunnel.running && store.selected != profile.id { switching = profile } else { store.selectProfile(profile) }
                        #endif
                    } label: { VSRow(title: profile.name, subtitle: "WireGuard · " + (profile.endpoints.first ?? "No endpoint"), icon: "globe", selected: store.selected == profile.id) }
                    .buttonStyle(VSPlainButtonStyle())
                    .listRowBackground(store.selected == profile.id ? VSDesign.accent.opacity(0.08) : VSDesign.surface)
                    .contextMenu { NavigationLink("Profile Details") { profileDetail(profile).vsHeader("Profile Details") }; actions(profile) }
                    .swipeActions { Button("Delete", role: .destructive) { store.pendingDeletion = profile }.disabled(locked); Button("Edit") { edit(profile) }.disabled(locked) }
                    .swipeActions(edge: .leading) { Button("Set Active") { if tunnel.running { switching = profile } else { store.selectProfile(profile) } }.tint(VSDesign.accent).disabled(tunnel.busy || store.connectionOperation) }
                }
            } footer: { if locked { Text("Switching profiles briefly disconnects the current tunnel. Importing a file leaves the active session unchanged.") } else { Text("Select a profile. Edit and export are in its action menu.") } }
            if items.isEmpty { Text("No matching profiles").foregroundStyle(.secondary) }
            VSFormSection("Manage") {
                NavigationLink { VSPrivacyLockScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Connection Rules", icon: "arrow.triangle.branch") }
                ForEach(items) { profile in NavigationLink { profileDetail(profile).vsHeader("Profile Details") } label: { VSRow(title: profile.name + " Details", subtitle: "Inspect without changing the active connection", icon: "info.circle") } }
            }
        }.vsList()
    }
    func profileDetail(_ profile: SavedProfile) -> some View {
        VSCardList {
            VSSection {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 26)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name).font(.headline)
                        Text("WireGuard · " + rowStatusForDetails(profile)).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
                if tunnel.running && tunnel.configuredProfile == profile.id {
                    Button(tunnel.status == .connecting || tunnel.status == .reasserting ? "Cancel Connection" : "Disconnect") { Task { await tunnel.disconnect() } }
                        .disabled(tunnel.busy || tunnel.status == .disconnecting || store.connectionOperation)
                } else {
                    Button("Connect Profile") {
                        if tunnel.running { switching = profile }
                        else { store.selectAndConnectWireGuard(profile) }
                    }.disabled(tunnel.busy || store.connectionOperation || !TunnelController.available)
                }
            }
            VSSection("Configuration") {
                compactDetailRow(title: "Server", value: profile.endpoints.joined(separator: ", "))
                compactDetailRow(title: "Addresses", value: profile.addresses.joined(separator: ", "))
                compactDetailRow(title: "Imported DNS", value: profile.dns.isEmpty ? "Not specified" : profile.dns.joined(separator: ", "))
                compactDetailRow(title: "Requested DNS source", value: "VayuSetu DNS · " + store.dnsName)
                compactDetailRow(title: "Applied DNS", value: tunnel.configuredProfile == profile.id ? tunnel.appliedDNSDescription : "No session for this profile")
                Text("Imported DNS is preserved for export. VayuSetu’s encrypted resolver replaces it when this profile connects; query behavior remains independently unverified.").font(.caption).foregroundStyle(.secondary)
                compactDetailRow(title: "Peers", value: String(profile.peerCount))
                compactDetailRow(title: "Routing", value: profile.fullTunnel ? "Full tunnel" : "Custom / IPv4 routes")
            }
            VSSection("Connection information") {
                compactDetailRow(title: "Last used", value: store.lastUsed[profile.id.uuidString]?.formatted(date: .abbreviated, time: .shortened) ?? "Never used")
                if tunnel.status == .connected && tunnel.configuredProfile == profile.id {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let counters = tunnel.observedCounters()
                        compactDetailRow(title: "Session", value: tunnel.duration)
                        compactDetailRow(title: "Received", value: counters.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0.received), countStyle: .binary) } ?? "Unavailable")
                        compactDetailRow(title: "Sent", value: counters.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0.sent), countStyle: .binary) } ?? "Unavailable")
                    }
                } else { Text("No active session for this profile.").font(.caption).foregroundStyle(.secondary) }
            }
            VSSection("Actions") {
                if store.selected == profile.id && store.selectedManualProfile == nil {
                    Label("Selected for connection", systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Button("Select Profile") { if tunnel.running { switching = profile } else { store.selectProfile(profile) } }.disabled(tunnel.busy || store.connectionOperation)
                }
                if locked { Text("Disconnect before editing, duplicating or deleting profiles. Viewing details and redacted export remain available.").font(.caption).foregroundStyle(.secondary) }
                actions(profile)
            }
        }.vsList().environment(\.defaultMinListRowHeight, 44)
        #if os(iOS)
        .listSectionSpacing(.compact)
        #endif
        .vsCompactDetails().vsEditor()
    }
    private func compactDetailRow(title: String, value: String) -> some View {
        VSRow(title: title, value: value)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
    private func rowStatusForDetails(_ profile: SavedProfile) -> String {
        if tunnel.configuredProfile == profile.id && tunnel.running { return tunnel.statusText }
        return store.selected == profile.id && store.selectedManualProfile == nil ? "Selected" : "Not connected"
    }
    @ViewBuilder func actions(_ profile: SavedProfile) -> some View {
        Button("Edit / Rename", systemImage: "pencil") { edit(profile) }.disabled(store.profileInUse(profile) || tunnel.busy)
        Button("Duplicate", systemImage: "plus.square.on.square") { let active = store.selected; let native = store.selectedManualProfile; store.duplicate(profile); store.selected = active; store.selectedManualProfile = native }.disabled(tunnel.busy)
        #if os(iOS)
        Button("Show QR Code", systemImage: "qrcode") { qrProfile = profile }
        #endif
        Button("Export Redacted", systemImage: "square.and.arrow.up") { document = EncryptedBackupDocument(data: Data(store.redactedConfiguration(profile).utf8)); exporting = true }
        Button("Delete", systemImage: "trash", role: .destructive) { store.pendingDeletion = profile }.disabled(store.profileInUse(profile) || tunnel.busy)
    }
    func edit(_ profile: SavedProfile?) {
        do { draft = VSProfileDraft(profile: profile, name: profile?.name ?? "", text: try profile.map { try store.configuration(for: $0) } ?? "[Interface]\nPrivateKey = \nAddress = \n\n[Peer]\nPublicKey = \nEndpoint = \nAllowedIPs = 0.0.0.0/0, ::/0\n") }
        catch { store.notice = "Could not read the profile from Keychain." }
    }
}
#if os(iOS)
struct VSAddProfileScreen: View {
    var select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private struct Tile: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1).opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed).vsPressHaptic(configuration.isPressed)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(LinearGradient(colors: [VSDesign.accent, VSDesign.accent.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: VSDesign.accent.opacity(0.45), radius: 14, y: 6)
                    Text("Add a profile").font(.largeTitle.weight(.bold))
                    Text("Bring in a VPN you already have, or set one up by hand.").font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    label("Quick import")
                    HStack(spacing: 10) {
                        tile("File", "WireGuard .conf", icon: "doc.fill", action: "file")
                        tile("Clipboard", "Paste a copied config", icon: "doc.on.clipboard.fill", action: "clipboard")
                        tile("QR code", "Scan with camera", icon: "qrcode.viewfinder", action: "qr")
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    label("Set up manually")
                    VStack(spacing: 0) {
                        row("WireGuard", "Enter your provider’s settings", icon: "point.3.connected.trianglepath.dotted", badge: "Connects", action: "wireguard")
                        Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 68)
                        row("IKEv2 / IPsec", "Apple’s native adapter · server-managed DNS", icon: "network", badge: "Native", action: "ikev2")
                        Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 68)
                        row("OpenVPN", "Integration on hold", icon: "key.horizontal.fill", badge: "Soon", action: nil)
                    }.background(VSSheet.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                }
                Label("Configurations stay on this device. Credentials are stored in Keychain.", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 30)
        }.scrollIndicators(.hidden)
            .toolbar { ToolbarItem(placement: .cancellationAction) { VSCloseButton(label: "Cancel") { dismiss() } } }
            .navigationBarTitleDisplayMode(.inline)
    }
    private func label(_ text: String) -> some View { Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(1.1).foregroundStyle(.secondary).padding(.horizontal, 4) }
    private func tile(_ title: String, _ subtitle: String, icon: String, action: String) -> some View {
        Button { select(action) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(VSDesign.accent)
                    .frame(width: 42, height: 42).background(VSDesign.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                }
            }.padding(12).frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
                .background(VSSheet.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        }.buttonStyle(Tile()).accessibilityLabel(title + ", " + subtitle)
    }
    @ViewBuilder private func row(_ title: String, _ subtitle: String, icon: String, badge: String, action: String?) -> some View {
        let content = HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(action == nil ? Color.secondary : VSDesign.accent)
                .frame(width: 40, height: 40).background((action == nil ? Color.white.opacity(0.06) : VSDesign.accent.opacity(0.15)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(action == nil ? Color.secondary : Color.primary)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(action == nil ? Color.secondary : VSDesign.accent)
                .padding(.horizontal, 8).padding(.vertical, 4).background((action == nil ? Color.white.opacity(0.06) : VSDesign.accent.opacity(0.14)), in: Capsule())
            if action != nil { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }.padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        if let action { Button { select(action) } label: { content }.buttonStyle(Tile()).accessibilityLabel(title) }
        else { content.accessibilityElement(children: .combine) }
    }
}
#endif
struct VSProfileEditor: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    let draft: VSProfileDraft
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var text: String
    @State private var reveal = false
    @State private var raw = false
    @State private var error = ""
    @State private var validation = ""
    @State private var discarding = false
    @State private var showError = false
    init(store: AppStore, tunnel: TunnelController, draft: VSProfileDraft) { self.store = store; self.tunnel = tunnel; self.draft = draft; _name = State(initialValue: draft.name); _text = State(initialValue: draft.text) }
    var changed: Bool { name != draft.name || text != draft.text }
    var multiPeer: Bool { text.components(separatedBy: "[Peer]").count > 2 }
    var body: some View {
        AnyView(Form {
            VSFormSection("General") { TextField("Profile name", text: $name) }
            VSFormSection {
                field("Address", "Interface", "Address")
                VStack(alignment: .leading, spacing: 3) { Text("Private key").font(.caption).foregroundStyle(.secondary); HStack { if reveal { TextField("Private key", text: binding("Interface", "PrivateKey")) } else { SecureField("Private key", text: binding("Interface", "PrivateKey")) }; Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless).accessibilityLabel(reveal ? "Hide private key" : "Reveal private key") }.vsInput() }
                field("DNS servers (optional)", "Interface", "DNS")
                Text("Imported DNS values are saved with this profile but are not applied when connecting. VayuSetu requests the encrypted resolver selected in the DNS tab. Accepted tunnel settings and actual query-path verification are reported separately in Connection Details.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Interface") } footer: { Text("Credentials are saved in this device’s Keychain.") }
            if !multiPeer {
                VSFormSection("Peer") {
                    field("Public key", "Peer", "PublicKey"); field("Endpoint", "Peer", "Endpoint"); field("Allowed IPs", "Peer", "AllowedIPs")
                    SecureField("Preshared key (optional)", text: binding("Peer", "PresharedKey")).vsInput()
                }
            }
            VSFormSection {
                DisclosureGroup("Advanced") {
                    field("MTU", "Interface", "MTU")
                    if !multiPeer { field("Persistent keepalive", "Peer", "PersistentKeepalive") }
                    Toggle("Edit full configuration", isOn: $raw)
                    if raw { Text("Full configuration includes private keys.").font(.caption).foregroundStyle(.orange); TextEditor(text: $text).font(.system(.footnote, design: .monospaced)).frame(minHeight: 200).vsInput() }
                }
                if multiPeer { Text("This profile has multiple peers. Use the full configuration editor to preserve every peer.").font(.caption).foregroundStyle(.secondary) }
            }
            VSFormSection {
                Button("Validate Configuration") {
                    do {
                        let summary = try ProfileParser.parse(text); error = ""
                        do { try ProfileParser.validateTunnel(summary); validation = "Configuration syntax and supported routes checked. Server connectivity is not verified." }
                        catch { validation = "Configuration can be stored, but this build cannot connect its route type." }
                    } catch { validation = ""; self.error = (error as? AppIssue)?.message ?? "Configuration validation failed." }
                }
                if !validation.isEmpty { Text(validation).font(.caption).foregroundStyle(.secondary) }
                if !error.isEmpty { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red) }
            }
        }.formStyle(.grouped).vsFormLook().buttonStyle(VSDefaultButtonStyle()).scrollIndicators(.hidden).vsHeader(draft.profile == nil ? "New Profile" : "Edit Profile").vsEditor()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if changed { discarding = true } else { dismiss() } }.vsTapHaptic() }; ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.vsTapHaptic().disabled((draft.profile != nil && !changed) || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.profileInUse(draft.profile) || tunnel.busy) } }
        .interactiveDismissDisabled(changed)
        .vsConfirm(isPresented: $discarding, title: "Discard your changes?", message: "What you typed here has not been saved.", confirm: "Discard", destructive: true, icon: "xmark.bin.fill", cancel: "Keep Editing") { dismiss() }
        .onChange(of: text) { _, _ in validation = "" }
        .vsAlert(isPresented: $showError, tone: .danger, icon: "xmark.octagon.fill", title: "Could not save", message: error)
        #if os(iOS)
        .listSectionSpacing(.compact)
        #endif
        .environment(\.defaultMinListRowHeight, 44))
    }
    func field(_ label: String, _ section: String, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: binding(section, key)).font(.body.monospaced()).vsInput()
        }
    }
    func value(_ section: String, _ key: String) -> String {
        var current = ""
        for line in text.components(separatedBy: "\n") {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("[") { current = clean }
            if current == "[\(section)]", let equal = clean.firstIndex(of: "="), clean[..<equal].trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() { return clean[clean.index(after: equal)...].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces) }
        }
        return ""
    }
    func binding(_ section: String, _ key: String) -> Binding<String> {
        Binding(get: { value(section, key) }, set: { updated in
            var lines = text.components(separatedBy: "\n"); var current = ""; var insert: Int?; var found: Int?
            for (index, line) in lines.enumerated() {
                let clean = line.trimmingCharacters(in: .whitespaces)
                if clean.hasPrefix("[") { if current == "[\(section)]" { break }; current = clean; if current == "[\(section)]" { insert = index + 1 } }
                if current == "[\(section)]", let equal = clean.firstIndex(of: "="), clean[..<equal].trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() { found = index; break }
            }
            if let found { if updated.isEmpty { lines.remove(at: found) } else { lines[found] = "\(key) = \(updated)" } }
            else if let insert, !updated.isEmpty { lines.insert("\(key) = \(updated)", at: insert) }
            text = lines.joined(separator: "\n")
        })
    }
    func save() { let active = store.selected; let native = store.selectedManualProfile; if store.saveConfiguration(text, name: name, replacing: draft.profile) { if draft.profile != nil { store.selected = active; store.selectedManualProfile = native }; dismiss() } else { error = store.notice; store.notice = ""; showError = true } }
}

struct VSManualProtocolEditor: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var tunnel: TunnelController
    let original: ManualVPNDraft
    @State private var value: ManualVPNDraft
    @State private var error = ""
    @State private var validated = false
    @State private var discarding = false
    @State private var deleting = false
    @State private var pendingSwitch = false
    @State private var showError = false
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, original: ManualVPNDraft) { self.store = store; _tunnel = ObservedObject(wrappedValue: store.tunnel); self.original = original; _value = State(initialValue: original) }
    private var changed: Bool { value != original }
    var body: some View {
        Form {
            VSFormSection { Label(value.protocolKind == .ikev2 ? "Native IKEv2 · DNS set by the VPN server" + (store.lastUsed[value.id.uuidString] == nil ? " · Not connected yet" : "") : "Configuration draft — OpenVPN engine pending", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
            VSFormSection("General") { TextField("Profile name", text: $value.name); TextField("Server address", text: $value.server).vsInput() }
            if value.protocolKind == .openVPN {
                VSFormSection("Connection") {
                    TextField("Port", text: $value.port).vsInput()
                    Picker("Transport", selection: $value.transport) { Text("UDP").tag("UDP"); Text("TCP").tag("TCP") }
                }
                VSFormSection("User authentication (optional)") { TextField("Username", text: $value.username).vsInput(); SecureField("Password", text: $value.password).vsInput() }
                VSFormSection("Certificates") {
                    TextField("CA certificate (PEM)", text: $value.caCertificate, axis: .vertical).vsInput()
                    TextField("Client certificate (PEM, optional)", text: $value.clientCertificate, axis: .vertical).vsInput()
                    SecureField("Client private key (PEM, optional)", text: $value.privateKey).vsInput()
                }
            } else {
                VSFormSection("Server identity") { TextField("Remote identifier", text: $value.remoteIdentifier).vsInput(); TextField("Local identifier (optional)", text: $value.localIdentifier).vsInput() }
                VSFormSection("Authentication") {
                    Picker("Method", selection: $value.authentication) { Text("Username & Password").tag("Username & Password"); Text("Certificate").tag("Certificate") }
                    if value.authentication == "Username & Password" { TextField("Username", text: $value.username).vsInput(); SecureField("Password", text: $value.password).vsInput() }
                    else { SecureField("PKCS#12 identity (base64)", text: $value.identityBase64).vsInput(); SecureField("Identity password", text: $value.identityPassword).vsInput() }
                }
                VSFormSection { Toggle("Connect on demand", isOn: $value.onDemand) } header: { Text("Connection behavior") } footer: { Text("Applied only when you explicitly connect the saved IKEv2 profile. No VPN policy is installed by saving.") }
            }
            VSFormSection {
                Button("Validate Configuration") { do { try value.validate(); error = ""; validated = true } catch { validated = false; self.error = error.localizedDescription } }
                if validated { Text("Required configuration fields checked. Server compatibility, certificate validity and connectivity are unverified.").font(.footnote).foregroundStyle(.secondary) }
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if value.protocolKind == .ikev2, let summary = store.manualDrafts.first(where: { $0.id == value.id }) {
                VSFormSection {
                    Button(tunnel.running && tunnel.configuredProfile == value.id ? "Disconnect IKEv2" : "Connect IKEv2") {
                        if tunnel.running && tunnel.configuredProfile == value.id { Task { await tunnel.disconnect() } }
                        else if tunnel.running { pendingSwitch = true }
                        else { store.selectAndConnectManual(summary) }
                    }.disabled(changed || store.connectionOperation || tunnel.busy)
                    NavigationLink("Export / Back Up Profile") { VSNativeProfileExportScreen(profile: value) }.disabled(changed)
                    Button("Delete IKEv2 Profile", role: .destructive) { deleting = true }.disabled(tunnel.running || tunnel.busy || store.connectionOperation)
                    Text("Uses the VPN server’s DNS. VayuSetu’s selected DoH/DoT endpoint is not applied. Save changes before connecting.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            VSFormSection { Text("Credentials stay in Keychain. Backups exclude credentials unless you explicitly include them in a password-encrypted backup. Delete only after disconnecting.").font(.footnote).foregroundStyle(.secondary) }
        }.formStyle(.grouped).vsFormLook().buttonStyle(VSDefaultButtonStyle()).scrollIndicators(.hidden).vsEditor()
            #if os(iOS)
            .listSectionSpacing(.compact)
            #endif
            .environment(\.defaultMinListRowHeight, 44).vsHeader(value.protocolKind == .ikev2 ? "IKEv2 Profile" : "OpenVPN Draft")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if changed { discarding = true } else { dismiss() } }.vsTapHaptic() }
                ToolbarItem(placement: .confirmationAction) { Button(value.protocolKind == .ikev2 ? "Save Profile" : "Save Draft") { do { try store.saveManualDraft(value); dismiss() } catch { self.error = error.localizedDescription; showError = true } }.vsTapHaptic().disabled(value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .interactiveDismissDisabled(changed)
            .vsConfirm(isPresented: $discarding, title: "Discard your changes?", message: "What you typed here has not been saved.", confirm: "Discard", destructive: true, icon: "xmark.bin.fill", cancel: "Keep Editing") { dismiss() }
            .vsConfirm(isPresented: $deleting, title: "Delete this IKEv2 profile?", message: "Removes this profile’s Keychain credentials and VayuSetu-owned system VPN configuration. Other profiles are preserved.", confirm: "Delete Profile", destructive: true, icon: "trash.fill") {
                if let summary = store.manualDrafts.first(where: { $0.id == value.id }) { Task { do { try await store.deleteManualDraft(summary); dismiss() } catch { self.error = (error as? AppIssue)?.message ?? "Deletion failed." } } }
            }
            .vsConfirm(isPresented: $pendingSwitch, title: "Switch to this IKEv2 profile?", message: "The current VPN disconnects before IKEv2 starts. Network access may be interrupted.", confirm: "Switch Profile", icon: "arrow.triangle.2.circlepath") { if let summary = store.manualDrafts.first(where: { $0.id == value.id }) { store.selectAndConnectManual(summary) } }
            .onChange(of: value) { _, _ in validated = false }
            .vsAlert(isPresented: $showError, tone: .danger, icon: "xmark.octagon.fill", title: "Could not save", message: error)
    }
}

struct VSNativeProfileExportScreen: View {
    let profile: ManualVPNDraft
    @State private var includeCredentials = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var exporting = false
    @State private var document = EncryptedBackupDocument()
    @State private var error = ""
    var body: some View {
        Form {
            VSFormSection("Profile") { VSRow(title: profile.name, value: "IKEv2") }
            VSFormSection {
                Toggle("Include credentials", isOn: $includeCredentials)
                Text(includeCredentials ? "Includes passwords and certificate identity inside the encrypted file. Keep the backup password separate." : "Exports only the profile name and protocol. Re-enter server details and credentials after restoring.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Contents") }
            VSFormSection("Backup password") {
                SecureField("At least 12 characters", text: $password)
                SecureField("Confirm password", text: $confirmation)
            }
            VSFormSection {
                Button("Export Encrypted Profile") {
                    do { document = EncryptedBackupDocument(data: try BackupCrypto.encrypt(NativeProfileBackup.snapshot(profile, includeCredentials: includeCredentials), password: password)); error = ""; exporting = true }
                    catch { self.error = (error as? AppIssue)?.message ?? "Could not create the encrypted profile export." }
                }.disabled(password.count < 12 || password != confirmation)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }.formStyle(.grouped).vsFormLook().buttonStyle(VSDefaultButtonStyle()).vsEditor().vsHeader("Export IKEv2")
            #if os(iOS)
            .listSectionSpacing(.compact)
            #endif
            .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: "VayuSetu-IKEv2.vayubackup") { _ in document = EncryptedBackupDocument(); password = ""; confirmation = "" }
            .onDisappear { password = ""; confirmation = ""; document = EncryptedBackupDocument() }
    }
}

#if os(iOS)
import CoreImage.CIFilterBuiltins
/// A profile as a QR code, to move it to another device. The code contains the private key, so it stays hidden until you ask for it,
/// is hidden again as soon as the app is left, and is never saved or shared anywhere.
struct VSProfileQRScreen: View {
    let name: String
    let configuration: () throws -> String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var failure = ""
    private func reveal() {
        do {
            let text = try configuration()
            guard text.utf8.count <= 2_000 else { failure = "This configuration is too large for a QR code. Use Export instead."; return }
            let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "L"
            guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
                  let cg = CIContext().createCGImage(output, from: output.extent) else { failure = "The QR code could not be made."; return }
            image = UIImage(cgImage: cg); failure = ""
        } catch { failure = "The profile could not be read from Keychain." }
    }
    var body: some View {
        VSCardList {
            VSSection("Move “\(name)” to another device") {
                if let image {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(maxWidth: .infinity).accessibilityLabel("QR code for the profile \(name)")
                    Button("Hide QR Code") { self.image = nil }
                } else {
                    Button("Show QR Code", action: reveal)
                }
                if !failure.isEmpty { Text(failure).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("On the other device open VayuSetu → Profiles → + → Scan QR Code. This code contains the profile’s private key: anyone who scans it can use your VPN account. Show it only to a device you own.")
            }
        }.vsList().vsHeader("Profile QR Code", "Scan with VayuSetu on another device.")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.vsTapHaptic() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { image = nil } }
        .onDisappear { image = nil }
    }
}

private struct VSQRImportScreen: View {
    var accept: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorized = false
    @State private var requesting = false
    @State private var failure = ""
    @State private var captured: String?
    @State private var summary: WireGuardSummary?
    @State private var scanning = false
    @State private var cameraWanted = true
    var body: some View {
        VStack(spacing: 16) {
            if let summary {
                List {
                    VSFormSection("Configuration recognized") {
                        Label("WireGuard configuration", systemImage: "checkmark.circle")
                        VSRow(title: "Peers", value: String(summary.peerCount))
                        VSRow(title: "Routing", value: summary.fullTunnel ? "Full tunnel" : "Custom routes")
                        Text("Private keys stay hidden. Nothing has been saved or connected.").font(.footnote).foregroundStyle(.secondary)
                    }
                    VSFormSection {
                        Button("Review Profile") { if let captured { accept(captured) } }
                        Button("Scan Again") { captured = nil; self.summary = nil; failure = ""; cameraWanted = true; startCamera() }
                    }
                }.vsList()
            } else if scanning && authorized && scenePhase == .active {
                VSQRScannerCamera(receive: receive, failed: { failure = "Camera scanning is unavailable. Retry or use file import."; scanning = false; cameraWanted = false })
                    .clipShape(RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 20)
                    .accessibilityLabel("WireGuard QR camera")
                Text("Point the camera at a WireGuard QR code. Images are not stored or uploaded.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
                Button("Stop Camera") { scanning = false; cameraWanted = false }.buttonStyle(.bordered).vsTapHaptic()
            } else if requesting {
                ProgressView("Requesting camera access…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 44)).foregroundStyle(VSDesign.accent)
                    Text("Scan a WireGuard configuration").font(.title2.weight(.semibold))
                    Text("Camera access is used only while scanning. The app validates the code and lets you review it before saving. No connection starts automatically.").font(.subheadline).foregroundStyle(.secondary)
                    Button { cameraWanted = true; startCamera() } label: {
                        Text(requesting ? "Requesting access…" : authorized ? "Start Camera" : "Continue to Camera")
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.borderedProminent).vsTapHaptic().disabled(requesting)
                    if AVCaptureDevice.authorizationStatus(for: .video) == .denied || AVCaptureDevice.authorizationStatus(for: .video) == .restricted {
                        Text("Camera access is unavailable. You can enable it in Settings or use file import.").font(.footnote).foregroundStyle(.secondary)
                        Button("Open App Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    }
                }.padding(16)
                Spacer()
            }
            if !failure.isEmpty {
                Text(failure).font(.footnote).foregroundStyle(.orange).padding(.horizontal, 20)
                if !scanning { Button("Try Again") { captured = nil; summary = nil; failure = ""; startCamera() } }
            }
        }.padding(.bottom, 20).background(VSDesign.background).vsHeader("Scan QR Code")
            .vsInlineTitle()
            .toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.vsTapHaptic() } }
            .task { startCamera() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { scanning = false }
                else if cameraWanted && authorized && summary == nil && failure.isEmpty { startCamera() }
            }
            .onDisappear { scanning = false; cameraWanted = false }
    }
    private func startCamera() {
        guard !requesting else { return }; requesting = true
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                DispatchQueue.main.async { completeCameraPermission(allowed) }
            }
        } else { completeCameraPermission(status == .authorized) }
    }
    private func completeCameraPermission(_ allowed: Bool) {
        requesting = false; authorized = allowed
        guard allowed else { failure = "Camera permission was not granted. No image was captured."; return }
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else { failure = "This device cannot run the QR scanner. Use configuration file import."; return }
        failure = ""; scanning = true
    }
    private func receive(_ text: String) {
        scanning = false; cameraWanted = false
        do { let parsed = try QRConfigurationImport.validate(text); captured = text; summary = parsed; failure = "" }
        catch { captured = nil; summary = nil; failure = "This QR code is not a supported WireGuard configuration. Use a complete configuration QR code without shell commands." }
    }
}
private struct VSQRScannerCamera: UIViewControllerRepresentable {
    var receive: (String) -> Void
    var failed: () -> Void
    func makeUIViewController(context: Context) -> QRScannerHost {
        QRScannerHost(receive: receive, failed: failed)
    }
    func updateUIViewController(_ controller: QRScannerHost, context: Context) {}
    static func dismantleUIViewController(_ controller: QRScannerHost, coordinator: ()) { controller.scanner.stopScanning() }
    final class QRScannerHost: UIViewController, DataScannerViewControllerDelegate {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        let receive: (String) -> Void
        let failed: () -> Void
        private var delivered = false
        init(receive: @escaping (String) -> Void, failed: @escaping () -> Void) { self.receive = receive; self.failed = failed; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidLoad() {
            super.viewDidLoad(); scanner.delegate = self
            addChild(scanner); view.addSubview(scanner.view); scanner.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), scanner.view.topAnchor.constraint(equalTo: view.topAnchor), scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
            scanner.didMove(toParent: self)
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); do { try scanner.startScanning() } catch { DispatchQueue.main.async { self.failed() } } }
        override func viewWillDisappear(_ animated: Bool) { scanner.stopScanning(); super.viewWillDisappear(animated) }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { capture(addedItems) }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { capture([item]) }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { scanner.stopScanning(); failed() }
        private func capture(_ items: [RecognizedItem]) {
            guard !delivered else { return }
            for item in items {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    delivered = true; scanner.stopScanning(); DispatchQueue.main.async { self.receive(text) }; return
                }
            }
        }
    }
}
#endif

#if os(iOS)
// MARK: - Profiles dashboard. The view draws `ConnectionSummaryModel` and `ProfileRowModel`; selection is a preference, connection is observed.
extension VSProfilesScreen {
    fileprivate var border: Color { VSDesign.separator }
    fileprivate func tint(_ tone: DNSTone) -> Color {
        switch tone {
        case .good: return Color.green
        case .caution: return Color.orange
        case .bad: return Color.red
        case .neutral: return .secondary
        }
    }
    /// Observed state of the remote VPN (never VayuSetu's local DNS tunnel).
    fileprivate var remoteLink: ProfileLinkState {
        guard tunnel.running, !tunnel.localDNSRunning else { return tunnel.stage == .failed && store.selection.vpnEnabled ? .failed : .off }
        switch tunnel.status {
        case .connected: return .connected
        case .disconnecting: return .disconnecting
        default: return .connecting
        }
    }
    fileprivate func link(for id: UUID) -> ProfileLinkState {
        if tunnel.running && !tunnel.localDNSRunning && tunnel.configuredProfile == id { return remoteLink }
        if remoteLink == .failed, (store.selected == id && store.selectedManualProfile == nil) || store.selectedManualProfile == id { return .failed }
        return .off
    }
    fileprivate var selectedName: String? {
        if let id = store.selectedManualProfile { return store.manualDrafts.first { $0.id == id }?.name }
        return store.active?.name
    }
    fileprivate var summary: ConnectionSummaryModel {
        let remote = tunnel.running && !tunnel.localDNSRunning
        return ConnectionSummaryModel.make(ConnectionSummaryInput(
            link: remoteLink, runningName: remote ? store.connectionName : nil,
            runningKind: remote ? (tunnel.protocolName == "IKEv2" ? .ikev2 : .wireGuard) : nil,
            selectedName: selectedName, selectedKind: store.selectedVPNKind, localDNSRunning: tunnel.localDNSRunning, busy: tunnel.busy || store.protectionBusy))
    }
    fileprivate func rowModel(_ profile: VSStoredProfile) -> ProfileRowModel {
        let kind: VPNKind
        switch profile { case .wireGuard: kind = .wireGuard; case .native(let value): kind = value.protocolKind == .ikev2 ? .ikev2 : .openVPN }
        let selected: Bool
        switch profile {
        case .wireGuard(let value): selected = store.selected == value.id && store.selectedManualProfile == nil && !store.dnsOnlyChosen
        case .native(let value): selected = store.selectedManualProfile == value.id
        }
        return ProfilesModel.row(ProfileRowInput(id: profile.id, name: profile.name, kind: kind, selected: selected, link: link(for: profile.id), lastUsed: store.lastUsed[profile.id.uuidString]))
    }

    fileprivate var profilesDashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                profilesHeader
                summaryCard
                profileListSection
                preferencesSection
                if !store.manualDraftStorageError.isEmpty { Text(store.manualDraftStorageError).font(.caption).foregroundStyle(.orange) }
            }.padding(.horizontal, 16).padding(.bottom, 110)
        }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively).background(VSDesign.background)
    }
    fileprivate var summaryCard: some View {
        let model = summary; let color = tint(model.tone)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if model.showsProgress { ProgressView().controlSize(.small).tint(color) } else { Circle().fill(color).frame(width: 8, height: 8) }
                Text(model.stateLabel).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(color)
            }
            let text = VStack(alignment: .leading, spacing: 3) {
                Text(model.headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(model.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            let buttons = HStack(spacing: 8) {
                if model.action != .none {
                    Button { Task { await store.togglePill(.vpn) } } label: { Text(model.actionTitle) }
                        .buttonStyle(VSCompactButtonStyle(prominent: model.action == .connect))
                        .disabled(store.protectionBusy || tunnel.busy || store.connectionOperation).accessibilityIdentifier("ProfilesSummaryAction")
                }
                Button { showingConnectionDetails = true } label: { HStack(spacing: 3) { Text("Details"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) } }
                    .buttonStyle(VSCompactButtonStyle()).accessibilityIdentifier("ProfilesConnectionDetails")
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) { text; Spacer(minLength: 8); buttons }
                VStack(alignment: .leading, spacing: 4) { text; buttons }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
            .accessibilityElement(children: .contain).accessibilityIdentifier("ProfilesSummary")
    }

    fileprivate var profileListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("YOUR PROFILES").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Text(String(store.profiles.count + store.manualDrafts.count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search profiles", text: $search).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                if !search.isEmpty {
                    Button { search = ""; searchFocused = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                        .buttonStyle(VSPlainButtonStyle()).accessibilityLabel("Clear profile search")
                }
            }.padding(.horizontal, 12).frame(minHeight: 40).background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Menu {
                    Picker("Filter profiles", selection: $protocolFilter) { ForEach(["All Profiles", "WireGuard", "IKEv2", "Connected", "Recently Used"], id: \.self) { Text($0).tag($0) } }
                } label: { Label(protocolFilter == "All Profiles" ? "All" : protocolFilter, systemImage: "line.3.horizontal.decrease").font(.caption.weight(.medium)).frame(minHeight: 36) }
                    .accessibilityLabel("Filter profiles")
                Spacer(minLength: 8)
                Menu {
                    Picker("Sort profiles", selection: $sort) { ForEach(["Recently Used", "Name A–Z", "Name Z–A", "Recently Added", "Protocol"], id: \.self) { Text($0).tag($0) } }
                } label: { Label(sort, systemImage: "arrow.up.arrow.down").font(.caption.weight(.medium)).frame(minHeight: 36) }
                    .accessibilityLabel("Sort profiles")
            }.foregroundStyle(.secondary)
            noProfileCard
            ForEach(unifiedProfiles) { profile in
                let model = rowModel(profile)
                profileCard(model, primary: { tapped(profile) }) { menu(for: profile) }
            }
            if unifiedProfiles.isEmpty { Text("No matching profiles").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(12) }
        }
    }
    fileprivate func tapped(_ profile: VSStoredProfile) {
        switch profile {
        case .wireGuard(let value):
            if tunnel.running && tunnel.configuredProfile == value.id { return }
            if tunnel.running { switching = value } else { store.selectProfile(value) }
        case .native(let value):
            guard value.protocolKind == .ikev2 else { store.notice = "OpenVPN is unavailable while its engine and licensing are on hold."; return }
            if tunnel.running && tunnel.configuredProfile == value.id { return }
            if tunnel.running { switchingNative = value } else { store.selectManual(value) }
        }
    }
    fileprivate var noProfileCard: some View {
        let chosen = store.dnsOnlyChosen
        return Button { store.selectNoVPNProfile() } label: {
            HStack(spacing: 12) {
                Image(systemName: "network").font(.system(size: 17)).foregroundStyle(chosen ? VSDesign.accent : .secondary).frame(width: 34, height: 34)
                    .background(VSDesign.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("No VPN profile").font(.subheadline.weight(.semibold))
                    Text("DNS Only · no remote VPN").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if chosen { Label("Selected", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(VSDesign.accent).labelStyle(.titleAndIcon) }
            }.padding(10).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).contentShape(Rectangle())
                .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(chosen ? VSDesign.accent.opacity(0.7) : border, lineWidth: chosen ? 1.5 : 1))
        }.buttonStyle(VSPlainButtonStyle()).disabled(tunnel.busy || store.connectionOperation || store.protectionBusy).accessibilityIdentifier("ProfileNoVPN")
            .accessibilityLabel("No VPN profile, DNS Only" + (chosen ? ", selected" : ""))
    }
    fileprivate func profileCard<Menu: View>(_ model: ProfileRowModel, primary: @escaping () -> Void, @ViewBuilder menu: () -> Menu) -> some View {
        HStack(spacing: 4) {
            Button(action: primary) {
                HStack(spacing: 12) {
                    Image(systemName: model.icon).font(.system(size: 17)).foregroundStyle(model.isActive ? tint(.good) : model.isSelected ? VSDesign.accent : .secondary).frame(width: 34, height: 34)
                        .background(VSDesign.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(model.protocolName + " · " + model.dnsLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        statusLabel(model.status)
                    }
                    Spacer(minLength: 4)
                }.padding(.leading, 10).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(VSPlainButtonStyle()).disabled(!model.isUsable || tunnel.busy || store.connectionOperation || store.protectionBusy).accessibilityIdentifier("ProfileListRow")
            SwiftUI.Menu { menu() } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Actions for " + model.name)
        }.padding(.vertical, 3).padding(.trailing, 2)
            .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.isSelected ? VSDesign.accent.opacity(0.7) : border, lineWidth: model.isSelected ? 1.5 : 1))
            .accessibilityElement(children: .contain)
    }
    @ViewBuilder fileprivate func statusLabel(_ status: ProfileStatus) -> some View {
        switch status {
        case .connected: Label("Connected", systemImage: "circle.fill").font(.caption.weight(.semibold)).foregroundStyle(tint(.good)).labelStyle(DotLabelStyle())
        case .connecting: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Connecting…").font(.caption).foregroundStyle(tint(.caution)) }
        case .disconnecting: Text("Disconnecting…").font(.caption).foregroundStyle(tint(.caution))
        case .failed: Text("Connection failed").font(.caption.weight(.semibold)).foregroundStyle(tint(.bad))
        case .selected: Label("Selected", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(VSDesign.accent)
        case .lastUsed(let date): Text("Last used " + date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
        case .neverUsed: Text("Never used").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder fileprivate func menu(for profile: VSStoredProfile) -> some View {
        switch profile {
        case .wireGuard(let value): profileMenu(value)
        case .native(let value): nativeMenu(value)
        }
    }
    @ViewBuilder fileprivate func nativeMenu(_ summary: ManualVPNDraftSummary) -> some View {
        let current = tunnel.running && tunnel.configuredProfile == summary.id
        if current { Button("Disconnect", systemImage: "power") { Task { await store.togglePill(.vpn) } }.disabled(tunnel.busy || store.connectionOperation) }
        else if summary.protocolKind == .ikev2 {
            Button("Connect", systemImage: "power") { if tunnel.running { switchingNative = summary } else { store.selectAndConnectManual(summary) } }.disabled(tunnel.busy || store.connectionOperation)
            if store.selectedManualProfile != summary.id { Button("Select Profile", systemImage: "checkmark.circle") { if tunnel.running { switchingNative = summary } else { store.selectManual(summary) } }.disabled(tunnel.busy || store.connectionOperation) }
        }
        Button("Edit Configuration", systemImage: "pencil") { do { manualDraft = try store.manualDraft(summary) } catch { store.notice = "Could not read the profile from Keychain." } }.disabled(tunnel.running || tunnel.busy || store.connectionOperation)
        Button("Export / Back Up (contains credentials)", systemImage: "square.and.arrow.up") { do { nativeExport = try store.manualDraft(summary) } catch { store.notice = "Could not read the profile from Keychain." } }
        Button("Delete", systemImage: "trash", role: .destructive) { deletingNative = summary }.disabled(tunnel.running || tunnel.busy || store.connectionOperation)
    }
    fileprivate var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONNECTION PREFERENCES").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                NavigationLink { VSPrivacyLockScreen(store: store, tunnel: tunnel) } label: {
                    VSRow(title: "Connection Rules & Privacy Lock", subtitle: store.strictRouting ? "Privacy Lock requested" : "Privacy Lock off", icon: "arrow.triangle.branch", chevron: true).padding(14)
                }.buttonStyle(VSPlainButtonStyle())
                Divider().padding(.leading, 56)
                NavigationLink { VSChecksScreen(store: store, tunnel: tunnel, network: diagnosticsNetwork) } label: {
                    VSRow(title: "Connection Diagnostics", subtitle: "Checks and measured evidence", icon: "waveform.path.ecg", chevron: true).padding(14)
                }.buttonStyle(VSPlainButtonStyle())
            }.background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
        }
    }
}
private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 6) { configuration.icon.font(.system(size: 6)); configuration.title } }
}
#endif
