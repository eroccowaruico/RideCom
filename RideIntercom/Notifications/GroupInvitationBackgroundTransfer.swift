import Foundation

nonisolated struct GroupInvitationUploadID: Hashable, Sendable {
    enum Operation: String, Hashable, Sendable { case send, cancel }
    let deliveryID: UUID
    let sessionBinding: String
    let operation: Operation
}

@MainActor
protocol GroupInvitationBackgroundTransferring: AnyObject {
    var hasRestored: Bool { get }
    func restore() async
    func reconcile(keeping keys: Set<GroupInvitationUploadID>)
    func contains(_ key: GroupInvitationUploadID) -> Bool
    func enqueue(_ request: URLRequest, for key: GroupInvitationUploadID) throws
}

#if os(iOS)
@MainActor
final class GroupInvitationBackgroundTransfer: NSObject, GroupInvitationBackgroundTransferring, URLSessionDataDelegate {
    static let shared = GroupInvitationBackgroundTransfer()
    static let identifier = "com.yowamushi-inc.RideIntercom.group-invitations"

    private weak var owner: AppCallOwner?
    private var restoration: Task<[URLSessionTask], Never>?
    private(set) var hasRestored = false
    private var uploads: [GroupInvitationUploadID: URLSessionTask] = [:]
    private var responses: [Int: Data] = [:]
    private var backgroundCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForResource = GroupDeliveryRecord.invitationLifetime
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    func bind(to owner: AppCallOwner) {
        self.owner = owner
        Task {
            await restore()
            reconcile(keeping: self.owner?.viewModel?.backgroundGroupInvitationUploadIDs() ?? [])
        }
    }

    func restore() async {
        guard !hasRestored else { return }
        if restoration == nil { restoration = Task { await session.allTasks } }
        guard let tasks = await restoration?.value, !hasRestored else { return }
        for task in tasks where task.state == .running || task.state == .suspended {
            guard let key = Self.key(for: task), uploads[key] == nil else { task.cancel(); continue }
            uploads[key] = task
        }
        hasRestored = true
        restoration = nil
    }

    func reconcile(keeping keys: Set<GroupInvitationUploadID>) {
        for key in Array(uploads.keys) {
            guard let task = uploads[key] else { continue }
            if !keys.contains(key) {
                uploads.removeValue(forKey: key)
                task.cancel()
            } else if task.state == .suspended {
                task.resume()
            }
        }
    }

    func contains(_ key: GroupInvitationUploadID) -> Bool { uploads[key] != nil }

    func enqueue(_ request: URLRequest, for key: GroupInvitationUploadID) throws {
        guard uploads[key] == nil, let body = request.httpBody else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try body.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var headers = request
        headers.httpBody = nil
        // A file upload in a background session copies the source when the task is created.
        let task = session.uploadTask(with: headers, fromFile: file)
        task.taskDescription = [key.deliveryID.uuidString, key.sessionBinding, key.operation.rawValue].joined(separator: ":")
        uploads[key] = task
        task.resume()
    }

    func handleEvents(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        _ = session
    }

    private static func key(for task: URLSessionTask) -> GroupInvitationUploadID? {
        guard let fields = task.taskDescription?.split(separator: ":", omittingEmptySubsequences: false), fields.count == 3,
              let id = UUID(uuidString: String(fields[0])), InternetAccountClient.notificationUserID(String(fields[1])),
              let operation = GroupInvitationUploadID.Operation(rawValue: String(fields[2])) else { return nil }
        return .init(deliveryID: id, sessionBinding: String(fields[1]), operation: operation)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            let id = dataTask.taskIdentifier
            guard (responses[id]?.count ?? 0) + data.count <= 4_096 else {
                dataTask.cancel()
                return
            }
            responses[id, default: Data()].append(data)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            let data = responses.removeValue(forKey: task.taskIdentifier)
            guard let key = Self.key(for: task) else { return }
            // A restored completion can arrive before enumeration. A superseded task cannot commit.
            if let active = uploads[key] {
                guard active.taskIdentifier == task.taskIdentifier else { return }
                uploads.removeValue(forKey: key)
            }
            guard error == nil, let response = task.response as? HTTPURLResponse, response.statusCode == 200,
                  let originalURL = task.originalRequest?.url, response.url == originalURL, let data,
                  let reply = try? JSONDecoder().decode(GroupDeliveryReply.self, from: data) else { return }
            owner?.viewModel?.applyBackgroundGroupInvitationReply(reply, for: key)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            let completion = backgroundCompletion
            backgroundCompletion = nil
            completion?()
        }
    }
}
#endif
