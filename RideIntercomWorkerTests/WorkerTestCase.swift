import Foundation
import XCTest

class WorkerTestCase: XCTestCase {
    private struct NodeFailure: Decodable {
        let message: String
        let stack: String?
        let expected: String?
        let actual: String?
    }

    private struct NodeOutcome: Decodable {
        let status: String
        let message: String?
        let failures: [NodeFailure]?
    }

    func runWorkerCase(_ encodedCase: String, node encodedNode: String) throws {
        let request = try decode(encodedCase)
        let node = try decode(encodedNode)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let server = root.appendingPathComponent("server", isDirectory: true)
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: node)
        task.currentDirectoryURL = server
        task.arguments = [server.appendingPathComponent("test/run-worker-case.mjs").path, request]
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
        receipt.name = "Node test result"
        receipt.lifetime = .keepAlways
        add(receipt)

        let output = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        let lastLine = try XCTUnwrap(output.split(whereSeparator: \.isNewline).last, output)
        let result = try JSONDecoder().decode(NodeOutcome.self, from: Data(lastLine.utf8))
        guard task.terminationStatus == 0 && result.status == "passed" else {
            let failure = result.failures?.first
            let message = [result.message, failure?.message, failure?.stack,
                          failure?.expected.map { "Expected: " + $0 }, failure?.actual.map { "Actual: " + $0 }]
                .compactMap { $0 }.joined(separator: "\n")
            XCTFail(message.isEmpty ? output : message)
            return
        }
    }

    private func decode(_ value: String) throws -> String {
        let bytes = try XCTUnwrap(Data(base64Encoded: value))
        return try XCTUnwrap(String(bytes: bytes, encoding: .utf8))
    }
}
