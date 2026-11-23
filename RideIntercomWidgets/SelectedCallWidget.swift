import AppIntents
import SwiftUI
import WidgetKit

private struct SelectedCallEntry: TimelineEntry {
    let date: Date
    let destination: WidgetCallDestination?
    let currentCall: CallLivePresentation?
}

private struct SelectedCallProvider: AppIntentTimelineProvider {
    typealias Intent = SelectWidgetCallDestination
    func placeholder(in context: Context) -> SelectedCallEntry {
        .init(date: .now, destination: nil, currentCall: nil)
    }
    func snapshot(for configuration: Intent, in context: Context) async -> SelectedCallEntry {
        entry(for: configuration.destination, snapshot: WidgetDestinationStore.system.readSnapshot(), at: .now)
    }
    func timeline(for configuration: Intent, in context: Context) async -> Timeline<SelectedCallEntry> {
        let snapshot = WidgetDestinationStore.system.readSnapshot()
        let current = entry(for: configuration.destination, snapshot: snapshot, at: .now)
        guard current.currentCall != nil, let deadline = snapshot?.currentCallDeadline else {
            return .init(entries: [current], policy: .never)
        }
        let expired = SelectedCallEntry(date: deadline, destination: current.destination, currentCall: nil)
        return .init(entries: [current, expired], policy: .never)
    }

    private func entry(
        for configured: WidgetCallDestination?, snapshot: WidgetDestinationSnapshot?, at date: Date
    ) -> SelectedCallEntry {
        let destination = configured.flatMap { selected in
            snapshot?.destinations.first { $0.id == selected.id }
        }
        let currentCall = snapshot?.currentCall(for: destination, at: date)
        return .init(date: date, destination: destination, currentCall: currentCall)
    }
}

struct SelectedCallWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: CallSurfaceKind.selectedWidget.rawValue, intent: SelectWidgetCallDestination.self,
            provider: SelectedCallProvider()) { entry in
            SelectedCallContent(destination: entry.destination, currentCall: entry.currentCall)
                .containerBackground(for: .widget) { WidgetSurfaceBackground() }
        }
        .configurationDisplayName("Selected call")
        .description("Start a call with a saved user or group you choose.")
        .supportedFamilies([.systemSmall])
    }
}
