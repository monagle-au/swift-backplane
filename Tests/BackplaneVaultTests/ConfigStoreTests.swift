//
//  ConfigStoreTests.swift
//  swift-backplane
//

import Testing
import Foundation
import Configuration
@testable import BackplaneVault

@Suite("ConfigStore")
struct ConfigStoreTests {
    let encryption = MockEncryption()

    // MARK: - In-Memory

    @Test("In-memory set and read string")
    func inMemoryString() async throws {
        let store = ConfigStore.inMemory(encryption: encryption)
        try await store.set("hello", forKey: "greeting")
        let value = store.reader.string(forKey: "greeting")
        #expect(value == "hello")
    }

    @Test("In-memory set and read int")
    func inMemoryInt() async throws {
        let store = ConfigStore.inMemory(encryption: encryption)
        try await store.set(42, forKey: "count")
        let value = store.reader.int(forKey: "count")
        #expect(value == 42)
    }

    @Test("In-memory set and read bool")
    func inMemoryBool() async throws {
        let store = ConfigStore.inMemory(encryption: encryption)
        try await store.set(true, forKey: "enabled")
        let value = store.reader.bool(forKey: "enabled")
        #expect(value == true)
    }

    @Test("In-memory set and read double")
    func inMemoryDouble() async throws {
        let store = ConfigStore.inMemory(encryption: encryption)
        try await store.set(3.14, forKey: "pi")
        let value = store.reader.double(forKey: "pi")
        #expect(value == 3.14)
    }

    @Test("In-memory remove key")
    func inMemoryRemove() async throws {
        let store = ConfigStore.inMemory(encryption: encryption)
        try await store.set("temp", forKey: "key")
        #expect(store.reader.string(forKey: "key") == "temp")

        try await store.remove(key: "key")
        #expect(store.reader.string(forKey: "key") == nil)
    }

    @Test("In-memory setSecret encrypts value")
    func inMemorySetSecret() async throws {
        let store = ConfigStore.inMemory(encryption: encryption)
        try await store.setSecret("my-api-key", forKey: "appKey")

        // The DecryptingConfigProvider transparently decrypts on read
        let value = store.secret(forKey: "appKey")
        #expect(value == "my-api-key")
    }

    @Test("In-memory initial values are readable")
    func inMemoryInitialValues() {
        let store = ConfigStore.inMemory(values: ["host": "localhost", "port": "8080"])
        #expect(store.reader.string(forKey: "host") == "localhost")
        #expect(store.reader.string(forKey: "port") == "8080")
    }

    // MARK: - Scoping

    @Test("Scoped store prefixes keys")
    func scopedStore() async throws {
        let store = ConfigStore.inMemory(encryption: encryption)
        let scoped = store.scoped(to: "bridge")
        try await store.set("192.168.1.10", forKey: "bridge.ip")

        let value = scoped.reader.string(forKey: "ip")
        #expect(value == "192.168.1.10")
    }

    // MARK: - File-Backed

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("backplane-vault-config-store-test-\(UUID().uuidString)")
    }

    @Test("File-backed persistence and reload")
    func fileBacked() async throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write some values
        let store = try ConfigStore(
            filePath: path,
            scope: "test",
            encryption: encryption,
            environmentProvider: nil
        )
        try await store.set("value1", forKey: "key1")
        try await store.set(99, forKey: "key2")

        // Create a new store from the same file
        let store2 = try ConfigStore(
            filePath: path,
            scope: "test",
            encryption: encryption,
            environmentProvider: nil
        )
        #expect(store2.reader.string(forKey: "key1") == "value1")
        #expect(store2.reader.int(forKey: "key2") == 99)
    }

    @Test("File-backed secret persistence")
    func fileBackedSecret() async throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = try ConfigStore(
            filePath: path,
            scope: "test",
            encryption: encryption,
            environmentProvider: nil
        )
        try await store.setSecret("secret-value", forKey: "apiKey")

        // Verify the file contains the encrypted value, not plaintext
        let raw = try ConfigWriter.read(filePath: path)
        let storedValue = raw["apiKey"] as? String
        #expect(storedValue == "mock-encrypted:secret-value")

        // New store from the same file decrypts on read
        let store2 = try ConfigStore(
            filePath: path,
            scope: "test",
            encryption: encryption,
            environmentProvider: nil
        )
        #expect(store2.secret(forKey: "apiKey") == "secret-value")
    }

    @Test("Reload picks up external file changes")
    func reload() async throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = try ConfigStore(
            filePath: path,
            scope: "test",
            encryption: encryption,
            environmentProvider: nil
        )
        try await store.set("original", forKey: "key")
        #expect(store.reader.string(forKey: "key") == "original")

        // Simulate an external modification
        try ConfigWriter.merge(key: "key", value: "modified", filePath: path)

        // Before reload, still sees old value
        #expect(store.reader.string(forKey: "key") == "original")

        // After reload, sees new value
        try await store.reload()
        #expect(store.reader.string(forKey: "key") == "modified")
    }

    @Test("Default PassthroughEncryption for in-memory store")
    func defaultPassthroughEncryption() async throws {
        let store = ConfigStore.inMemory()
        try await store.set("hello", forKey: "key")
        #expect(store.reader.string(forKey: "key") == "hello")
    }
}
