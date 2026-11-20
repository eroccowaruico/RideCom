import Foundation
import RTC

/// The short-lived routes for a single saved contact invitation.
@MainActor
final class ContactInvitationTransport {
    enum Event {
        case members(Set<String>)
        case message(peer: String, ApplicationDataMessage)
    }

    // Allows an 8 KiB payload after base64 encoding, plus the message fields.
    private static let maximumLocalFrameBytes = 12 * 1024

    private let memberID: String
    private let session: CallSession?
    private let sessionRoutes: Set<RTC.RouteKind>
    private let localEnabled: Bool
    private var local: RTCLocalDataChannel?
    private var localPeers: Set<String> = []
    private var sessionPeers: Set<String> = []
    var onEvent: ((Event) -> Void)?

    init(memberID: String, routes: Set<RTC.RouteKind>, internetConfiguration: RTC.CloudflareRealtimeConfiguration?,
         injectedSession: CallSession?) {
        self.memberID = memberID
        localEnabled = injectedSession == nil && routes.contains(.multipeer)
        sessionRoutes = injectedSession == nil ? [.webRTC] : routes
        if let injectedSession {
            session = injectedSession
        } else if routes.contains(.webRTC), let internetConfiguration {
            session = RideIntercomCallSessionAdapter(memberID: memberID, internetConfiguration: internetConfiguration)
        } else {
            session = nil
        }
    }

    func start(_ token: GroupInviteToken, displayName: String) throws {
        if let session {
            var members = [GroupMember(id: memberID, displayName: displayName)]
            if token.inviterMemberID != memberID {
                members.append(.init(id: token.inviterMemberID, displayName: token.inviterDisplayName ?? "Inviter"))
            }
            let rendezvous = try IntercomGroup(id: token.groupID, name: "Contact Invitation", members: members,
                                             accessSecret: token.groupSecret)
            session.onEvent = { [weak self] event in self?.receiveSession(event) }
            session.setEnabledRoutes(sessionRoutes)
            session.connect(group: rendezvous)
        }
        if localEnabled {
            let credential = RTCCredential.derived(groupID: token.groupID.uuidString, secret: token.groupSecret)
            let channel = RTCLocalDataChannel(localID: .init(rawValue: memberID), credential: credential) { [weak self] event in
                // The transport calls back on one queue. Preserve the order of
                // membership snapshots and messages when entering MainActor.
                DispatchQueue.main.async { self?.receiveLocal(event) }
            }
            local = channel
            channel.start()
        }
    }

    func stop() {
        onEvent = nil
        session?.onEvent = nil
        session?.disconnect()
        local?.stop()
        local = nil
        localPeers = []
        sessionPeers = []
    }

    func send(_ message: ApplicationDataMessage) {
        session?.sendApplicationData(message)
        if let local, let data = try? JSONEncoder().encode(message), data.count <= Self.maximumLocalFrameBytes {
            local.send(data)
        }
    }

    private func receiveSession(_ event: TransportEvent) {
        switch event {
        case .authenticated(let members):
            sessionPeers = Set(members.lazy.filter(\.isConnected).map { $0.peer.id.rawValue })
            publishMembers()
        case .disconnected:
            sessionPeers = []
            publishMembers()
        case .receivedApplicationData(let peerID, let message):
            onEvent?(.message(peer: peerID, message))
        default:
            break
        }
    }

    private func receiveLocal(_ event: RTCLocalDataChannel.Event) {
        guard let local else { return }
        switch event {
        case .members(let members):
            localPeers = Set(members.map(\.rawValue))
            publishMembers()
        case .message(let data, let peer):
            guard data.count <= Self.maximumLocalFrameBytes,
                  let message = try? JSONDecoder().decode(ApplicationDataMessage.self, from: data),
                  message.delivery == .reliable else { return }
            onEvent?(.message(peer: peer.rawValue, message))
        case .failed:
            local.stop()
            self.local = nil
            localPeers = []
            publishMembers()
        }
    }

    private func publishMembers() { onEvent?(.members(localPeers.union(sessionPeers))) }
}
