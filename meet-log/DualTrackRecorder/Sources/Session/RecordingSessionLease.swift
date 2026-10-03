import Darwin
import Foundation

/// Process-wide and cross-process exclusion. The OS releases this lock on a crash.
public final class RecordingSessionLease: @unchecked Sendable {
    public enum LeaseError: Error { case busy }
    private var descriptor: Int32 = -1

    public init(directory: URL) throws {
        let url = directory.appendingPathComponent(".session-lock")
        let opened = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard opened >= 0 else { throw RecorderError.outputFailed("Could not open the recording session lock.") }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(opened)
            if code == EWOULDBLOCK { throw LeaseError.busy }
            throw RecorderError.outputFailed("Could not lock the recording session.")
        }
        descriptor = opened
    }

    deinit {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    public static func isActive(in directory: URL) throws -> Bool {
        do {
            let lease = try RecordingSessionLease(directory: directory)
            withExtendedLifetime(lease) { }
            return false
        } catch LeaseError.busy { return true }
    }
}
