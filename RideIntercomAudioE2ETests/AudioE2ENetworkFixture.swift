import AuthenticationServices
import AVFAudio
import CryptoKit
import Foundation
import RTC
import SessionManager
import XCTest
@testable import RideIntercom

struct AudioE2EWorkerConnection {
    let url: URL?
    let fixture: AudioE2EWorker?
    let room: String
}

extension AudioE2ETests {
    @MainActor
    func startWorker(for options: AudioE2ENetworkRun) async throws -> AudioE2EWorkerConnection {
        let room = RTCCredential.derived(groupID: options.groupID.uuidString, secret: options.groupSecret).groupHash
        guard options.usesInternet || options.waitsForLateParticipant else {
            return AudioE2EWorkerConnection(url: nil, fixture: nil, room: room)
        }
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(options.workerURL)))
        guard options.role == "a" else { return AudioE2EWorkerConnection(url: url, fixture: nil, room: room) }
        let fixture = try AudioE2EWorker(
            port: UInt16(try XCTUnwrap(url.port)), run: options.identifier, room: room,
            checksInternetRecovery: options.checksInternetRecovery,
            holdsInternetSignaling: options.startsBeforeInternet, leavesICEUnanswered: options.waitsForInternet
        )
        try await fixture.start()
        addTeardownBlock { await fixture.stop() }
        return AudioE2EWorkerConnection(url: url, fixture: fixture, room: room)
    }
}

@MainActor
struct AudioE2ERouteFixture {
    #if DEBUG
    let instrumentedRoutes: MixedRouteAudioE2E?
    #endif

    init(run: AudioE2ENetworkRun) throws {
        #if DEBUG
        instrumentedRoutes = run.mixed || run.checksLocalRecovery ? MixedRouteAudioE2E() : nil
        #else
        if run.mixed || run.checksLocalRecovery {
            throw NSError(domain: "Local route fault injection requires Debug-Validation", code: 1)
        }
        #endif
    }

    func makeSession(run: AudioE2ENetworkRun, worker: AudioE2EWorkerConnection) -> RideIntercomCallSessionAdapter? {
        let internet = run.usesInternet ? worker.url.map {
            CloudflareRealtimeConfiguration(workerURL: $0, accessToken: run.identifier)
        } : nil
        let memberID = run.memberID
        let callSession: RideIntercomCallSessionAdapter?
        if run.waitsForInternet {
            callSession = RideIntercomCallSessionAdapter(memberID: memberID, internetConfiguration: internet)
        } else if run.usesInternet || run.checksLocalRecovery {
            callSession = RideIntercomCallSessionAdapter(memberID: memberID, internetConfiguration: internet,
                sessionFactory: { policy, routes, configuration in
                    #if DEBUG
                    if let instrumentedRoutes {
                        return instrumentedRoutes.makeSession(routes: routes, internet: configuration)
                    }
                    #endif
                    return RTC.CallSessionFactory.makeSession(.init(
                        routeConfiguration: .init(enabledRoutes: routes, preferredRoute: .webRTC), audioPolicy: policy,
                        webRTC: .init(cloudflareConfigurationProvider: { _ in configuration },
                                      engineFactory: { makeAudioE2EWebRTCEngine() })))
                })
        } else { callSession = nil }
        return callSession
    }
}

@MainActor
struct AudioE2ENativeAudio {
    let localFixture: String
    let remoteFixture: String
    let outputEngine: AVAudioEngine
    let input: SpeechFileInput
    let remote: SpeechFileInput
    let probe: RenderedAudioProbe
    let mixedProbe: RenderedAudioProbe
    let decodedProbe: RenderedAudioProbe
    let output: SystemAudioOutputStreamBackend

    init(run: AudioE2ENetworkRun) throws {
        let role = run.role
        let suffix = run.speechPair == "japanese" ? "-ja" : ""
        let fixtures = run.speechPair == "conversation"
            ? ["conversation-ja", "conversation-reply-ja"] : ["speech" + suffix, "reply" + suffix]
        localFixture = fixtures[role == "a" ? 0 : 1]
        remoteFixture = fixtures[role == "a" ? 1 : 0]
        outputEngine = AVAudioEngine()
        input = try SpeechFileInput(name: localFixture, engine: outputEngine)
        if run.mixed { input.setFrameDeliveryEnabled(false) }
        remote = try SpeechFileInput(name: remoteFixture)
        probe = RenderedAudioProbe(recordsRenderClock: run.waitsForInternet)
        mixedProbe = RenderedAudioProbe()
        decodedProbe = RenderedAudioProbe()
        output = SystemAudioOutputStreamBackend(engine: outputEngine)
        let nativeOutput = outputEngine.mainMixerNode
        try nativeOutput.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { [probe] buffer, time in
            probe.append(buffer, time: time)
        }
    }

    func removeOutputProbe() { outputEngine.mainMixerNode.removeTap(onBus: 0) }
}

@MainActor
struct AudioE2ECallStorage {
    private let namespace: String
    private let defaults: UserDefaults
    private let keychain: FixtureKeychain
    private let credentials: KeychainGroupCredentialStore
    let directory: URL

    init(run: AudioE2ENetworkRun) throws {
        namespace = "RideIntercom.AudioE2E.\(run.identifier).\(run.role)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        keychain = FixtureKeychain()
        credentials = KeychainGroupCredentialStore(keychain: keychain, namespace: namespace)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: namespace)
        for ref in (try? credentials.references()) ?? [] { try? credentials.delete(reference: ref) }
        try? FileManager.default.removeItem(at: directory)
    }

    func makeViewModel(
        run: AudioE2ENetworkRun, routes: AudioE2ERouteFixture,
        worker: AudioE2EWorkerConnection, audio: AudioE2ENativeAudio
    ) async throws -> IntercomViewModel {
        let settings = try makeSettings(for: run)
        let callSession = routes.makeSession(run: run, worker: worker)
        let (startingAccount, identity) = try await makeAccount(for: run)
        let startsFromSavedGroup = run.startsFromSavedGroup
        let access: (@MainActor @Sendable (Date) -> StoreAccessEvaluation)?
        if startsFromSavedGroup {
            access = { _ in StoreAccessEvaluation(status: .active) }
        } else {
            access = nil
        }
        let internetSettings = InternetConnectionSettingsStore(keychain: keychain, namespace: namespace)
        if run.usesInternet {
            var origin = try XCTUnwrap(worker.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            XCTAssertEqual(origin.host, "127.0.0.1")
            // Saved settings require HTTPS. The injected RTC adapter uses the local HTTP fixture.
            origin.scheme = "https"
            try internetSettings.save(url: XCTUnwrap(origin.url).absoluteString, token: run.identifier)
        }
        return IntercomViewModel(
            accountSession: startingAccount,
            enforceCallAccess: startsFromSavedGroup ? true : nil,
            callAccessEvaluation: access,
            callSession: callSession,
            groupRepository: GroupRepository(store: FileGroupStore(directory: directory), credentials: credentials),
            appSettingsStore: settings,
            internetSettingsStore: internetSettings,
            localMemberIdentityStore: identity,
            invitationAuthority: DirectInvitationAuthority(keychain: keychain, namespace: namespace),
            requestMicrophoneAccess: {
                #if os(iOS)
                await AVAudioApplication.requestRecordPermission()
                #else
                // The Mac endpoint supplies file samples without opening a microphone.
                true
                #endif
            },
            audioInputCapture: AudioInputStreamCapture(
                configuration: .intercom(voiceProcessing: IntercomViewModel.defaultVoiceProcessingConfiguration()),
                backend: audio.input
            ),
            audioOutputRenderer: AudioOutputStreamRenderer(configuration: .intercom, backend: audio.output)
        )
    }

    private func makeSettings(for run: AudioE2ENetworkRun) throws -> UserDefaultsAppSettingsStore {
        let initial = run.initial
        let settings = UserDefaultsAppSettingsStore(defaults: defaults)
        var configuration = AppSettings(enabledRTCTransportRoutes: run.enabledRoutes)
        configuration.preferredTransmitCodec = AudioCodecIdentifier(rawValue: initial.codec)
        configuration.rtcAudioFormatPreset = try XCTUnwrap(RTCAudioFormatPreset(rawValue: initial.format))
        configuration.audioSessionProfile = try XCTUnwrap(AudioSessionProfile(rawValue: initial.profile))
        settings.save(configuration)
        return settings
    }

    private func makeAccount(
        for options: AudioE2ENetworkRun
    ) async throws -> (AppleAccountSession, UserDefaultsLocalMemberIdentityStore) {
        let role = options.role
        let run = options.identifier
        let groupID = options.groupID
        let groupSecret = options.groupSecret
        let memberID = options.memberID
        let startsFromSavedGroup = options.startsFromSavedGroup
        let accountKeychain = FixtureKeychain()
        let account = AppleAccountSession(
            keychain: accountKeychain, defaults: defaults, namespace: namespace, credentialState: { _ in .authorized }
        )
        let request = ASAuthorizationAppleIDProvider().createRequest()
        account.prepare(request)
        XCTAssertTrue(account.completeSignIn(userID: "audio-e2e-" + role, state: request.state))
        let identity = UserDefaultsLocalMemberIdentityStore(defaults: defaults,
            makeID: { memberID }, defaultDisplayName: { "Audio E2E \(role)" })
        var startingAccount = account
        if startsFromSavedGroup {
            let otherRole = role == "a" ? "b" : "a"
            let savedGroups = GroupRepository(store: FileGroupStore(directory: directory), credentials: credentials)
            _ = try savedGroups.load(localMemberID: identity.loadOrCreate().memberID)
            let group = try IntercomGroup(id: groupID, name: "Audio E2E", members: [
                GroupMember(id: memberID, displayName: "Audio E2E \(role)"),
                GroupMember(id: "e2e-\(otherRole)-\(run.prefix(8))", displayName: "Audio E2E \(otherRole)")
            ])
            try savedGroups.save([group], credential: .init(groupID: groupID, secret: groupSecret))
            startingAccount = AppleAccountSession(keychain: accountKeychain, defaults: defaults,
                namespace: namespace, credentialState: { _ in throw URLError(.notConnectedToInternet) })
            await startingAccount.refresh()
            XCTAssertEqual(startingAccount.userID, "audio-e2e-" + role)
            XCTAssertNotNil(startingAccount.message, "The saved sign-in must survive a failed Apple credential check")
        }
        return (startingAccount, identity)
    }

    func makeInvitation(for run: AudioE2ENetworkRun) throws -> URL {
        let token = try GroupInviteToken.make(
            authority: DirectInvitationAuthority(keychain: keychain, namespace: namespace + ".Inviter"),
            signer: DeviceIdentitySigner(memberID: "fixture-owner", key: P256.Signing.PrivateKey()),
            credential: .init(groupID: run.groupID, secret: run.groupSecret), groupName: "Audio E2E",
            inviterMemberID: "fixture-owner")
        return try GroupInviteTokenCodec.joinURL(for: token)
    }
}

@MainActor
struct AudioE2EEndpoint {
    let run: AudioE2ENetworkRun
    let audio: AudioE2ENativeAudio
    let worker: AudioE2EWorkerConnection
    let directory: URL
    let viewModel: IntercomViewModel

    func waitForFirstParticipantIfNeeded() async throws {
        if run.waitsForLateParticipant, run.role == "b" {
            try await AudioE2EWorker.waitForFirstParticipant(
                at: XCTUnwrap(worker.url), room: worker.room, token: run.identifier, timeout: 45 + run.mutedWait
            )
        }
    }

    func join(invitation: URL) throws {
        let groupID = run.groupID
        if run.startsFromSavedGroup {
            XCTAssertEqual(viewModel.enabledRTCTransportRoutes, run.enabledRoutes)
            XCTAssertTrue(viewModel.groups.contains { $0.id == groupID })
            XCTAssertNil(viewModel.activeGroupID)
            viewModel.openDestination(.group(groupID))
            XCTAssertEqual(viewModel.activeGroupID, groupID)
        } else {
            try viewModel.acceptInviteURL(invitation)
        }
    }

    func makeBarrier() throws -> AudioE2EBarrier {
        let rendezvous: (@MainActor (String, Double) async throws -> Void)?
        if run.mutedWait > 0 {
            let url = try XCTUnwrap(worker.url)
            rendezvous = { phase, timeout in
                try await AudioE2EWorker.waitForPairStage(
                    at: url, room: worker.room, run: run, phase: phase, timeout: timeout
                )
            }
        } else {
            rendezvous = nil
        }
        return AudioE2EBarrier(session: viewModel.callSession, rendezvous: rendezvous)
    }

    func waitForAuthenticatedPeer(joiningStarted: ContinuousClock.Instant) async throws -> String {
        try await waitUntil(
            seconds: 60, description: "Verified peer, RTC audio admission and active audio", status: status
        ) {
            viewModel.authenticatedPeerIDs.count == 1 && viewModel.isAudioReady
                && IntercomViewModel.admittedMemberships(in: viewModel.peerProfiles).count == 1
                && (!run.startsFromSavedGroup || viewModel.callAccessState.isEstablished)
        }
        let peerID = try XCTUnwrap(viewModel.authenticatedPeerIDs.first)
        if run.startsFromSavedGroup {
            XCTAssertEqual(viewModel.availableCallRoutes, [.multipeer])
            let elapsed = joiningStarted.duration(to: .now)
            print("Audio E2E: Restored saved group and established Local call after \(elapsed)")
        }
        return peerID
    }

    func status() -> String {
        "state=\(viewModel.connectionState) authenticated=\(viewModel.authenticatedPeerIDs.count) "
            + "ready=\(viewModel.isAudioReady) tx=\(viewModel.sentVoicePacketCount) "
            + "rx=\(viewModel.receivedVoicePacketCount) "
            + "outputBatches=\(observedOutputBatches(viewModel)) audioError=\(viewModel.audioErrorMessage ?? "none") "
            + "input=\(String(describing: viewModel.lastInputStreamOperationReport?.result)) "
            + "output=\(String(describing: viewModel.lastOutputStreamOperationReport?.result)) "
            + "session=\(String(describing: viewModel.lastAudioSessionConfigurationReport?.operations))"
    }
}

struct AudioE2EPair {
    let endpoint: AudioE2EEndpoint
    let peerID: String
    let barrier: AudioE2EBarrier
}

extension AudioE2ETests {
    @MainActor
    func verifyDuplex(
        _ endpoint: AudioE2EEndpoint, invitation: URL, routes: AudioE2ERouteFixture
    ) async throws {
        let run = endpoint.run
        let viewModel = endpoint.viewModel
        try await endpoint.waitForFirstParticipantIfNeeded()
        let joiningStarted = ContinuousClock.now
        try endpoint.join(invitation: invitation)
        let receiveTrace = NetworkAudioReception(
            pipeline: viewModel.audioPipeline, decodedProbe: endpoint.audio.decodedProbe
        )
        if run.waitsForInternet {
            // Starting the call binds its receiver synchronously. Install the
            // observation before yielding for authentication and the first speech.
            viewModel.callSession.processReceivedAudio = receiveTrace.process
        }
        let waiting = AudioE2EWaitingCall(viewModel: viewModel)
        if run.mutedWait > 0, run.role == "a" {
            XCTAssertTrue(viewModel.setCallMuted(true, for: waiting.reference))
        }
        if run.movesToBackground {
            try await leaveForSettingsAfterStartingCall(viewModel: viewModel, joiningStarted: joiningStarted)
        }
        let barrier = try endpoint.makeBarrier()
        defer {
            let attachment = XCTAttachment(
                string: endpoint.status() + "\nmixer=\(viewModel.audioPipeline.snapshot)"
                    + "\nvad=\(viewModel.vadGateRuntimeSnapshot)"
            )
            attachment.name = "endpoint-\(run.role)-status"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        if run.waitsForLateParticipant, run.role == "a" {
            try await verifyWaitingParticipant(endpoint, waiting: waiting)
        }
        let peerID = try await endpoint.waitForAuthenticatedPeer(joiningStarted: joiningStarted)
        let pair = AudioE2EPair(endpoint: endpoint, peerID: peerID, barrier: barrier)
        if run.waitsForLateParticipant {
            try await verifyLateParticipant(pair, routes: routes, waiting: waiting, joiningStarted: joiningStarted)
            return
        }
        #if DEBUG
        if let instrumentedRoutes = routes.instrumentedRoutes {
            try await verifyMixedRoutes(pair, routes: instrumentedRoutes)
            return
        }
        #endif
        if !run.waitsForInternet { viewModel.callSession.processReceivedAudio = receiveTrace.process }
        try await measureNetworkScenarios(pair, receiveTrace: receiveTrace)
    }

    #if DEBUG
    @MainActor
    private func verifyMixedRoutes(_ pair: AudioE2EPair, routes: MixedRouteAudioE2E) async throws {
        try await routes.verify(test: self, pair: pair)
    }
    #endif
}
