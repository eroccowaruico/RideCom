import AVFAudio
import AudioCore
import AudioMixer
import Codec
import Foundation
import PeakLimiter
import RTC
import SessionManager
import SoundIsolation
import Testing
import VADGate

@testable import RideIntercom

extension AppTests.SettingsTests {
    @Test func savedOpusManualBitrateRestoresWithoutChangingAACOrFormat() throws {
        let suiteName = "RideIntercomTests.legacy-opus.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(32_000, forKey: "RideIntercom.settings.opusBitRate")
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        let harness = AppTestSupport.makeHarness(appSettingsStore: store)
        #expect(harness.viewModel.opusBitRate == 32_000)
        #expect(harness.viewModel.aacELDv2BitRate == 48_000)
        for format in RTCAudioFormatPreset.allCases {
            harness.viewModel.setRTCAudioFormatPreset(format)
            harness.viewModel.setOpusBitRate(16_000)
            #expect(harness.viewModel.opusBitRate == 48_000)
            #expect(store.load().opusBitRate == 48_000)
            #expect(store.load().rtcAudioFormatPreset == format)
        }
    }
    @Test func userDefaultsSettingsStoreMigratesLegacyRTCTransportRouteSettingsToDefault() throws {
        let suiteName = "RideIntercomTests.legacy-routes.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            [RTC.RouteKind.webRTC.rawValue],
            forKey: "RideIntercom.settings.enabledRTCTransportRoutes"
        )
        let settingsStore = UserDefaultsAppSettingsStore(defaults: defaults)

        #expect(
            settingsStore.load().enabledRTCTransportRoutes
                == IntercomViewModel.defaultEnabledRTCTransportRoutes)

        settingsStore.save(AppSettings(enabledRTCTransportRoutes: [.webRTC]))

        #expect(settingsStore.load().enabledRTCTransportRoutes == [.webRTC])
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func viewModelLoadsPersistsAndAppliesRTCTransportRouteOptOut() {
        let defaultHarness = AppTestSupport.makeHarness()
        #expect(defaultHarness.viewModel.enabledRTCTransportRoutes == Set(RTC.RouteKind.allCases))
        #expect(defaultHarness.callSession.enabledRouteValues.last == Set(RTC.RouteKind.allCases))

        let settingsStore = InMemoryAppSettingsStore(
            settings: AppSettings(
                enabledRTCTransportRoutes: [.webRTC]
            ))
        let harness = AppTestSupport.makeHarness(appSettingsStore: settingsStore)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.webRTC])
        #expect(harness.callSession.enabledRouteValues.last == [.webRTC])
        #expect(!harness.viewModel.isRTCTransportRouteEnabled(.multipeer))
        #expect(harness.viewModel.canToggleRTCTransportRoute(.multipeer))
        #expect(!harness.viewModel.canToggleRTCTransportRoute(.webRTC))

        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.webRTC])
        #expect(settingsStore.load().enabledRTCTransportRoutes == [.webRTC])
        #expect(harness.callSession.enabledRouteValues.last == [.webRTC])

        harness.viewModel.setRTCTransportRoute(.multipeer, enabled: true)

        #expect(harness.viewModel.enabledRTCTransportRoutes == Set(RTC.RouteKind.allCases))
        #expect(settingsStore.load().enabledRTCTransportRoutes == Set(RTC.RouteKind.allCases))
        #expect(harness.callSession.enabledRouteValues.last == Set(RTC.RouteKind.allCases))

        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.multipeer])
        #expect(settingsStore.load().enabledRTCTransportRoutes == [.multipeer])
        #expect(harness.callSession.enabledRouteValues.last == [.multipeer])

        harness.viewModel.setRTCTransportRoute(.multipeer, enabled: false)

        #expect(harness.viewModel.enabledRTCTransportRoutes == [.multipeer])
        #expect(settingsStore.load().enabledRTCTransportRoutes == [.multipeer])
        #expect(harness.callSession.enabledRouteValues.last == [.multipeer])
    }

    @Test func viewModelRepairsEmptyRTCTransportRoutesBeforeConnecting() {
        let settingsStore = InMemoryAppSettingsStore(
            settings: AppSettings(
                enabledRTCTransportRoutes: []
            ))
        let harness = AppTestSupport.makeHarness(appSettingsStore: settingsStore)

        #expect(
            harness.viewModel.enabledRTCTransportRoutes
                == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(
            harness.callSession.enabledRouteValues.last
                == IntercomViewModel.defaultEnabledRTCTransportRoutes)

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])

        #expect(
            harness.viewModel.enabledRTCTransportRoutes
                == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(
            settingsStore.load().enabledRTCTransportRoutes
                == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(
            harness.callSession.enabledRouteValues.last
                == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(harness.callSession.connectedGroup?.id == IntercomSeedData.recentGroups[0].id)
    }

    @Test func changingRTCTransportRoutesStopsActiveConnectionBeforeApplyingPolicy() {
        let harness = AppTestSupport.makeHarness()

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)

        #expect(harness.callSession.disconnectCallCount == 1)
        #expect(harness.viewModel.connectionState == .idle)
        #expect(harness.callSession.connectedGroup == nil)
        #expect(harness.callSession.enabledRouteValues.last == [.multipeer])
    }

    @Test(arguments: [RTC.RouteKind.multipeer, .webRTC])
    func actualEffectsFollowSettingsWithoutRestartingMedia(route: RTC.RouteKind) async throws {
        let harness = AppTestSupport.makeHarness(hasInternetCallCredential: route == .webRTC)
        let model = harness.viewModel
        model.setRTCTransportRoute(route == .webRTC ? .multipeer : .webRTC, enabled: false)
        #expect(model.supportsSoundIsolation == VoiceIsolationSupport.isAvailable)
        model.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { model.isAudioReady }
        #expect(model.isAudioReady)
        let enginesBefore = harness.audioDriver.createdEngineCount
        let transmitBus = try #require(model.audioPipeline.snapshot.buses.first { $0.id == "tx-bus" })
        #expect(
            transmitBus.effectChain.map(\.id) == [
                "sound-isolation", "dynamics-processor", "peak-limiter"
            ])
        #expect(transmitBus.effectChain.allSatisfy { $0.typeName == "AVAudioUnitEffect" })
        model.setSoundIsolationEnabled(false)
        model.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: true)
        model.setReceiveMixSoundIsolationEnabled(true)
        #expect(harness.audioDriver.createdEngineCount == enginesBefore)
        func state(_ bus: String) -> MixerEffectState? {
            model.audioPipeline.snapshot.buses.first { $0.id == bus }?.effectChain.first {
                $0.id == "sound-isolation"
            }?.state
        }
        #expect(state("tx-bus") == .bypassed)
        #expect(state("rx-peer-member-108") == .active)
        #expect(state("rx-master") == .active)
        let report = try #require(
            model.lastRuntimePackageReports.first {
                $0.package == "SoundIsolation" && $0.kind == "transmitRuntimeSnapshot"
            })
        #expect(try report.decodeJSON(VoiceIsolationRuntimeSnapshot.self).state == .bypassed)
        model.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: false)
        #expect(state("rx-peer-member-108") == .bypassed)
        model.disconnect()
        #expect(model.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(
            !model.lastRuntimePackageReports.contains {
                $0.package == "PeakLimiter" && $0.kind.contains("RuntimeSnapshot")
            })
    }

    @Test func internetConfigurationUsesKeychainAndRejectsUnsecuredEndpoint() throws {
        let keychain = InternetTestKeychain()
        let store = InternetConnectionSettingsStore(keychain: keychain)
        #expect(try store.load() == nil)
        #expect(throws: (any Error).self) {
            try store.save(url: "http://example.com", token: "device-token")
        }
        try store.save(url: "https://ride.example.com", token: "device-token")
        #expect(try store.load()?.workerURL.absoluteString == "https://ride.example.com")
        #expect(try store.load()?.accessToken == "device-token")
        #expect(!(try #require(keychain.value)).contains("invitation-secret"))
    }

    @Test func developmentInternetDefaultsNeedNoManualSaveAndDoNotPersist() throws {
        let keychain = InternetTestKeychain()
        let store = InternetConnectionSettingsStore.makeForCurrentProcess(
            keychain: keychain, namespace: "fixture",
            info: [
                "DevelopmentInternetConnection": [
                    "workerURL": "https://preview.example.com", "accessToken": "synthetic-token"
                ]
            ],
            environment: [:])
        #expect(try store.load()?.workerURL.absoluteString == "https://preview.example.com")
        #expect(try store.load()?.accessToken == "synthetic-token")
        #expect(keychain.value == nil)
        let harness = AppTestSupport.makeHarness(internetSettingsStore: store)
        #expect(harness.viewModel.hasInternetCredentials)
        #expect(harness.viewModel.internetWorkerURL == "https://preview.example.com")
    }

    @Test func developmentInternetDefaultsPreserveSavedCredentialsForTheirOrigin() throws {
        let keychain = InternetTestKeychain()
        let store = InternetConnectionSettingsStore.makeForCurrentProcess(
            keychain: keychain, namespace: "fixture",
            info: [
                "DevelopmentInternetConnection": [
                    "workerURL": "https://preview.example.com", "accessToken": "synthetic-token"
                ]
            ],
            environment: [:])
        try store.save(url: "https://preview.example.com", token: "replacement-token")
        #expect(try store.load()?.accessToken == "replacement-token")
        #expect(throws: (any Error).self) {
            try store.save(url: "https://manual.example.com", token: "manual-token")
        }
        #expect(try store.load()?.accessToken == "replacement-token")
        keychain.value = "unreadable-saved-credentials"
        #expect(throws: (any Error).self) { try store.load() }
        #expect(keychain.value == "unreadable-saved-credentials")
    }

    @Test func developmentBuildSelectsFixedPreviewBeforeEnrollment() throws {
        let keychain = InternetTestKeychain()
        let store = InternetConnectionSettingsStore.makeForCurrentProcess(
            keychain: keychain, namespace: "fixture", info: [:], environment: [:])
        let preview = "https://preview-ridecom.analog.workers.dev"
        #expect(store.fixedWorkerOrigin?.absoluteString == preview)
        #expect(try store.load() == nil)
        #expect(try store.workerOrigin(preview).absoluteString == preview)
        #expect(throws: (any Error).self) {
            try store.workerOrigin("https://workers.ridecom.yowamushi-inc.com")
        }
        #expect(keychain.value == nil)

        let legacy = "https://preview.workers.ridecom.yowamushi-inc.com"
        let previous = InternetConnectionSettingsStore(keychain: keychain, namespace: "fixture")
        try previous.save(url: legacy, token: "previous-origin-token")
        let saved = try #require(keychain.value)
        #expect(try store.load() == nil)
        #expect(throws: (any Error).self) { try store.workerOrigin(legacy) }
        #expect(keychain.value == saved)
    }

    @Test func localTestProcessesCannotLoadOrReplaceLiveInternetCredentials() throws {
        for environment in [
            ["RIDEINTERCOM_LOCAL_TESTING": "1"],
            ["XCTestConfigurationFilePath": "fixture.xctestconfiguration"],
            ["XCTestBundlePath": "fixture.xctest"]
        ] {
            let keychain = InternetTestKeychain()
            try InternetConnectionSettingsStore(keychain: keychain).save(
                url: "https://saved.example.com", token: "saved-token")
            let before = keychain.value
            let store = InternetConnectionSettingsStore.makeForCurrentProcess(
                keychain: keychain, namespace: "fixture",
                info: [
                    "DevelopmentInternetConnection": [
                        "workerURL": "https://preview.example.com", "accessToken": "synthetic-token"
                    ]
                ],
                environment: environment)
            #expect(try store.load() == nil)
            #expect(throws: (any Error).self) {
                try store.save(url: "https://other.example.com", token: "other-token")
            }
            #expect(keychain.value == before)
        }
    }
    @Test func internetSettingsValidationPreservesCallAndSavedCheckUsesNoMedia() async throws {
        let keychain = InternetTestKeychain()
        let store = InternetConnectionSettingsStore(keychain: keychain)
        let harness = AppTestSupport.makeHarness(internetSettingsStore: store)
        await harness.viewModel.checkInternetService()
        #expect(harness.viewModel.internetCheckMessage.contains("Configure"))
        let stops = harness.callSession.disconnectCallCount
        #expect(throws: (any Error).self) {
            try harness.viewModel.saveInternetConnection(url: "http://example.com", token: "wrong")
        }
        #expect(harness.callSession.disconnectCallCount == stops)
        #expect(!harness.viewModel.hasInternetCredentials)
        try harness.viewModel.saveInternetConnection(url: "https://worker.test", token: "private-token")
        #expect(harness.callSession.disconnectCallCount == stops + 1)
        #expect(harness.viewModel.hasInternetCredentials)
        #expect(harness.viewModel.internetWorkerURL == "https://worker.test")
        #expect(!harness.viewModel.internetCheckMessage.contains("private-token"))
        #expect(harness.callSession.startMediaCallCount == 0)
    }

    @Test func callWithoutInternetCredentialsShowsSetupAndKeepsNearbyAvailable() throws {
        let store = InternetConnectionSettingsStore(keychain: InternetTestKeychain())
        let harness = AppTestSupport.makeHarness(internetSettingsStore: store)
        let model = harness.viewModel
        let group = try #require(model.groups.first)
        let setup = String(localized: "Could not prepare Internet calling for this device.")

        model.setRTCTransportRoutes([.webRTC])
        model.openDestination(.group(group.id))
        #expect(model.selectedGroup?.id == group.id)
        #expect(model.groupErrorMessage == setup)
        #expect(model.activeGroupID == nil)
        #expect(harness.callSession.connectedGroup == nil)

        model.setRTCTransportRoutes([.multipeer, .webRTC])
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        model.openDestination(.group(group.id))
        #expect(model.activeGroupID == group.id)
        #expect(harness.callSession.connectedGroup?.id == group.id)
        #expect(model.groupErrorMessage == nil)
        #expect(model.connectivityNotice == nil)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        #expect(model.connectivityNotice == setup)
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        #expect(model.connectivityNotice == nil)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        #expect(model.connectivityNotice == setup)
        model.disconnect()
        #expect(model.connectivityNotice == nil)

        model.setRTCTransportRoutes([.multipeer])
        model.openDestination(.group(group.id))
        #expect(model.activeGroupID == group.id)
        #expect(model.connectivityNotice == nil)
        model.disconnect()

        try store.save(url: "https://worker.test", token: "fixture-device-token")
        let registeredHarness = AppTestSupport.makeHarness(internetSettingsStore: store)
        let registeredModel = registeredHarness.viewModel
        let registeredGroup = try #require(registeredModel.groups.first)
        registeredModel.setRTCTransportRoutes([.webRTC])
        registeredModel.openDestination(.group(registeredGroup.id))
        #expect(registeredModel.activeGroupID == registeredGroup.id)
        #expect(registeredHarness.callSession.connectedGroup?.id == registeredGroup.id)
        #expect(registeredModel.connectivityNotice == nil)
        registeredModel.disconnect()
    }

    @Test func unreadableInternetSettingsKeepSavedDataAndReportReadFailure() throws {
        let keychain = InternetTestKeychain()
        keychain.value = "unreadable-saved-credentials"
        let store = InternetConnectionSettingsStore(keychain: keychain)
        let harness = AppTestSupport.makeHarness(internetSettingsStore: store)
        let model = harness.viewModel
        let group = try #require(model.groups.first)

        model.setRTCTransportRoutes([.webRTC])
        model.openDestination(.group(group.id))

        #expect(model.groupErrorMessage == String(localized:
            "Could not read saved Internet calling settings. Reopen RideCom and try again."))
        #expect(harness.callSession.connectedGroup == nil)
        #expect(keychain.value == "unreadable-saved-credentials")
    }

}
