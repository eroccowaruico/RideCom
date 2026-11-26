import Foundation

extension CallNotifications {
    struct DeviceOperation {
        let id: UUID
        let removesDevice: Bool
        let task: Task<Void, Never>
    }

    /// Keep PUT and DELETE in order, including work added while cancellation drains.
    private func enqueueDeviceOperation(
        removesDevice: Bool, _ body: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = deviceOperations.last?.task, id = UUID()
        let task = Task {
            defer { deviceOperations.removeAll { $0.id == id } }
            await previous?.value
            guard !Task.isCancelled else { return }
            await body()
        }
        deviceOperations.append(.init(id: id, removesDevice: removesDevice, task: task))
        return task
    }

    func cancelDeviceOperations(keepingRemovals: Bool) {
        let cancelled = deviceOperations.filter { !keepingRemovals || !$0.removesDevice }
        guard !cancelled.isEmpty else { return }
        for operation in cancelled { operation.task.cancel() }
        // The Worker may already have applied the write. Confirm the current desire on recovery.
        if receivesNotifications { message = nil }
        receivesNotifications = false
    }

    func removePendingDevice(_ context: CallNotificationServiceAccess, generation expected: Int) async {
        guard canAttemptNotificationCleanup else { return }
        let revision = Result { try store.reserveNotificationDeviceRevision() }
        let operation = enqueueDeviceOperation(removesDevice: true) { [self] in
            if !permitsNotificationInternet(), await authorizationGranted() { return }
            guard canAttemptNotificationCleanup, current(context, generation: expected), !isEnabled,
                  store.notificationRemovalPending else { return }
            do {
                try await client.removeNotificationDevice(access: context, revision: revision.get())
                guard current(context, generation: expected), !isEnabled else { return }
                store.notificationRemovalPending = false; message = nil
            } catch {
                guard current(context, generation: expected), !isEnabled else { return }
                message = "Notifications are disabled here. Server removal is pending; retry when online."
            }
        }
        await operation.value
    }

    func receivedDeviceToken(_ token: Data, environment: String, topic: String) async {
        guard permitsNotificationInternet(), isEnabled, let context = serviceAccess() else { return }
        tokenGeneration += 1
        let expectedToken = tokenGeneration, expected = generation
        let revision = Result { try store.reserveNotificationDeviceRevision() }
        let operation = enqueueDeviceOperation(removesDevice: false) { [self] in
            guard permitsNotificationInternet(), current(context, generation: expected), isEnabled,
                  expectedToken == tokenGeneration else { return }
            do {
                try await client.registerNotificationDevice(
                    access: context, deviceToken: token, environment: environment, topic: topic,
                    revision: revision.get())
                guard current(context, generation: expected), expectedToken == tokenGeneration, isEnabled
                else { return }
                store.notificationRemovalPending = false
                receivesNotifications = true; message = "Notifications are enabled on this device."
            } catch {
                guard current(context, generation: expected), expectedToken == tokenGeneration else { return }
                receivesNotifications = false
                message = "Notifications could not be registered. Please try again."
            }
        }
        await operation.value
    }
    func registrationFailed() {
        if isCurrentUser(), isEnabled {
            receivesNotifications = false; message = "Notifications could not be registered. Please try again."
        }
    }
    @discardableResult
    func stop() -> Task<Void, Never>? {
        cancelSavedGrantRevocations()
        let previous =
            isEnabled || store.notificationRemovalPending ? try? store.notificationAccess(memberID: memberID) : nil
        generation += 1; tokenGeneration += 1; isBusy = false; receivesNotifications = false
        guard let previous else { return nil }
        store.notificationRemovalPending = true
        guard permitsNotificationInternet(), let revision = try? store.reserveNotificationDeviceRevision()
        else { return nil }
        // This account has retired. The already authorised cleanup outlives its view model.
        return enqueueDeviceOperation(removesDevice: true) { [client] in
            try? await client.removeNotificationDevice(access: previous, revision: revision)
        }
    }

    func registerIfAllowed() { if permitsNotificationInternet() { register() } }

    func retryDeviceRegistration(allowRegistration: Bool) async {
        guard canAttemptNotificationCleanup, let context = serviceAccess() else { return }
        let expected = generation
        let expectedDevice = deviceDisableGeneration
        let granted = await authorizationGranted()
        guard current(context, generation: expected), canAttemptNotificationCleanup,
              deviceDisableGeneration == expectedDevice else { return }
        if granted {
            guard allowRegistration, permitsNotificationInternet(), !receivesNotifications else { return }
            if isEnabled { register() } else { await enable() }
        } else if isEnabled {
            authorizationDenied = true
            await disable()
            reportAuthorizationDenied(context, generation: expected)
        } else if removalPending {
            await removePendingDevice(context, generation: expected)
        }
    }
    func disable() async {
        guard isCurrentUser() else { return }
        deviceDisableGeneration += 1
        store.notificationRegistrationEnabled = false
        store.notificationRemovalPending = true
        receivesNotifications = false; tokenGeneration += 1; unregister()
        guard canAttemptNotificationCleanup, let context = serviceAccess() else {
            message = "Notifications are disabled here. Server removal is pending; retry when online."
            return
        }
        await removePendingDevice(context, generation: generation)
    }
}
