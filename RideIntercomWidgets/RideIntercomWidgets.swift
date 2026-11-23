import AppIntents
import SwiftUI
import WidgetKit

@main
struct RideIntercomWidgets: WidgetBundle {
    var body: some Widget {
        SelectedCallWidget()
        #if os(iOS)
        DestinationCallControl()
        RecentCallControl()
        CallLiveActivityWidget()
        #endif
    }
}

#if os(iOS)
/// Connects to the destination chosen when the Control was added. It never ends a call:
/// the Control Center opens on the lock screen, where nothing irreversible belongs.
struct DestinationCallControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: CallSurfaceKind.destinationControl.rawValue, provider: Provider()
        ) { state in
            ControlWidgetButton(action: Self.action(for: state)) {
                DestinationControlLabel(state: state)
            }
        }
        .displayName("Call destination")
        .description("Connect to the person or group you choose when adding this control.")
        .promptsForUserConfiguration()
    }

    /// Ready: open the app and start that destination (device unlock, as for every Control).
    /// Not set, removed, or already active: open the app, which shows the live call.
    static func action(for state: CallControlState) -> OpenCallControlIntent {
        if case .ready(let destination) = state { return OpenCallControlIntent(destinationID: destination.id) }
        return OpenCallControlIntent(action: .calls)
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: SelectControlCallDestination) -> CallControlState {
            configuration.destination.map { .ready($0) } ?? .unconfigured
        }
        func currentValue(configuration: SelectControlCallDestination) async throws -> CallControlState {
            CallControlState(
                configured: configuration.destination, snapshot: WidgetDestinationStore.system.readSnapshot())
        }
    }
}
struct DestinationControlLabel: View {
    let state: CallControlState
    var body: some View {
        switch state {
        case .unconfigured:
            Label("Set a destination", systemImage: "plus")
        case .ready(let destination):
            Label { Text(verbatim: destination.name); Text("Connect") } icon: { Image(systemName: "phone.fill") }
        case .active(let destination, let status):
            Label {
                Text(verbatim: destination.name)
                Text(LocalizedStringKey(status.title))
            } icon: {
                Image(systemName: status.systemSurfaceSymbol).foregroundStyle(status.systemSurfaceColor)
            }
        case .unavailable:
            Label("Set the destination again", systemImage: "plus")
        }
    }
}

struct RecentCallControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "RideIntercom.RecentCall") {
            ControlWidgetButton(action: OpenCallControlIntent(action: .recent)) {
                Label("Resume recent call", systemImage: "arrow.clockwise")
            }
        }.displayName("Resume recent call").description("Open RideCom and connect to your recent call.")
    }
}
#endif
