import Foundation
import Network

/// Owns incoming UDP flows on the transport queue. Stopping retires every flow and its pending callbacks.
final class LocalDatagramReceiver: @unchecked Sendable {
    private struct Flow {
        let connection: NWConnection
        var lastActivity: TimeInterval
        var lastReceiptAt: TimeInterval = -.infinity
    }

    private var flows: [UUID: Flow] = [:]

    func accept(
        _ connection: NWConnection, on queue: DispatchQueue,
        makeReceipt: @escaping @Sendable (PeerID, Data) -> Data?,
        onReceive: @escaping @Sendable (PeerID, Data) -> Void
    ) {
        // UDP has no disconnect handshake. Evict the oldest flow at the resource bound.
        if flows.count >= 16, let oldest = flows.min(by: { $0.value.lastActivity < $1.value.lastActivity })?.key {
            flows.removeValue(forKey: oldest)?.connection.cancel()
        }
        let flowID = UUID()
        flows[flowID] = Flow(connection: connection, lastActivity: ProcessInfo.processInfo.systemUptime)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.flows[flowID] != nil else { return }
            if case .failed = state { connection.cancel(); self.flows[flowID] = nil }
            if case .cancelled = state { self.flows[flowID] = nil }
        }
        connection.start(queue: queue)
        receive(connection, flowID: flowID, makeReceipt: makeReceipt, onReceive: onReceive)
    }

    func stop() {
        for flow in flows.values { flow.connection.cancel() }
        flows.removeAll()
    }

    private func receive(
        _ connection: NWConnection, flowID: UUID,
        makeReceipt: @escaping @Sendable (PeerID, Data) -> Data?,
        onReceive: @escaping @Sendable (PeerID, Data) -> Void
    ) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.flows[flowID] != nil else { return }
            self.flows[flowID]?.lastActivity = ProcessInfo.processInfo.systemUptime
            if let data, let packet = LocalMediaFraming.decode(data) {
                let now = ProcessInfo.processInfo.systemUptime
                // Do not amplify small/unknown datagrams.
                if data.count >= LocalMediaReceiptAuthenticator.byteCount,
                   now - (self.flows[flowID]?.lastReceiptAt ?? now) >= LocalMediaReceiptWindow.interval,
                   let receipt = makeReceipt(packet.sender, data) {
                    self.flows[flowID]?.lastReceiptAt = now
                    connection.send(content: receipt, completion: .contentProcessed { _ in })
                }
                onReceive(packet.sender, packet.payload)
            }
            if error == nil {
                self.receive(connection, flowID: flowID, makeReceipt: makeReceipt, onReceive: onReceive)
            } else {
                connection.cancel(); self.flows[flowID] = nil
            }
        }
    }
}

extension LocalDatagramTransport {
    static func parameters() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        // Nearby voice must work without an AP and never use a cellular path.
        // Do not require a specific interface: that disables peer-to-peer opt-in.
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }
}
