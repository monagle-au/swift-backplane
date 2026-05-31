//
//  LocalKeyfileEncryptionTests.swift
//  swift-backplane
//

#if BACKPLANE_VAULT_KEYFILE

import Testing
import Foundation
import Crypto
import BackplaneVault

@Suite("LocalKeyfileEncryption")
struct LocalKeyfileEncryptionTests {
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("backplane-vault-keyfile-test-\(UUID().uuidString)")
    }

    // MARK: - Round-trip

    @Test("encrypt then decrypt round-trips")
    func roundTrip() throws {
        let enc = LocalKeyfileEncryption(key: SymmetricKey(size: .bits256))
        let ciphertext = try enc.encrypt("hello world")
        let plaintext = try enc.decrypt(ciphertext)
        #expect(plaintext == "hello world")
    }

    @Test("encrypt produces a backplane-vault:v1: prefix")
    func encryptedPrefix() throws {
        let enc = LocalKeyfileEncryption(key: SymmetricKey(size: .bits256))
        let ciphertext = try enc.encrypt("payload")
        #expect(ciphertext.hasPrefix("backplane-vault:v1:"))
        #expect(enc.isEncrypted(ciphertext))
    }

    @Test("isEncrypted is false for plaintext")
    func notEncrypted() {
        let enc = LocalKeyfileEncryption(key: SymmetricKey(size: .bits256))
        #expect(!enc.isEncrypted("hello"))
        #expect(!enc.isEncrypted(""))
        #expect(!enc.isEncrypted("encrypted:v1:foo"))  // Acumen's old prefix
    }

    @Test("decrypt returns nil for unrecognised format")
    func decryptUnrecognised() throws {
        let enc = LocalKeyfileEncryption(key: SymmetricKey(size: .bits256))
        #expect(try enc.decrypt("plain string") == nil)
        #expect(try enc.decrypt("") == nil)
    }

    @Test("encrypt uses a fresh nonce per call (ciphertexts differ)")
    func freshNoncePerCall() throws {
        let enc = LocalKeyfileEncryption(key: SymmetricKey(size: .bits256))
        let a = try enc.encrypt("same plaintext")
        let b = try enc.encrypt("same plaintext")
        #expect(a != b, "AES-GCM ciphertexts for the same plaintext must differ (fresh nonce)")
        // Both round-trip back to the same plaintext.
        #expect(try enc.decrypt(a) == "same plaintext")
        #expect(try enc.decrypt(b) == "same plaintext")
    }

    @Test("decrypt with a different key throws")
    func wrongKeyThrows() throws {
        let enc1 = LocalKeyfileEncryption(key: SymmetricKey(size: .bits256))
        let enc2 = LocalKeyfileEncryption(key: SymmetricKey(size: .bits256))
        let ciphertext = try enc1.encrypt("secret")
        #expect(throws: (any Error).self) {
            _ = try enc2.decrypt(ciphertext)
        }
    }

    // MARK: - Keyfile

    @Test("init creates a keyfile if absent, with 0o600 permissions")
    func keyfileCreatedWithRestrictivePermissions() throws {
        let tmpDir = makeTempDir()
        let keyPath = tmpDir.appendingPathComponent(".vault-key").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try LocalKeyfileEncryption(keyPath: keyPath)
        #expect(FileManager.default.fileExists(atPath: keyPath))

        let attrs = try FileManager.default.attributesOfItem(atPath: keyPath)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600,
                "keyfile should be 0o600; got \(String(describing: perms?.intValue))")
    }

    @Test("init reads existing keyfile")
    func keyfileReused() throws {
        let tmpDir = makeTempDir()
        let keyPath = tmpDir.appendingPathComponent(".vault-key").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let enc1 = try LocalKeyfileEncryption(keyPath: keyPath)
        let ciphertext = try enc1.encrypt("hello")

        // Second instance reads the existing keyfile.
        let enc2 = try LocalKeyfileEncryption(keyPath: keyPath)
        #expect(try enc2.decrypt(ciphertext) == "hello",
                "second instance should decrypt with the same persisted key")
    }

    @Test("init throws on malformed keyfile")
    func malformedKeyfileThrows() throws {
        let tmpDir = makeTempDir()
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let keyPath = tmpDir.appendingPathComponent(".vault-key").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write a key of the wrong length.
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: keyPath))

        #expect(throws: LocalKeyfileEncryptionError.self) {
            _ = try LocalKeyfileEncryption(keyPath: keyPath)
        }
    }

    @Test("init creates parent directory")
    func keyfileCreatesParentDirectory() throws {
        let tmpDir = makeTempDir()
        let keyPath = tmpDir.appendingPathComponent("nested/dir/.vault-key").path
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try LocalKeyfileEncryption(keyPath: keyPath)
        #expect(FileManager.default.fileExists(atPath: keyPath))
    }
}

#endif
