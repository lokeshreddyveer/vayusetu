import WidgetKit
import SwiftUI
import ActivityKit

@main struct VayuSetuActivityBundle: WidgetBundle {
    @WidgetBundleBuilder var body: some Widget {
        VayuSetuConnectionWidget()
        VayuSetuStatusWidget()
        if #available(iOS 18.0, *) {
            DNSOnlyControl()
            VPNControl()
            TurnOffControl()
            AdblockControl()
        }
    }
}

private extension ConnectionActivityAttributes.ContentState {
    var tint: Color {
        switch tone {
        case .on: Color(red: 0.30, green: 0.87, blue: 0.55)
        case .off: Color(red: 1.0, green: 0.62, blue: 0.35)
        case .info: Color(red: 0.35, green: 0.78, blue: 1.0)
        }
    }
}

private struct EventBadge: View {
    let state: ConnectionActivityAttributes.ContentState
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: state.symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(state.tint)
            .frame(width: size, height: size).background(state.tint.opacity(0.18), in: Circle())
    }
}

struct VayuSetuConnectionWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ConnectionActivityAttributes.self) { context in
            lockScreen(context.state)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { EventBadge(state: state).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(state.title).font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1)
                        if !state.detail.isEmpty { Text(state.detail).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            } compactLeading: {
                Image(systemName: state.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(state.tint)
            } compactTrailing: {
                Text(state.short).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(state.tint).lineLimit(1)
            } minimal: {
                Image(systemName: state.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(state.tint)
            }
            .keylineTint(state.tint)
        }
    }

    private func lockScreen(_ state: ConnectionActivityAttributes.ContentState) -> some View {
        HStack(spacing: 14) {
            EventBadge(state: state, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title).font(.system(size: 17, weight: .semibold, design: .rounded))
                if !state.detail.isEmpty { Text(state.detail).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .activityBackgroundTint(Color(red: 0.055, green: 0.085, blue: 0.125))
        .activitySystemActionForegroundColor(.white)
    }
}
