// ConfigStoreKeyEnumerationTests.swift
// Copyright 2026 Monagle Pty Ltd

import Configuration
import Foundation
import Testing

@testable import BackplaneVault

/// Listing the keys a store actually holds.
///
/// Without this, callers that need to know *which* records exist keep a second
/// index alongside the records and maintain it by hand. Two Acumen integrations
/// do exactly that today, and both write the record's fields first and the
/// index entry last — so a throw or a crash in between leaves data on disk that
/// nothing can see. Enumeration removes the reason for the index to exist.
@Suite("ConfigStore key enumeration")
struct ConfigStoreKeyEnumerationTests {

    private let encryption = MockEncryption()

    private func makeStore(scope: String = "test") throws -> (ConfigStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backplane-keys-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try ConfigStore(
            filePath: dir.appendingPathComponent("config.json").path,
            scope: scope,
            encryption: encryption,
            environmentProvider: nil
        )
        return (store, dir)
    }

    @Test("Keys written under a prefix come back")
    func returnsKeysUnderPrefix() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.set("a", forKey: "device.one.name")
        try await store.set("b", forKey: "device.two.name")

        let keys = await store.keys(withPrefix: "device.")

        #expect(Set(keys) == ["device.one.name", "device.two.name"])
    }

    @Test("Keys outside the prefix are not returned")
    func excludesKeysOutsidePrefix() async throws {
        // The store holds an agent's whole configuration, not just its records
        // — a bridge IP, an app key. Enumerating records must not sweep those up.
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.set("a", forKey: "device.one.name")
        try await store.set("192.168.1.1", forKey: "bridgeIP")

        let keys = await store.keys(withPrefix: "device.")

        #expect(keys == ["device.one.name"])
    }

    @Test("A removed key stops being listed")
    func removedKeysDisappear() async throws {
        // The whole point: the listing follows the data rather than a parallel
        // index that has to be kept in step with it.
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.set("a", forKey: "device.one.name")
        try await store.set("b", forKey: "device.two.name")

        try await store.remove(key: "device.one.name")

        #expect(await store.keys(withPrefix: "device.") == ["device.two.name"])
    }

    @Test("A scoped store lists keys in its own namespace, not the file's")
    func scopedStoreStripsItsScope() async throws {
        // `set` and `remove` take unscoped keys, so enumeration must too —
        // otherwise a caller gets back keys it cannot pass to either.
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scoped = store.scoped(to: "shelly")
        try await scoped.set("a", forKey: "device.one.name")

        let keys = await scoped.keys(withPrefix: "device.")

        #expect(keys == ["device.one.name"])
    }

    @Test("A store with nothing under the prefix returns empty, not everything")
    func emptyResultForUnknownPrefix() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.set("a", forKey: "bridgeIP")

        #expect(await store.keys(withPrefix: "device.").isEmpty)
    }
}
