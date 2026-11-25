#if os(iOS)
import BackgroundTasks
import UIKit

struct BackgroundRefreshSubmission {
    enum Action { case none, submit, cancel }

    private enum State { case idle, submitting, cancelledWhileSubmitting }
    private var state = State.idle

    mutating func reconcile(needed: Bool) -> Action {
        guard needed else {
            if state == .submitting { state = .cancelledWhileSubmitting }
            return .cancel
        }
        guard state == .idle else { return .none }
        state = .submitting
        return .submit
    }

    mutating func finish(needed: Bool) -> Action {
        let wasCancelled = state == .cancelledWhileSubmitting
        state = .idle
        guard needed else { return .cancel }
        // A foreground cancellation can win before the async submission reports back.
        return wasCancelled ? reconcile(needed: true) : .none
    }
}

@MainActor
final class SavedCommunicationBackgroundRefresh {
    static let identifier = "com.yowamushi-inc.RideIntercom.saved-communication-refresh"

    weak var owner: AppCallOwner?
    private var isRegistered = false
    private var isInBackground = false
    private var submission = BackgroundRefreshSubmission()
    private var running: Task<Void, Never>?

    func register() {
        guard !isRegistered else { return }
        let launch: (BGTask) -> Void = { [weak self] task in
            MainActor.assumeIsolated {
                if let self { self.run(task) } else { task.setTaskCompleted(success: false) }
            }
        }
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main,
                                                        launchHandler: launch)
    }

    func setInBackground(_ value: Bool) {
        guard isInBackground != value else { return }
        isInBackground = value
        reconcileSchedule()
    }

    func accountDidChange() {
        running?.cancel()
        reconcileSchedule()
    }

    private var shouldSchedule: Bool {
        isInBackground && SystemSurfaceScope.permitsSystemAccess
            && owner?.needsSavedCommunicationBackgroundRefresh == true
    }

    func reconcileSchedule() {
        guard isRegistered else { return }
        apply(submission.reconcile(needed: shouldSchedule))
    }

    private func apply(_ action: BackgroundRefreshSubmission.Action) {
        switch action {
        case .none:
            break
        case .cancel:
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        case .submit:
            let identifier = Self.identifier
            Task.detached(priority: .utility) { [weak self] in
                let request = BGAppRefreshTaskRequest(identifier: identifier)
                request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
                try? await BGTaskScheduler.shared.submitTaskRequest(request)
                await self?.submissionFinished()
            }
        }
    }

    private func submissionFinished() {
        apply(submission.finish(needed: shouldSchedule))
    }

    private func run(_ task: BGTask) {
        guard running == nil, task is BGAppRefreshTask, SystemSurfaceScope.permitsSystemAccess, let owner else {
            task.setTaskCompleted(success: false)
            return
        }
        isInBackground = UIApplication.shared.applicationState != .active
        reconcileSchedule()
        let work = Task { @MainActor [weak self] in
            let success = await owner.refreshSavedCommunicationInBackground()
            task.expirationHandler = nil
            self?.running = nil
            task.setTaskCompleted(success: success && !Task.isCancelled)
            if !owner.needsSavedCommunicationBackgroundRefresh { self?.reconcileSchedule() }
        }
        running = work
        task.expirationHandler = { work.cancel() }
    }
}
#endif
