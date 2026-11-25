import Foundation

extension CallNotifications {
    /// Keep PUT and DELETE in order, including work added while cancellation drains.
    private func enqueueDeviceOperation(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = deviceOperations.last?.task, id = UUID()
        let task = Task {
            defer { deviceOperations.removeAll { $0.id == id } }
            await previous?.value
            guard !Task.isCancelled else { return }
            await body()
        }
        deviceOperations.append((id, task))
        return task
    }

    func cancelDeviceOperations() {
        guard !deviceOperations.isEmpty else { return }
        for operation in deviceOperations { operation.task.cancel() }
        // The Worker may already have applied the write. Confirm the current desire on recovery.
        if receivesNotifications { message = nil }
        receivesNotifications = false
    }

    func removePendingDevice(_ context: CallNotificationServiceAccess, generation expected: Int) async {
        guard permitsDeviceRegistration() else { return }
        let operation = enqueueDeviceOperation { [self] in
            guard permitsDeviceRegistration(), current(context, generation: expected), !isEnabled,
                  store.notificationRemovalPending else { return }
            do {
                try await client.removeNotificationDevice(origin: context.origin, token: context.accessToken)
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
        guard permitsDeviceRegistration(), isEnabled, let context = serviceAccess() else { return }
        tokenGeneration += 1
        let expectedToken = tokenGeneration, expected = generation
        let operation = enqueueDeviceOperation { [self] in
            guard permitsDeviceRegistration(), current(context, generation: expected), isEnabled,
                  expectedToken == tokenGeneration else { return }
            do {
                try await client.registerNotificationDevice(
                    origin: context.origin, token: context.accessToken, deviceToken: token,
                    environment: environment, topic: topic)
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
        let previous =
            isEnabled || store.notificationRemovalPending ? try? store.notificationAccess(memberID: memberID) : nil
        generation += 1; tokenGeneration += 1; isBusy = false; receivesNotifications = false
        guard let previous else { return nil }
        store.notificationRemovalPending = true
        guard permitsDeviceRegistration() else { return nil }
        // This account has retired. The already authorised cleanup outlives its view model.
        return enqueueDeviceOperation { [client] in
            try? await client.removeNotificationDevice(origin: previous.origin, token: previous.accessToken)
        }
    }

    func registerIfAllowed() { if permitsDeviceRegistration() { register() } }

    func retryDeviceRegistration() async {
        guard permitsDeviceRegistration(), let context = serviceAccess() else { return }
        let expected = generation
        let expectedDevice = deviceDisableGeneration
        let granted = await authorizationGranted()
        guard current(context, generation: expected), permitsDeviceRegistration(),
              deviceDisableGeneration == expectedDevice else { return }
        if granted {
            guard !receivesNotifications else { return }
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
        guard permitsDeviceRegistration(), let context = serviceAccess() else {
            message = "Notifications are disabled here. Server removal is pending; retry when online."
            return
        }
        await removePendingDevice(context, generation: generation)
    }
}
