import Foundation

@testable import RideIntercom

@MainActor final class ContactDeletionHTTPFixture {
    struct Entry {
        let id: String
        let slot: String
        let expiresAt: Int64
        let recipientKey: String
        var state = "pending"
        var packet: String?
    }
    let owner: String
    let recipient: String
    let memberID: String
    let trust: DeviceIdentityTrust
    var entry: Entry?
    var submitted: [String] = []
    var received: [String] = []
    var readCount = 0
    var dropFirstReceiptResponse = false

    init(owner: String, recipient: String, memberID: String, trust: DeviceIdentityTrust) {
        self.owner = owner
        self.recipient = recipient
        self.memberID = memberID
        self.trust = trust
    }

    func respond(_ request: URLRequest, _ caller: String) -> (Int, [String: Any]) {
        guard let body = request.httpBody, let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let slot = fields["slot"] as? String, slot.utf8.count == 64
        else { return (400, [:]) }
        switch (request.httpMethod, request.url?.path) {
        case ("PUT", "/api/contact-deletions"): return publish(fields, slot: slot, caller: caller)
        case ("POST", "/api/contact-deletions/read"): return read(fields, slot: slot, caller: caller)
        case ("PUT", "/api/contact-deletions/receipt"): return acknowledge(fields, slot: slot, caller: caller)
        case ("DELETE", "/api/contact-deletions"): return retire(fields, slot: slot, caller: caller)
        default: return (404, [:])
        }
    }

    private func publish(_ fields: [String: Any], slot: String, caller: String) -> (Int, [String: Any]) {
        let id = fields["id"] as? String
        let expiresAt = fields["expiresAt"] as? Int64
        let packet = fields["packet"] as? String
        guard caller == owner, fields["recipient"] as? String == recipient, let id, id == id.lowercased(),
            let expiresAt, let packet, let recipientKey = fields["recipientKey"] as? String
        else { return (400, [:]) }
        submitted.append(packet)
        if submitted.count == 1 { return (503, [:]) }
        if let entry { return (200, ["state": entry.state]) }
        entry = Entry(id: id, slot: slot, expiresAt: expiresAt, recipientKey: recipientKey, packet: packet)
        return (200, ["state": "pending"])
    }

    private func read(_ fields: [String: Any], slot: String, caller: String) -> (Int, [String: Any]) {
        guard let entry, entry.slot == slot, fields["owner"] as? String == owner, let packet = entry.packet else {
            return (404, [:])
        }
        let record: [String: Any] = ["id": entry.id, "expiresAt": entry.expiresAt, "packet": packet]
        if caller == owner, entry.state == "received", fields["proof"] == nil { return (200, ["receipt": record]) }
        guard caller == recipient, entry.state == "pending",
            verified(fields, [owner, slot], purpose: .readContactDeletion, key: entry.recipientKey)
        else { return (404, [:]) }
        readCount += 1
        return (200, ["deletion": record])
    }

    private func acknowledge(_ fields: [String: Any], slot: String, caller: String) -> (Int, [String: Any]) {
        let id = fields["id"] as? String
        let packet = fields["packet"] as? String
        guard let entry, entry.slot == slot, caller == recipient, fields["owner"] as? String == owner, let id,
            id == entry.id, let packet,
            verified(
                fields, [owner, slot, id, packet], purpose: .acknowledgeContactDeletionRelay, key: entry.recipientKey)
        else { return (404, [:]) }
        received.append(packet)
        self.entry?.packet = packet
        self.entry?.state = "received"
        if dropFirstReceiptResponse && received.count == 1 { return (503, [:]) }
        return (200, ["state": "received"])
    }

    private func retire(_ fields: [String: Any], slot: String, caller: String) -> (Int, [String: Any]) {
        let id = fields["id"] as? String
        let expiresAt = fields["expiresAt"] as? Int64
        guard let entry, entry.slot == slot, caller == owner, entry.id == id, entry.expiresAt == expiresAt else {
            return (409, [:])
        }
        self.entry?.packet = nil
        self.entry?.state = "retired"
        return (200, ["state": "retired"])
    }

    private func verified(
        _ fields: [String: Any], _ values: [String], purpose: DeviceIdentityProof.Purpose, key: String
    ) -> Bool {
        guard let object = fields["proof"], let encoded = try? JSONSerialization.data(withJSONObject: object),
            let proof = try? JSONDecoder().decode(DeviceIdentityProof.self, from: encoded), proof.publicKey == key,
            let payload = try? JSONSerialization.data(withJSONObject: values, options: .withoutEscapingSlashes),
            let result = try? proof.verify(payload, purpose: purpose, memberID: memberID, trust: trust)
        else { return false }
        return result.principal?.userID == recipient
    }
}
