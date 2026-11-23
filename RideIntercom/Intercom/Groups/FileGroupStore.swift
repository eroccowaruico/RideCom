import Darwin
import Foundation

/// All repository operations hold the same nonblocking process lock, including GC.
final class FileGroupStore: GroupStoring {
    let url: URL
    private var lockDescriptor: Int32 = -1
    private let prepareProtection: (URL) throws -> Void

    init(
        directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RideIntercom/Groups", isDirectory: true),
        prepareProtection: @escaping (URL) throws -> Void = CallStorageProtection.prepare
    ) {
        url = directory.appendingPathComponent("groups.json")
        self.prepareProtection = prepareProtection
    }
    deinit { if lockDescriptor >= 0 { Darwin.close(lockDescriptor) } }

    func lock() throws {
        guard lockDescriptor == -1 else { throw GroupStorageError.busy }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try prepareProtection(url.deletingLastPathComponent())
        let lockURL = url.deletingPathExtension().appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try prepareProtection(lockURL)
            try prepareProtection(url)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw GroupStorageError.busy }
        lockDescriptor = descriptor
    }
    func unlock() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN); Darwin.close(lockDescriptor); lockDescriptor = -1
    }
    func read() throws -> GroupSnapshot? {
        let bytes: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= GroupSnapshot.maximumEncodedBytes else { throw IntercomGroupError.invalidStoredGroups }
            bytes = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        return try GroupSnapshot.decode(bytes)
    }
    func commit(_ snapshot: GroupSnapshot) throws {
        // Foundation writes a sibling temporary file and replaces the directory entry.
        // This is a process-interruption boundary, not a power-loss durability promise.
        try snapshot.encoded().write(to: url, options: CallStorageProtection.writingOptions)
    }
    func archive() throws {
        let directory = url.deletingLastPathComponent()
        do {
            let destination = directory.appendingPathComponent("groups-corrupt-\(UUID()).json")
            try FileManager.default.copyItem(at: url, to: destination)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
    }
}
