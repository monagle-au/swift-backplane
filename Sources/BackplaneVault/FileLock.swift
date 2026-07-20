//
//  FileLock.swift
//  swift-backplane
//

import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// An advisory, cross-process exclusive lock backed by `flock(2)` on a
/// sidecar lock file.
///
/// The lock is taken on `<file>.lock` next to the file it protects — never on
/// the data file itself. Writers replace the data file atomically via
/// temp-file + `rename(2)`, which swaps inodes, so a lock held on the data
/// file's descriptor would silently stop excluding anyone who re-opened the
/// path after the swap. The sidecar's inode is stable for the lifetime of the
/// lock, so `flock` on it excludes across processes *and* across independent
/// descriptors within one process (each holder opens its own descriptor —
/// actor isolation alone does not serialize two backends on the same file).
///
/// Acquisition polls with `LOCK_EX | LOCK_NB` against a bounded deadline
/// rather than parking a thread in a blocking `flock` call, so a wedged
/// holder cannot hang other processes indefinitely — on timeout,
/// ``FileLockError/timedOut(lockFilePath:timeout:)`` is thrown.
///
/// The sidecar file is created with `0o600` permissions and is intentionally
/// never unlinked: removing a lock file while another process is opening it
/// hands out locks on two different inodes, reintroducing the race the lock
/// exists to prevent. An empty leftover `.lock` file is normal.
public final class FileLock: Sendable {
    /// Path of the sidecar lock file this lock holds.
    public let lockFilePath: String

    /// The open descriptor holding the `flock`; `nil` once released.
    private let descriptor: Mutex<CInt?>

    private init(lockFilePath: String, fd: CInt) {
        self.lockFilePath = lockFilePath
        self.descriptor = Mutex(fd)
    }

    deinit {
        release()
    }

    /// Release the lock by closing its descriptor. Idempotent; also runs on
    /// deinit so a dropped lock cannot outlive its holder.
    public func release() {
        let fd = descriptor.withLock { fd -> CInt? in
            defer { fd = nil }
            return fd
        }
        if let fd {
            close(fd)
        }
    }

    // MARK: - Acquisition

    /// The sidecar lock path protecting `dataFilePath` (`<file>.lock`).
    public static func lockFilePath(forProtecting dataFilePath: String) -> String {
        dataFilePath + ".lock"
    }

    /// Acquire the exclusive lock protecting `dataFilePath`, waiting up to
    /// `timeout` for another holder to release it.
    public static func acquire(
        forProtecting dataFilePath: String,
        timeout: Duration = .seconds(5)
    ) async throws -> FileLock {
        try await acquire(lockFilePath: lockFilePath(forProtecting: dataFilePath), timeout: timeout)
    }

    /// Acquire an exclusive lock on the given lock file, waiting up to
    /// `timeout` for another holder to release it.
    ///
    /// Creates the lock file (and parent directories) if needed. Waiting is
    /// cooperative — `Task.sleep` between non-blocking attempts — so no
    /// thread is parked.
    public static func acquire(
        lockFilePath: String,
        timeout: Duration = .seconds(5)
    ) async throws -> FileLock {
        let fd = try openLockFile(at: lockFilePath)
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while true {
                if try attemptExclusiveLock(fd, lockFilePath: lockFilePath) {
                    return FileLock(lockFilePath: lockFilePath, fd: fd)
                }
                guard clock.now < deadline else {
                    throw FileLockError.timedOut(lockFilePath: lockFilePath, timeout: timeout)
                }
                try await Task.sleep(for: pollInterval)
            }
        } catch {
            close(fd)
            throw error
        }
    }

    /// Synchronous counterpart of ``acquire(forProtecting:timeout:)`` for
    /// non-async contexts. Parks the calling thread for at most `timeout`.
    public static func acquireBlocking(
        forProtecting dataFilePath: String,
        timeout: Duration = .seconds(5)
    ) throws -> FileLock {
        try acquireBlocking(lockFilePath: lockFilePath(forProtecting: dataFilePath), timeout: timeout)
    }

    /// Synchronous counterpart of ``acquire(lockFilePath:timeout:)`` for
    /// non-async contexts. Parks the calling thread for at most `timeout`.
    public static func acquireBlocking(
        lockFilePath: String,
        timeout: Duration = .seconds(5)
    ) throws -> FileLock {
        let fd = try openLockFile(at: lockFilePath)
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while true {
                if try attemptExclusiveLock(fd, lockFilePath: lockFilePath) {
                    return FileLock(lockFilePath: lockFilePath, fd: fd)
                }
                guard clock.now < deadline else {
                    throw FileLockError.timedOut(lockFilePath: lockFilePath, timeout: timeout)
                }
                usleep(pollMicroseconds)
            }
        } catch {
            close(fd)
            throw error
        }
    }

    // MARK: - Private

    private static let pollInterval: Duration = .milliseconds(10)
    private static let pollMicroseconds: useconds_t = 10_000

    private static func openLockFile(at path: String) throws -> CInt {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let fd = path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600)) }
        guard fd >= 0 else {
            throw FileLockError.io(operation: "open", path: path, errno: errno)
        }
        return fd
    }

    /// One non-blocking `flock` attempt. Returns `false` if another
    /// descriptor holds the lock.
    private static func attemptExclusiveLock(_ fd: CInt, lockFilePath: String) throws -> Bool {
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return true
            }
            switch errno {
            case EINTR:
                continue
            case EWOULDBLOCK:
                return false
            default:
                throw FileLockError.io(operation: "flock", path: lockFilePath, errno: errno)
            }
        }
    }
}

// MARK: - Errors

public enum FileLockError: Error, CustomStringConvertible {
    /// The lock was still held by another process (or another descriptor in
    /// this process) when the wait deadline expired.
    case timedOut(lockFilePath: String, timeout: Duration)

    /// A lock-related syscall failed.
    case io(operation: String, path: String, errno: CInt)

    public var description: String {
        switch self {
        case .timedOut(let lockFilePath, let timeout):
            "Timed out after \(timeout) waiting for the exclusive file lock at \(lockFilePath). "
                + "Another process is holding it; if that process is wedged, stop it and retry "
                + "(do not delete the lock file while anything may still be using it)."
        case .io(let operation, let path, let code):
            "File lock \(operation) failed for \(path): \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}
