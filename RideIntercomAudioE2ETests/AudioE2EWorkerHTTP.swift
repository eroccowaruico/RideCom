import CryptoKit
import Foundation
import Network

enum AudioE2EWorkerHTTP {
    private enum Failure: Error { case invalidRequest, disconnected }

    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: [String: Any]
    }
    static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(throwing: Failure.disconnected)
                }
            }
        }
    }
    static func readRequest(_ connection: NWConnection) async throws -> Request {
        var bytes = Data()
        while bytes.count <= 262_144 {
            let next = try await receive(connection)
            guard !next.isEmpty else { throw Failure.disconnected }
            bytes.append(next)
            guard let split = bytes.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let header = bytes[..<split.lowerBound]
            // Preserve the parser's replacement-character handling for malformed UTF-8.
            let text = String(decoding: header, as: Unicode.UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3 else { throw Failure.invalidRequest }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
            }
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard (0...131_072).contains(length) else { throw Failure.invalidRequest }
            guard bytes.count - split.upperBound >= length else { continue }
            let body = bytes[split.upperBound..<(split.upperBound + length)]
            let object = body.isEmpty ? [:] : try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: object)
        }
        throw Failure.invalidRequest
    }
    static func send(_ connection: NWConnection, bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    static func respond(_ connection: NWConnection, status: Int = 200, body: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        try await send(connection, bytes: Data(header.utf8) + data)
    }
    static func upgradeToWebSocket(_ request: Request, connection: NWConnection) async throws {
        guard let key = request.headers["sec-websocket-key"] else { throw Failure.invalidRequest }
        let input = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        let accept = Data(Insecure.SHA1.hash(data: input)).base64EncodedString()
        let header = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        try await send(connection, bytes: Data(header.utf8))
    }
}
