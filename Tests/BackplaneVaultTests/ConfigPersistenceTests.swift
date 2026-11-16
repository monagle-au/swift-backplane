//
//  ConfigPersistenceTests.swift
//  swift-backplane
//

import Configuration
import Foundation
import Testing

@testable import BackplaneVault

// MARK: - Test doubles

/// Records every save; can be changed from outside to simulate another writer.
actor RecordingPersistence: ConfigPersistence {
    var stored: [String: ConfigEntry]
    var saves: [[String: ConfigEntry]] = []
    private let yieldsOnSave: Bool

    init(_ initial: [String: ConfigEntry] = [:], yieldsOnSave: Bool = false) {
        stored = initial
        self.yieldsOnSave = yieldsOnSave
    }

    func load() async throws -> [String: ConfigEntry] { stored }

    func save(_ entries: [String: ConfigEntry]) async throws {
        if yieldsOnSave {
            // Give other callers a chance to interleave.
            for _ in 0..<3 { await Task.yield() }
        }
        stored = entries
        saves.append(entries)
    }

    func replaceExternally(_ entries: [String: ConfigEntry]) { stored = entries }
}

struct Boom: Error {}

/// Fails every save after the first `allowed` saves.
actor FailingPersistence: ConfigPersistence {
    var stored: [String: ConfigEntry]
    private var allowed: Int

    init(_ initial: [String: ConfigEntry] = [:], allowed: Int = 0) {
        stored = initial
        self.allowed = allowed
    }

    func load() async throws -> [String: ConfigEntry] { stored }

    func save(_ entries: [String: ConfigEntry]) async throws {
        guard allowed > 0 else { throw Boom() }
        allowed -= 1
        stored = entries
    }
}

// MARK: - Tests

@Suite("ConfigPersistence")
struct ConfigPersistenceTests {
    @Test("Loaded entries are readable, secrets in plaintext under passthrough")
    func loads() async throws {
        let persistence = RecordingPersistence([
            "bridge.ip": ConfigEntry(value: .string("10.0.0.2"), isSecret: false),
            "appKey": ConfigEntry(value: .string("plain-secret"), isSecret: true),
            "port": ConfigEntry(value: .int(443), isSecret: false),
            "ratio": ConfigEntry(value: .double(0.5), isSecret: false),
            "enabled": ConfigEntry(value: .bool(true), isSecret: false),
        ])
        let store = try await ConfigStore(
            persistence: persistence, scope: "agent.test", encryption: .passthrough, environmentProvider: nil)
        #expect(store.reader.string(forKey: "bridge.ip") == "10.0.0.2")
        #expect(store.secret(forKey: "appKey") == "plain-secret")
        #expect(store.reader.int(forKey: "port") == 443)
        #expect(store.reader.double(forKey: "ratio") == 0.5)
        #expect(store.reader.bool(forKey: "enabled") == true)
        #expect(await persistence.saves.isEmpty)
    }

    @Test("set and setSecret save the whole document with secret flags")
    func saves() async throws {
        let persistence = RecordingPersistence([
            "kept": ConfigEntry(value: .string("yes"), isSecret: false)
        ])
        let store = try await ConfigStore(
            persistence: persistence, scope: "agent.test", encryption: .passthrough, environmentProvider: nil)
        try await store.set("on", forKey: "mode")
        try await store.setSecret("s3cret", forKey: "token")
        let last = try #require(await persistence.saves.last)
        #expect(last["kept"] == ConfigEntry(value: .string("yes"), isSecret: false))
        #expect(last["mode"] == ConfigEntry(value: .string("on"), isSecret: false))
        #expect(last["token"] == ConfigEntry(value: .string("s3cret"), isSecret: true))
        #expect(store.reader.string(forKey: "mode") == "on")
        #expect(store.secret(forKey: "token") == "s3cret")
    }

    @Test("Overwriting a secret with a plain value clears its secret flag")
    func secretFlagFollowsLastWrite() async throws {
        let persistence = RecordingPersistence()
        let store = try await ConfigStore(
            persistence: persistence, scope: "s", encryption: .passthrough, environmentProvider: nil)
        try await store.setSecret("hidden", forKey: "k")
        try await store.set("visible", forKey: "k")
        #expect(await persistence.stored["k"] == ConfigEntry(value: .string("visible"), isSecret: false))
    }

    @Test("With a real encryption, saved secrets are ciphertext and read back as plaintext")
    func encrypted() async throws {
        let persistence = RecordingPersistence()
        let encryption = MockEncryption()
        let store = try await ConfigStore(
            persistence: persistence, scope: "s", encryption: encryption, environmentProvider: nil)
        try await store.setSecret("s3cret", forKey: "token")
        let saved = try #require(await persistence.saves.last?["token"])
        guard case .string(let stored) = saved.value else {
            Issue.record("not a string")
            return
        }
        #expect(saved.isSecret)
        #expect(stored != "s3cret" && encryption.isEncrypted(stored))
        #expect(store.secret(forKey: "token") == "s3cret")

        let reopened = try await ConfigStore(
            persistence: persistence, scope: "s", encryption: encryption, environmentProvider: nil)
        #expect(reopened.secret(forKey: "token") == "s3cret")
    }

    @Test("Ints stay ints, bools stay bools, doubles stay doubles")
    func scalarsExact() async throws {
        let persistence = RecordingPersistence()
        let store = try await ConfigStore(
            persistence: persistence, scope: "s", encryption: .passthrough, environmentProvider: nil)
        try await store.set(1, forKey: "one")
        try await store.set(0, forKey: "zero")
        try await store.set(true, forKey: "yes")
        try await store.set(1.0, forKey: "unit")
        let last = try #require(await persistence.saves.last)
        #expect(last["one"]?.value == .int(1))
        #expect(last["zero"]?.value == .int(0))
        #expect(last["yes"]?.value == .bool(true))
        #expect(last["unit"]?.value == .double(1.0))
    }

    @Test("remove drops the key from the saved document and from reads")
    func removes() async throws {
        let persistence = RecordingPersistence([
            "a": ConfigEntry(value: .bool(true), isSecret: false),
            "b": ConfigEntry(value: .string("stay"), isSecret: false),
        ])
        let store = try await ConfigStore(
            persistence: persistence, scope: "s", encryption: .passthrough, environmentProvider: nil)
        try await store.remove(key: "a")
        #expect(await persistence.stored == ["b": ConfigEntry(value: .string("stay"), isSecret: false)])
        #expect(store.reader.bool(forKey: "a") == nil)
        #expect(await store.keys(withPrefix: "") == ["b"])
    }

    @Test("A failed set leaves memory unchanged and throws")
    func failedSave() async throws {
        let store = try await ConfigStore(
            persistence: FailingPersistence(), scope: "s", encryption: .passthrough, environmentProvider: nil)
        await #expect(throws: Boom.self) { try await store.set("x", forKey: "k") }
        #expect(store.reader.string(forKey: "k") == nil)
        #expect(await store.keys(withPrefix: "").isEmpty)
    }

    @Test("A failed remove leaves the key readable and throws")
    func failedRemove() async throws {
        let persistence = FailingPersistence(["k": ConfigEntry(value: .string("v"), isSecret: false)])
        let store = try await ConfigStore(
            persistence: persistence, scope: "s", encryption: .passthrough, environmentProvider: nil)
        await #expect(throws: Boom.self) { try await store.remove(key: "k") }
        #expect(store.reader.string(forKey: "k") == "v")
    }

    @Test("A failed save doesn't leak into the next successful save")
    func failureThenSuccess() async throws {
        let persistence = FailingPersistence(allowed: 1)
        let store = try await ConfigStore(
            persistence: persistence, scope: "s", encryption: .passthrough, environmentProvider: nil)
        try await store.set("first", forKey: "a")
        await #expect(throws: Boom.self) { try await store.set("lost", forKey: "b") }
        #expect(await persistence.stored == ["a": ConfigEntry(value: .string("first"), isSecret: false)])
    }

    @Test("Concurrent writes are all saved and agree with reads")
    func concurrentWrites() async throws {
        let persistence = RecordingPersistence(yieldsOnSave: true)
        let store = try await ConfigStore(
            persistence: persistence, scope: "s", encryption: .passthrough, environmentProvider: nil)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { try await store.set(index, forKey: "key\(index)") }
            }
            try await group.waitForAll()
        }
        let stored = await persistence.stored
        #expect(stored.count == 20)
        for index in 0..<20 {
            #expect(stored["key\(index)"]?.value == .int(index))
            #expect(store.reader.int(forKey: ConfigKey("key\(index)")) == index)
        }
    }

    @Test("reload picks up external changes, drops removed keys, keeps secret flags")
    func reloads() async throws {
        let persistence = RecordingPersistence([
            "old": ConfigEntry(value: .string("gone soon"), isSecret: false),
            "mode": ConfigEntry(value: .string("off"), isSecret: false),
        ])
        let store = try await ConfigStore(
            persistence: persistence, scope: "s", encryption: .passthrough, environmentProvider: nil)
        await persistence.replaceExternally([
            "mode": ConfigEntry(value: .string("on"), isSecret: false),
            "token": ConfigEntry(value: .string("plain"), isSecret: true),
        ])
        try await store.reload()
        #expect(store.reader.string(forKey: "old") == nil)
        #expect(store.reader.string(forKey: "mode") == "on")
        #expect(store.secret(forKey: "token") == "plain")
        #expect(await store.keys(withPrefix: "") == ["mode", "token"])

        // The next save starts from the reloaded document.
        try await store.set("x", forKey: "new")
        let last = try #require(await persistence.saves.last)
        #expect(Set(last.keys) == ["mode", "token", "new"])
        #expect(last["token"]?.isSecret == true)
    }

    @Test("Scoped stores write flat dotted keys and list in their own namespace")
    func scoped() async throws {
        let persistence = RecordingPersistence()
        let store = try await ConfigStore(
            persistence: persistence, scope: "agent", encryption: .passthrough, environmentProvider: nil)
        let bridge = store.scoped(to: "bridge")
        try await bridge.set("10.0.0.9", forKey: "ip")
        try await bridge.setSecret("k", forKey: "appKey")
        #expect(await persistence.stored["bridge.ip"] == ConfigEntry(value: .string("10.0.0.9"), isSecret: false))
        #expect(await persistence.stored["bridge.appKey"]?.isSecret == true)
        #expect(bridge.reader.string(forKey: "ip") == "10.0.0.9")
        #expect(store.reader.string(forKey: "bridge.ip") == "10.0.0.9")
        #expect(await bridge.keys(withPrefix: "") == ["appKey", "ip"])
    }

    @Test("A persistence-backed store has no file path")
    func noFilePath() async throws {
        let store = try await ConfigStore(
            persistence: RecordingPersistence(), scope: "s", encryption: .passthrough, environmentProvider: nil)
        #expect(store.filePath.isEmpty)
    }

    @Test("ConfigEntry round-trips through Codable")
    func codable() throws {
        let entries: [String: ConfigEntry] = [
            "s": ConfigEntry(value: .string("v"), isSecret: true),
            "i": ConfigEntry(value: .int(3), isSecret: false),
            "d": ConfigEntry(value: .double(2.5), isSecret: false),
            "b": ConfigEntry(value: .bool(false), isSecret: false),
        ]
        let data = try JSONEncoder().encode(entries)
        #expect(try JSONDecoder().decode([String: ConfigEntry].self, from: data) == entries)
    }
}
