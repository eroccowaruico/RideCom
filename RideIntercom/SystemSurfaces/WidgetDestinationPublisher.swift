import Foundation
import Observation
import WidgetKit

// This extension belongs only to the app target; the widget has no writer API.
extension WidgetDestinationStore {
    func write(_ destinations: [WidgetCallDestination]) throws {
        try write(.init(destinations: destinations))
    }
    func write(_ snapshot: WidgetDestinationSnapshot) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }
}

@MainActor final class WidgetDestinationPublisher {
    private let store: WidgetDestinationStore
    private let reload: (CallSurfaceKind) -> Void
    private var published: WidgetDestinationSnapshot?
    init(store: WidgetDestinationStore, reload: @escaping (CallSurfaceKind) -> Void = { kind in
        switch kind {
        case .selectedWidget:
            WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue)
        case .destinationControl:
            #if os(iOS)
            ControlCenter.shared.reloadControls(ofKind: kind.rawValue)
            #else
            break
            #endif
        }
    }) { self.store = store; self.reload = reload }

    func publish(_ snapshot: WidgetDestinationSnapshot) {
        guard store.fileURL != nil else { return }
        guard published != snapshot || store.readSnapshot() != snapshot else { return }
        do {
            try store.write(snapshot)
            published = snapshot
        } catch {
            // Don't retain an older account's selectable list after write failure.
            if let file = store.fileURL { try? FileManager.default.removeItem(at: file) }
            published = nil
        }
        reload(.selectedWidget)
        #if os(iOS)
        reload(.destinationControl)
        #endif
    }
}

extension AppCallOwner {
    func observeWidgetDestinations() {
        let snapshot = withObservationTracking {
            _ = systemSurfaceIsForeground // Retry a failed publication on foreground return.
            let targets = callTargets
            let destinations = targets.map { target in
                WidgetCallDestination(id: target.entity.id, name: target.entity.name,
                    kind: { if case .user = target.destination { return .user }; return .group }())
            }
            let currentDestinationID: String? = {
                guard let model = viewModel, let group = model.groups.first(where: { $0.id == model.activeGroupID }),
                      let destination = model.callDestination(of: group) else { return nil }
                return targets.first { $0.destination == destination }?.entity.id
            }()
            let recentDestinationID = viewModel?.recentCallDestination.flatMap { recent in
                targets.first { $0.destination == recent }?.entity.id
            }
            return WidgetDestinationSnapshot(destinations: destinations,
                currentDestinationID: currentDestinationID,
                currentCall: currentLivePresentation,
                recentDestinationID: recentDestinationID)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeWidgetDestinations() }
        }
        widgetDestinations.publish(snapshot)
    }
}
