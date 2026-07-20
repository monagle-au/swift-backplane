//
//  ConfigStoreConcurrencyTests.swift
//  swift-backplane
//

import Testing
import Foundation
import Configuration
@testable import BackplaneVault

/// Regression tests for the cross-process lost-update bug: a store that
/// loaded the file at init and rewrote the whole file from its in-memory
/// snapshot would erase every key another store wrote after that snapshot
/// was taken. Two in-process instances reproduce the bug exactly, because
/// each backend has an independent snapshot (actor isolation does not
/// serialize distinct backends on one file).
@Suite("ConfigStore concurrent stores on one file")
struct ConfigStoreConcurrencyTests {
    let encryption = MockEncryption()

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("backplane-vault-concurrency-test-\(UUID().uuidString)")
    }

    private func makeStore(path: String, scope: String = "test") throws -> ConfigStore {
        try ConfigStore(
            filePath: path,
            scope: scope,
            encryption: encryption,
            environmentProvider: nil
        )
    }

    @Test("Interleaved writes from two stores keep every key")
    func interleavedWritesSurvive() async throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = try makeStore(path: path)
        let store2 = try makeStore(path: path)

        try await store1.set("one", forKey: "key1")
        try await store2.set("two", forKey: "key2")
        try await store1.set("three", forKey: "key3")
        try await store2.set("four", forKey: "key4")

        let onDisk = try ConfigWriter.read(filePath: path)
        #expect(onDisk["key1"] as? String == "one")
        #expect(onDisk["key2"] as? String == "two")
        #expect(onDisk["key3"] as? String == "three")
        #expect(onDisk["key4"] as? String == "four")
    }

    @Test("A store with a stale snapshot does not erase a later writer's key")
    func staleSnapshotDoesNotEraseLaterWrite() async throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // The incident shape: store1 loads (empty) snapshot first, store2
        // writes hapPairings, then store1 writes hapConfigNumber. Under
        // snapshot-rewrite, store1's write deleted store2's key.
        let store1 = try makeStore(path: path)
        let store2 = try makeStore(path: path)
        try await store2.set("pairing-data", forKey: "hapPairings")
        try await store1.set(7, forKey: "hapConfigNumber")

        let onDisk = try ConfigWriter.read(filePath: path)
        #expect(onDisk["hapPairings"] as? String == "pairing-data")
        #expect(onDisk["hapConfigNumber"] as? Int == 7)
    }

    @Test("remove(key:) removes only its own key")
    func removeIsPerKey() async throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = try makeStore(path: path)
        let store2 = try makeStore(path: path)

        try await store1.set("mine", forKey: "keyA")
        try await store2.set("theirs", forKey: "keyB")
        try await store1.remove(key: "keyA")

        let onDisk = try ConfigWriter.read(filePath: path)
        #expect(onDisk["keyA"] == nil)
        #expect(onDisk["keyB"] as? String == "theirs")
    }

    @Test("Secrets round-trip through the merge path")
    func secretsRoundTripThroughMerge() async throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = try makeStore(path: path)
        let store2 = try makeStore(path: path)

        try await store1.setSecret("s3cret", forKey: "apiKey")
        // A second store's write must merge around the secret, not clobber it.
        try await store2.set("plain", forKey: "other")

        // Stored ciphertext survives on disk...
        let onDisk = try ConfigWriter.read(filePath: path)
        #expect(onDisk["apiKey"] as? String == "mock-encrypted:s3cret")

        // ...the writing store still reads it decrypted...
        #expect(store1.secret(forKey: "apiKey") == "s3cret")

        // ...and a fresh store loads it as a decryptable secret.
        let store3 = try makeStore(path: path)
        #expect(store3.secret(forKey: "apiKey") == "s3cret")
        #expect(store3.reader.string(forKey: "other") == "plain")
    }

    @Test("File permissions stay 0o600 through merge writes")
    func permissionsPreserved() async throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = try makeStore(path: path)
        let store2 = try makeStore(path: path)
        try await store1.set("a", forKey: "one")
        try await store2.set("b", forKey: "two")
        try await store1.remove(key: "one")

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test("Local write opportunistically refreshes externally written keys")
    func localWriteRefreshesFromMergedFile() async throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = try makeStore(path: path)
        let store2 = try makeStore(path: path)

        try await store2.set("external", forKey: "fromOther")
        // store1 hasn't reloaded — but its own write merges against the
        // fresh file and refreshes its in-memory state from the result.
        try await store1.set("local", forKey: "mine")

        #expect(store1.reader.string(forKey: "fromOther") == "external")
        #expect(store1.reader.string(forKey: "mine") == "local")
    }

    @Test("Concurrent writers from two stores lose nothing", .timeLimit(.minutes(1)))
    func concurrentHammer() async throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = try makeStore(path: path)
        let store2 = try makeStore(path: path)
        let perStore = 25

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<perStore {
                    try await store1.set("v\(i)", forKey: "s1-\(i)")
                }
            }
            group.addTask {
                for i in 0..<perStore {
                    try await store2.set("v\(i)", forKey: "s2-\(i)")
                }
            }
            try await group.waitForAll()
        }

        let onDisk = try ConfigWriter.read(filePath: path)
        for i in 0..<perStore {
            #expect(onDisk["s1-\(i)"] as? String == "v\(i)", "store1 key \(i) lost")
            #expect(onDisk["s2-\(i)"] as? String == "v\(i)", "store2 key \(i) lost")
        }
    }

    @Test("Dotted-scope write-through still works via the merge path")
    func dottedScopeWriteThroughSurvivesMerge() async throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = try makeStore(path: path, scope: "service.database")
        let other = try makeStore(path: path, scope: "service.database")
        try await other.set("kept", forKey: "otherKey")
        try await store.set("db.example.com", forKey: "host")

        // Same-instance immediate visibility (the dotted-scope regression).
        #expect(store.reader.string(forKey: "host") == "db.example.com")

        // Both keys survive on disk.
        let onDisk = try ConfigWriter.read(filePath: path)
        #expect(onDisk["otherKey"] as? String == "kept")
        #expect(onDisk["host"] as? String == "db.example.com")
    }
}

@Suite("FileLock")
struct FileLockTests {
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("backplane-vault-filelock-test-\(UUID().uuidString)")
    }

    @Test("Second acquire waits until release")
    func excludesUntilReleased() async throws {
        let tmpDir = makeTempDir()
        let lockPath = tmpDir.appendingPathComponent("data.json.lock").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let first = try await FileLock.acquire(lockFilePath: lockPath, timeout: .seconds(1))

        // While held, an independent descriptor cannot acquire it.
        await #expect(throws: FileLockError.self) {
            _ = try await FileLock.acquire(lockFilePath: lockPath, timeout: .milliseconds(150))
        }

        first.release()
        let second = try await FileLock.acquire(lockFilePath: lockPath, timeout: .seconds(1))
        second.release()
    }

    @Test("Timeout error is descriptive")
    func timeoutErrorDescription() async throws {
        let tmpDir = makeTempDir()
        let lockPath = tmpDir.appendingPathComponent("data.json.lock").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let held = try await FileLock.acquire(lockFilePath: lockPath, timeout: .seconds(1))
        defer { held.release() }

        do {
            _ = try await FileLock.acquire(lockFilePath: lockPath, timeout: .milliseconds(100))
            Issue.record("Expected timeout")
        } catch let error as FileLockError {
            #expect(String(describing: error).contains(lockPath))
        }
    }

    @Test("Blocking acquire round-trips")
    func blockingAcquire() throws {
        let tmpDir = makeTempDir()
        let dataPath = tmpDir.appendingPathComponent("data.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lock = try FileLock.acquireBlocking(forProtecting: dataPath, timeout: .seconds(1))
        #expect(lock.lockFilePath == dataPath + ".lock")
        lock.release()
        // Idempotent release must be safe.
        lock.release()
    }

    @Test("Lock file is created 0o600 and left in place")
    func lockFilePermissions() async throws {
        let tmpDir = makeTempDir()
        let dataPath = tmpDir.appendingPathComponent("data.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lock = try await FileLock.acquire(forProtecting: dataPath)
        lock.release()

        let lockPath = FileLock.lockFilePath(forProtecting: dataPath)
        #expect(FileManager.default.fileExists(atPath: lockPath))
        let attributes = try FileManager.default.attributesOfItem(atPath: lockPath)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}
