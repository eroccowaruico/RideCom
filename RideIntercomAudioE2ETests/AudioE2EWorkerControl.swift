import Foundation
import RTC
import XCTest

struct AudioE2EWorkerConnection {
    let url: URL?
    let fixture: AudioE2EWorker?
    let room: String

    func settingsOrigin() throws -> URL {
        var origin = try XCTUnwrap(url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(origin.host, "127.0.0.1")
        origin.scheme = "https"
        return try XCTUnwrap(origin.url)
    }
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
            holdsInternetSignaling: options.startsBeforeInternet, leavesICEUnanswered: options.waitsForInternet,
            checksCredentialRecovery: options.recoversRejectedCredential
        )
        try await fixture.start()
        addTeardownBlock { await fixture.stop() }
        return AudioE2EWorkerConnection(url: url, fixture: fixture, room: room)
    }
}

extension AudioE2EWorker {
    static func waitForPairStage(
        at worker: URL, room: String, run: AudioE2ENetworkRun, phase: String, timeout: Double
    ) async throws {
        let url = worker.appendingPathComponent("api/rooms/\(room)/test-pair-stage")
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("Bearer " + run.identifier, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["participantId": run.memberID, "stage": phase])
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        print("Audio E2E: Synchronizing \(phase) through the fixture worker")
        repeat {
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               try JSONDecoder().decode([String: Bool].self, from: data)["ready"] == true { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw NSError(domain: "AudioE2E.PairStage.\(phase)", code: 1)
    }

    static func waitForFirstParticipant(at worker: URL, room: String, token: String, timeout: Int) async throws {
        let url = worker.appendingPathComponent("api/rooms/\(room)/test-waiting-participant")
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let state = try? JSONDecoder().decode([String: Bool].self, from: data), state["ready"] == true {
                return
            }
            try await Task.sleep(for: timeout > 45 ? .seconds(1) : .milliseconds(150))
        }
        throw NSError(domain: "AudioE2E.WaitingParticipant", code: 1)
    }

    static func signalInternetOutage(_ phase: String, at workerURL: URL, room: String,
                                     token: String, participantID: String) async throws {
        let url = workerURL.appendingPathComponent("api/rooms/\(room)/test-internet-outage-\(phase)")
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["participantId": participantID])
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        guard status == 200 else { throw NSError(domain: "AudioE2E.InternetOutage.\(phase)", code: status) }
    }
}
