//
//  ConfigWriterTests.swift
//  swift-backplane
//

import Testing
import Foundation
import BackplaneVault

@Suite("ConfigWriter")
struct ConfigWriterTests {
    /// Create a temporary directory for test files. Caller must clean up.
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("backplane-vault-config-writer-test-\(UUID().uuidString)")
    }

    @Test("Read missing file returns empty dictionary")
    func readMissingFile() throws {
        let result = try ConfigWriter.read(filePath: "/tmp/nonexistent-\(UUID()).json")
        #expect(result.isEmpty)
    }

    @Test("Write and read flat keys roundtrip")
    func writeReadFlat() throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let values: [String: Any] = ["name": "test", "count": 42, "enabled": true]
        try ConfigWriter.write(values, to: path)

        let loaded = try ConfigWriter.read(filePath: path)
        #expect(loaded["name"] as? String == "test")
        #expect(loaded["count"] as? Int == 42)
        #expect(loaded["enabled"] as? Bool == true)
    }

    @Test("Write and read nested keys via dot notation")
    func writeReadNested() throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let values: [String: Any] = ["bridge.ip": "192.168.1.10", "bridge.port": 443]
        try ConfigWriter.write(values, to: path)

        let loaded = try ConfigWriter.read(filePath: path)
        #expect(loaded["bridge.ip"] as? String == "192.168.1.10")
        #expect(loaded["bridge.port"] as? Int == 443)
    }

    @Test("Merge adds a key to existing file")
    func mergeKey() throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try ConfigWriter.write(["existing": "value"], to: path)
        try ConfigWriter.merge(key: "new", value: "added", filePath: path)

        let loaded = try ConfigWriter.read(filePath: path)
        #expect(loaded["existing"] as? String == "value")
        #expect(loaded["new"] as? String == "added")
    }

    @Test("Merge with nil removes a key")
    func mergeRemove() throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try ConfigWriter.write(["keep": "yes", "remove": "me"], to: path)
        try ConfigWriter.merge(key: "remove", value: nil, filePath: path)

        let loaded = try ConfigWriter.read(filePath: path)
        #expect(loaded["keep"] as? String == "yes")
        #expect(loaded["remove"] == nil)
    }

    @Test("Read rejects non-object JSON root")
    func rejectNonObjectRoot() throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try Data("[1,2,3]".utf8).write(to: URL(fileURLWithPath: path))

        #expect(throws: ConfigWriterError.self) {
            try ConfigWriter.read(filePath: path)
        }
    }

    @Test("Write creates parent directories")
    func createsParentDirs() throws {
        let tmpDir = makeTempDir()
        let nested = tmpDir.appendingPathComponent("a/b/c").path
        let path = "\(nested)/config.json"
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try ConfigWriter.write(["key": "value"], to: path)

        let loaded = try ConfigWriter.read(filePath: path)
        #expect(loaded["key"] as? String == "value")
    }

    @Test("Written file has 0o600 permissions")
    func writePermissions() throws {
        let tmpDir = makeTempDir()
        let path = tmpDir.appendingPathComponent("config.json").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try ConfigWriter.write(["key": "value"], to: path)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600,
                "config file should be 0o600; got \(String(describing: perms?.intValue))")
    }
}
