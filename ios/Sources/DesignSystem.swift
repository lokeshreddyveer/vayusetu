import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum VSDesign {
    #if os(macOS)
    static let accent = adaptive(dark: 0x2DB6C9, light: 0x087B8D)
    static let actionInk = adaptive(dark: 0x070B12, light: 0xFFFFFF)
    #else
    static let accent = Color(red: 0.196, green: 0.529, blue: 1)
    static let actionInk = Color.white
    #endif
    #if os(iOS)
    /// A deep blue-black in Dark Mode with slightly lifted cards and hairline edges; the system colours in Light Mode.
    static let separator = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor.separator })
    static let background = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.027, green: 0.039, blue: 0.063, alpha: 1) : UIColor.systemGroupedBackground })
    static let surface = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.067, green: 0.090, blue: 0.133, alpha: 1) : UIColor.secondarySystemGroupedBackground })
    static let elevated = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.086, green: 0.114, blue: 0.165, alpha: 1) : UIColor.secondarySystemGroupedBackground })
    #else
    static let separator = Color(red: 39/255, green: 51/255, blue: 66/255)
    static let background = adaptive(dark: 0x070B12, light: 0xF2F3F5)
    static let surface = adaptive(dark: 0x111A25, light: 0xFFFFFF)
    static let elevated = adaptive(dark: 0x192535, light: 0xFFFFFF)
    #endif
    private static func adaptive(dark: Int, light: Int) -> Color {
        func components(_ hex: Int) -> (Double, Double, Double) { (Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255) }
        #if os(iOS)
        return Color(UIColor { trait in
            let (r,g,b) = components(trait.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #else
        return Color(NSColor(name: nil) { appearance in
            let (r,g,b) = components(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
    static func copy(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
    static func clipboard() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}
struct VSActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Group {
            #if os(macOS)
            configuration.label.font(.body.weight(.semibold)).padding(.horizontal, 20).frame(minHeight: 36)
            #else
            configuration.label.font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 44)
            #endif
        }.foregroundStyle(primary ? VSDesign.actionInk : VSDesign.accent)
            .background(primary ? AnyShapeStyle(LinearGradient(colors: [VSDesign.accent, VSDesign.accent.opacity(0.78)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(VSDesign.accent.opacity(0.14)), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .shadow(color: primary ? VSDesign.accent.opacity(0.3) : .clear, radius: 8, y: 3)
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .vsPressHaptic(configuration.isPressed, strong: primary)
    }
}
struct VSRow: View {
    let title: String
    var subtitle: String = ""
    var icon: String = ""
    var value: String = ""
    var selected = false
    var chevron = false
    var body: some View {
        HStack(spacing: 12) {
            if !icon.isEmpty { Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(selected ? Color.white : VSDesign.accent).frame(width: 32, height: 32).background(selected ? AnyShapeStyle(VSDesign.accent) : AnyShapeStyle(VSDesign.accent.opacity(0.14)), in: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(selected ? .semibold : .regular)).foregroundStyle(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if !value.isEmpty { Text(value).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(VSDesign.accent).accessibilityLabel("Selected") }
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }.frame(minHeight: 26).contentShape(Rectangle())
    }
}
private struct VSInSheetKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var vsInSheet: Bool { get { self[VSInSheetKey.self] } set { self[VSInSheetKey.self] = newValue } } }
/// The screen background: the normal one, or nothing inside a sheet so the sheet's own dark gradient shows through.
private struct VSScreenBackground: ViewModifier {
    @Environment(\.vsInSheet) private var inSheet
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background {
            if !inSheet {
                #if os(iOS)
                if scheme == .dark { LinearGradient(colors: [Color(red: 0.045, green: 0.058, blue: 0.086), Color(red: 0.022, green: 0.031, blue: 0.050)], startPoint: .top, endPoint: .bottom).ignoresSafeArea() }
                else { VSDesign.background }
                #else
                VSDesign.background
                #endif
            }
        }
    }
}
extension View {
    func vsScreenBackground() -> some View { modifier(VSScreenBackground()) }
    func vsList() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped).scrollContentBackground(.hidden).scrollIndicators(.hidden).vsScreenBackground().toolbar(.visible, for: .navigationBar)
        #else
        self.listStyle(.inset).scrollContentBackground(.hidden).scrollIndicators(.hidden).vsScreenBackground()
        #endif
    }
    /// One header for every pushed screen: the same large title and optional one-line subtitle the tab roots use.
    func vsHeader(_ title: String, _ subtitle: String = "") -> some View {
        #if os(iOS)
        self.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { Text("") } }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 28, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    if !subtitle.isEmpty { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 8).background(VSDesign.background)
            }
        #else
        self.navigationTitle(title)
        #endif
    }
    func vsEditor() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        #else
        self.frame(minWidth: 500, minHeight: 440)
        #endif
    }
    func vsInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}


/// Small stat tile shared by the DNS and Filter screens: icon, title, value. In a row every tile gets the same size.
struct VSStatTile: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 17, weight: .regular)).foregroundStyle(tint).frame(height: 24)
            VStack(spacing: 1) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                Text(value).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 6).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSDesign.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine).accessibilityLabel("\(title): \(value)")
    }
}

/// Compact capsule button: 34 pt visual height inside a 44 pt touch target.
struct VSCompactButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold)).lineLimit(1).padding(.horizontal, 14).frame(minHeight: 34)
            .background(prominent ? VSDesign.accent : VSDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(prominent ? Color.white : VSDesign.accent)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .vsPressHaptic(configuration.isPressed, strong: prominent)
            .padding(.vertical, 5).contentShape(Rectangle())
    }
}

extension View {
    /// The card used across the dashboards: surface fill, subtle border, 16 pt padding.
    func vsCard(radius: CGFloat = 12, padding: CGFloat = 12) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Card screens
// One page/section/row vocabulary so every screen shares the Home, DNS and Profiles look: a title, uppercase
// section labels, and rounded bordered cards whose rows are separated by hairlines.

/// Draws each child as a padded row with a divider below it, except the last.
private struct VSCardRows: _VariadicView_UnaryViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 48)
                    .overlay(alignment: .bottom) { if child.id != last { Divider().overlay(VSDesign.separator).padding(.leading, 16) } }
            }
        }
    }
}

struct VSSection<Content: View, Header: View, Footer: View>: View {
    let content: Content
    let header: Header
    let footer: Footer
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary).textCase(.uppercase).padding(.horizontal, 4)
            _VariadicView.Tree(VSCardRows()) { content }
                .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(VSDesign.separator, lineWidth: 1))
            footer.font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
        }
    }
}
extension VSSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { self.init(content: content, header: { EmptyView() }, footer: { EmptyView() }) }
}
extension VSSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { self.init(content: content, header: { Text(title) }, footer: { EmptyView() }) }
}
extension VSSection where Header == Text {
    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) { self.init(content: content, header: { Text(title) }, footer: footer) }
}
extension VSSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) { self.init(content: content, header: header, footer: { EmptyView() }) }
}
extension VSSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) { self.init(content: content, header: { EmptyView() }, footer: footer) }
}

/// A scrolling page of cards. Use in place of `List`.
struct VSCardList<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .buttonStyle(VSRowButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 110)    // clears the floating tab bar, so the last row can be reached and tapped
                #if os(macOS)
                .frame(maxWidth: 880).frame(maxWidth: .infinity)    // on the Mac the pushed pages stay a readable width, centred
                #endif
        }.scrollIndicators(.hidden).vsScreenBackground().scrollDismissesKeyboard(.interactively)
    }
}

/// A row that opens another screen. Use in place of `NavigationLink` inside a card.
struct VSNavLink<Destination: View, Label: View>: View {
    let destination: Destination
    let label: Label
    init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) { self.destination = destination(); self.label = label() }
    var body: some View {
        NavigationLink { destination } label: {
            HStack(spacing: 8) {
                label.foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(VSPlainButtonStyle())
    }
}

extension VSNavLink where Label == Text {
    init(_ title: String, @ViewBuilder destination: () -> Destination) { self.init(destination: destination, label: { Text(title) }) }
}

extension View {
    /// Inline navigation title on iOS; the Mac has no such setting.
    func vsInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension View {
    /// Tab-root screens draw their own header; the iOS navigation bar is hidden for them.
    func vsHideNavigationBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar).navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension View {
    func vsURLKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.URL)
        #else
        self
        #endif
    }
}

#if os(iOS)
typealias PlatformView = UIView
#else
typealias PlatformView = NSView
#endif

/// Buttons placed directly in a card row: the whole row is the tap target, tinted like a system button.
/// Anything that sets its own style (plain rows, action buttons, bordered buttons) keeps it.
struct VSRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(configuration.role == .destructive ? Color.red : VSDesign.accent)
            .opacity(enabled ? (configuration.isPressed ? 0.55 : 1) : 0.4)
            .vsPressHaptic(configuration.isPressed, destructive: configuration.role == .destructive)
    }
}


// MARK: - Haptics
/// One place that decides how a touch feels. A press is a light tick the moment the finger lands; a primary action and a switch turning
/// on are firmer; a destructive action is the firmest. Everything here is a no-op on the Mac.
enum VSHaptic {
    enum Kind { case light, medium, firm, selection }
    static func play(_ kind: Kind) {
        #if os(iOS)
        let run = {
            MainActor.assumeIsolated {
                switch kind {
                case .light: Pads.light.impactOccurred(intensity: 0.8); Pads.light.prepare()
                case .medium: Pads.medium.impactOccurred(); Pads.medium.prepare()
                case .firm: Pads.rigid.impactOccurred(); Pads.rigid.prepare()
                case .selection: Pads.selection.selectionChanged(); Pads.selection.prepare()
                }
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
        #endif
    }
    #if os(iOS)
    @MainActor private enum Pads {
        static let light = UIImpactFeedbackGenerator(style: .light)
        static let medium = UIImpactFeedbackGenerator(style: .medium)
        static let rigid = UIImpactFeedbackGenerator(style: .rigid)
        static let selection = UISelectionFeedbackGenerator()
    }
    #endif
}
private struct VSPressHaptic: ViewModifier {
    let pressed: Bool; let strong: Bool; let destructive: Bool
    func body(content: Content) -> some View {
        content.onChange(of: pressed) { _, now in if now { VSHaptic.play(destructive ? .firm : strong ? .medium : .light) } }
    }
}
extension View {
    /// Feel for a custom button style: fires when the finger lands.
    func vsPressHaptic(_ pressed: Bool, strong: Bool = false, destructive: Bool = false) -> some View { modifier(VSPressHaptic(pressed: pressed, strong: strong, destructive: destructive)) }
    /// Feel for a system-styled control (bordered buttons) that has no style of its own to hook.
    func vsTapHaptic() -> some View { simultaneousGesture(TapGesture().onEnded { VSHaptic.play(.light) }) }
}

/// A plain, unstyled button that still reacts: dims and ticks when pressed.
struct VSPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1).contentShape(Rectangle()).vsPressHaptic(configuration.isPressed)
    }
}
/// The default for every button that does not choose a style (toolbar, forms, sheets): accent coloured, with haptics.
struct VSDefaultButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? Color.red : VSDesign.accent)
            .opacity(enabled ? (configuration.isPressed ? 0.55 : 1) : 0.4)
            .contentShape(Rectangle())
            .vsPressHaptic(configuration.isPressed, destructive: configuration.role == .destructive)
    }
}

/// Every Toggle in the app feels like a switch: a firm tap turning on, a lighter one turning off.
/// Declared here so it replaces SwiftUI's Toggle throughout the module.
struct Toggle<Content: View>: View {
    private let isOn: Binding<Bool>
    private let content: Content
    init(isOn: Binding<Bool>, @ViewBuilder label: () -> Content) { self.isOn = isOn; self.content = label() }
    var body: some View {
        SwiftUI.Toggle(isOn: Binding(get: { isOn.wrappedValue }, set: { value in VSHaptic.play(value ? .medium : .light); isOn.wrappedValue = value })) { content }
    }
}
extension Toggle where Content == Text {
    init(_ title: String, isOn: Binding<Bool>) { self.init(isOn: isOn) { Text(title) } }
}
/// Segmented and menu pickers tick as the selection moves.
struct Picker<SelectionValue: Hashable, Content: View>: View {
    private let title: String
    private let selection: Binding<SelectionValue>
    private let content: Content
    init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) { self.title = title; self.selection = selection; self.content = content() }
    var body: some View {
        SwiftUI.Picker(title, selection: Binding(get: { selection.wrappedValue }, set: { value in if value != selection.wrappedValue { VSHaptic.play(.selection) }; selection.wrappedValue = value })) { content }
    }
}
struct Stepper<Value: Strideable, Content: View>: View {
    private let value: Binding<Value>
    private let bounds: ClosedRange<Value>
    private let step: Value.Stride
    private let content: Content
    init(value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value.Stride = 1, @ViewBuilder label: () -> Content) { self.value = value; self.bounds = bounds; self.step = step; self.content = label() }
    var body: some View {
        SwiftUI.Stepper(value: Binding(get: { value.wrappedValue }, set: { new in if new != value.wrappedValue { VSHaptic.play(.selection) }; value.wrappedValue = new }), in: bounds, step: step) { content }
    }
}
extension Stepper where Content == Text {
    init(_ title: String, value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value.Stride = 1) { self.init(value: value, in: bounds, step: step) { Text(title) } }
}

// MARK: - Dialogs
/// One look for every alert and confirmation: an icon, a clear title, a short explanation and full-width buttons, on a dimmed background.
struct VSDialogAction: Identifiable {
    enum Kind { case primary, destructive, plain, cancel }
    let id = UUID()
    let title: String
    var kind: Kind = .primary
    var run: () -> Void = {}
}
enum VSDialogTone {
    case info, warning, danger
    var color: Color { switch self { case .info: VSDesign.accent; case .warning: .orange; case .danger: .red } }
    var icon: String { switch self { case .info: "info.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .danger: "exclamationmark.octagon.fill" } }
}
struct VSDialogRequest: Identifiable {
    let id: UUID; let tone: VSDialogTone; let icon: String; let title: String; let message: String
    let actions: [VSDialogAction]; let finished: () -> Void
}
@MainActor final class VSDialogCenter: ObservableObject {
    static let shared = VSDialogCenter()
    @Published private(set) var current: VSDialogRequest?
    @Published private(set) var hosts: [UUID] = []
    private var queue: [VSDialogRequest] = []
    func register(_ id: UUID) { hosts.removeAll { $0 == id }; hosts.append(id) }
    func unregister(_ id: UUID) { hosts.removeAll { $0 == id } }
    func present(_ request: VSDialogRequest) {
        guard current?.id != request.id, !queue.contains(where: { $0.id == request.id }) else { return }
        if current == nil { current = request } else { queue.append(request) }
    }
    func withdraw(_ id: UUID) {
        queue.removeAll { $0.id == id }
        if current?.id == id { current = nil; showNext() }
    }
    /// Runs the chosen action first, so state the action reads is still in place, then closes the dialog.
    func finish(_ action: VSDialogAction?) {
        guard let request = current else { return }
        action?.run()
        current = nil
        request.finished()
        showNext()
    }
    private func showNext() {
        guard current == nil, !queue.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in if current == nil, !queue.isEmpty { current = queue.removeFirst() } }
    }
}
private struct VSDialogCard: View {
    let request: VSDialogRequest
    let choose: (VSDialogAction?) -> Void
    @State private var shown = false
    @State private var drag: CGFloat = 0
    private var tint: Color { request.tone.color }
    private var dismissAction: VSDialogAction? { request.actions.first { $0.kind == .cancel } ?? (request.actions.count == 1 ? request.actions[0] : nil) }
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(shown ? 0.5 : 0).ignoresSafeArea()
                .contentShape(Rectangle()).onTapGesture { if let action = dismissAction { choose(action) } }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 40, height: 5).frame(maxWidth: .infinity).accessibilityHidden(true)
                HStack(spacing: 14) {
                    Image(systemName: request.icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: 48, height: 48).background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous)).accessibilityHidden(true)
                    Text(request.title).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if !request.message.isEmpty { Text(request.message).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                VStack(spacing: 10) { ForEach(ordered) { button($0) } }.padding(.top, 4)
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 22)
            .frame(maxWidth: 560)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32).fill(VSDesign.elevated)
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .ignoresSafeArea(edges: .bottom)
            }
            .shadow(color: .black.opacity(0.35), radius: 30, y: -6)
            .offset(y: shown ? max(0, drag) : 600)
            .gesture(DragGesture().onChanged { drag = $0.translation.height }.onEnded { value in
                if value.translation.height > 90, let action = dismissAction { choose(action) } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = 0 } }
            })
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { shown = true }
            VSHaptic.play(request.tone == .danger ? .firm : .medium)
        }
    }
    /// Main action first, then the others, with Cancel last when stacked.
    private var ordered: [VSDialogAction] { request.actions.filter { $0.kind != .cancel } + request.actions.filter { $0.kind == .cancel } }
    private func button(_ action: VSDialogAction) -> some View {
        Button(action.title) { choose(action) }.buttonStyle(VSDialogButtonStyle(kind: action.kind))
    }
}
private struct VSDialogButtonStyle: ButtonStyle {
    let kind: VSDialogAction.Kind
    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = kind == .primary ? VSDesign.accent : kind == .destructive ? .red : kind == .plain ? VSDesign.accent.opacity(0.14) : Color.primary.opacity(0.08)
        let ink: Color = kind == .primary || kind == .destructive ? .white : kind == .plain ? VSDesign.accent : .primary
        return configuration.label.font(.body.weight(kind == .cancel ? .medium : .semibold)).foregroundStyle(ink)
            .frame(maxWidth: .infinity, minHeight: 50).background(fill, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1).scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .vsPressHaptic(configuration.isPressed, strong: kind == .primary, destructive: kind == .destructive)
    }
}
/// Shows the current dialog above this view. The app root and every sheet carry one; only the topmost shows it.
private struct VSDialogHost: ViewModifier {
    @ObservedObject private var center = VSDialogCenter.shared
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .overlay {
                if let request = center.current, center.hosts.last == id {
                    VSDialogCard(request: request) { center.finish($0) }.transition(.opacity).zIndex(100)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: center.current?.id)
            .onAppear { center.register(id) }
            .onDisappear { center.unregister(id) }
    }
}
private struct VSDialogRequester: ViewModifier {
    @Binding var isPresented: Bool
    let tone: VSDialogTone; let icon: String?; let title: String; let message: String; let actions: [VSDialogAction]
    @State private var id = UUID()
    private func show() {
        let binding = $isPresented
        VSDialogCenter.shared.present(VSDialogRequest(id: id, tone: tone, icon: icon ?? tone.icon, title: title, message: message, actions: actions, finished: { binding.wrappedValue = false }))
    }
    func body(content: Content) -> some View {
        #if os(macOS)
        // The Mac uses the system alert: a centred, native dialog rather than the phone's slide-up sheet.
        content.alert(title, isPresented: $isPresented) {
            ForEach(actions) { action in
                Button(action.title, role: action.kind == .destructive ? .destructive : action.kind == .cancel ? .cancel : nil) { action.run() }
            }
        } message: { if !message.isEmpty { Text(message) } }
        #else
        content
            .onChange(of: isPresented) { _, now in if now { show() } else { VSDialogCenter.shared.withdraw(id) } }
            .onAppear { if isPresented { show() } }
            .onDisappear { if isPresented { VSDialogCenter.shared.withdraw(id); isPresented = false } }
        #endif
    }
}
extension View {
    func vsDialogHost() -> some View { modifier(VSDialogHost()) }
    func vsDialog(isPresented: Binding<Bool>, tone: VSDialogTone = .info, icon: String? = nil, title: String, message: String = "", actions: [VSDialogAction]) -> some View {
        modifier(VSDialogRequester(isPresented: isPresented, tone: tone, icon: icon, title: title, message: message, actions: actions))
    }
    /// A question with one confirming action and Cancel.
    func vsConfirm(isPresented: Binding<Bool>, title: String, message: String = "", confirm: String, destructive: Bool = false, icon: String? = nil, cancel: String = "Cancel", action: @escaping () -> Void) -> some View {
        vsDialog(isPresented: isPresented, tone: destructive ? .danger : .info, icon: icon, title: title, message: message,
                 actions: [VSDialogAction(title: confirm, kind: destructive ? .destructive : .primary, run: action), VSDialogAction(title: cancel, kind: .cancel)])
    }
    /// A message with a single OK.
    func vsAlert(isPresented: Binding<Bool>, tone: VSDialogTone = .warning, icon: String? = nil, title: String, message: String = "", button: String = "OK", then: @escaping () -> Void = {}) -> some View {
        vsDialog(isPresented: isPresented, tone: tone, icon: icon, title: title, message: message, actions: [VSDialogAction(title: button, kind: .primary, run: then)])
    }
}

// MARK: - Sheets
extension View {
    /// The shared look of every slide-up sheet: grabber, generous corners, a calm background with a soft glow, and sensible heights.
    @ViewBuilder func vsSheetChrome(_ detents: Set<PresentationDetent> = [.large]) -> some View {
        #if os(iOS)
        self.presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(34)
            .presentationContentInteraction(.scrolls)
            .presentationBackground {
                ZStack(alignment: .top) {
                    LinearGradient(colors: [VSSheet.top, VSSheet.bottom], startPoint: .top, endPoint: .bottom)
                }.ignoresSafeArea()
            }
            .preferredColorScheme(.dark)
            .environment(\.vsInSheet, true)
        #else
        self
        #endif
    }
}
/// A round close button for information sheets; the system draws it as a glass circle in the bar.
struct VSCloseButton: View {
    var label = "Close"
    let action: () -> Void
    var body: some View {
        Button { VSHaptic.play(.light); action() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)) }
            .accessibilityLabel(label)
    }
}

/// The deep dark palette used by every slide-up sheet.
enum VSSheet {
    static let top = Color(red: 0.055, green: 0.07, blue: 0.10)
    static let bottom = Color(red: 0.027, green: 0.035, blue: 0.055)
    static let card = Color(red: 0.085, green: 0.105, blue: 0.145)
}

// MARK: - Form sections
/// A `Section` for List/Form screens that wears the same surface and separators as the card screens.
struct VSFormSection<Content: View, Header: View, Footer: View>: View {
    let content: Content, header: Header, footer: Footer
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer()
    }
    var body: some View {
        Section {
            content.listRowBackground(VSDesign.surface).listRowSeparatorTint(VSDesign.separator)
        } header: { header } footer: { footer }
    }
}
extension VSFormSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { self.init(content: content, header: { EmptyView() }, footer: { EmptyView() }) }
}
extension VSFormSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { self.init(content: content, header: { Text(title) }, footer: { EmptyView() }) }
}
extension VSFormSection where Header == Text {
    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) { self.init(content: content, header: { Text(title) }, footer: footer) }
}
extension VSFormSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) { self.init(content: content, header: header, footer: { EmptyView() }) }
}
extension VSFormSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) { self.init(content: content, header: { EmptyView() }, footer: footer) }
}
extension View {
    /// Form and List screens: the same background as every other screen, with the card surface on their rows.
    func vsFormLook() -> some View { self.scrollContentBackground(.hidden).vsScreenBackground() }
}

extension View {
    @ViewBuilder func vsNoCapitalize() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

// MARK: - Platform image
#if os(iOS)
typealias PlatformImage = UIImage
extension PlatformImage { static func make(_ cg: CGImage) -> PlatformImage { UIImage(cgImage: cg) } }
extension Image { init(platformImage: PlatformImage) { self.init(uiImage: platformImage) } }
#else
typealias PlatformImage = NSImage
extension PlatformImage { static func make(_ cg: CGImage) -> PlatformImage { NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) } }
extension Image { init(platformImage: PlatformImage) { self.init(nsImage: platformImage) } }
#endif
