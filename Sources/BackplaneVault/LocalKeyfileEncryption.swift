//
//  LocalKeyfileEncryption.swift
//  swift-backplane
//

#if BACKPLANE_VAULT_KEYFILE

import Crypto
import Foundation

/// AES-256-GCM encryption backed by a machine-local keyfile.
///
/// On first use, generates a fresh 256-bit symmetric key and writes
/// it to `keyPath` with `0o600` permissions (owner read+write only).
/// Subsequent constructions read the existing key.
///
/// Encrypted-value format: `"backplane-vault:v1:<base64-combined-sealed-box>"`,
/// where the combined sealed box is `nonce || ciphertext || tag` produced
/// by `AES.GCM.seal(_:using:)`.
///
/// Available behind the `KeyfileEncryption` package trait, which pulls
/// `swift-crypto` as a dependency.
public struct LocalKeyfileEncryption: ConfigEncryption, Sendable {

    /// Prefix marking encrypted values. Versioned so future format
    /// migrations are non-breaking — `isEncrypted(_:)` recognises any
    /// `backplane-vault:vN:` prefix; `decrypt(_:)` dispatches on the
    /// version.
    public static let prefix = "backplane-vault:v1:"

    private let symmetricKey: SymmetricKey

    // MARK: - Initialization

    /// Construct backed by a machine-local keyfile.
    ///
    /// If the keyfile does not exist, a new 256-bit AES key is generated
    /// and written with permissions `0o600` (owner read+write only).
    /// If persisting the keyfile fails, `init` throws — the constructor
    /// does **not** silently fall back to in-process-only operation.
    /// Surfacing the failure here means a misconfigured deployment is
    /// detected at construction rather than losing encrypted data on
    /// the next restart.
    ///
    /// - Parameter keyPath: Absolute path to the encryption keyfile.
    /// - Throws: If the keyfile exists but is malformed, if the parent
    ///   directory cannot be created, or if the keyfile cannot be
    ///   persisted to disk.
    public init(keyPath: String) throws {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: keyPath)

        if fileManager.fileExists(atPath: keyPath) {
            let keyData = try Data(contentsOf: url)
            guard keyData.count == 32 else {
                throw LocalKeyfileEncryptionError.invalidKeyFile(
                    "Expected 32 bytes, got \(keyData.count)"
                )
            }
            self.symmetricKey = SymmetricKey(data: keyData)
            return
        }

        // Auto-generate a new 256-bit key.
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        // Create parent directory if needed.
        let directory = url.deletingLastPathComponent().path
        if !fileManager.fileExists(atPath: directory) {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
        }

        // Write with restrictive permissions (owner read/write only).
        // Unlike the Acumen origin code, we throw on persist failure
        // rather than silently degrading to in-process-only operation —
        // a misconfigured deployment is better surfaced at construction
        // than discovered after a restart loses encrypted state.
        let created = fileManager.createFile(
            atPath: keyPath,
            contents: keyData,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw LocalKeyfileEncryptionError.keyfilePersistFailed(
                "Could not write keyfile to \(keyPath)"
            )
        }

        // Defensive: re-apply restrictive permissions in case the
        // creation umask altered them.
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyPath
        )

        self.symmetricKey = key
    }

    /// Test-only constructor with an explicit `SymmetricKey`. No keyfile
    /// is read or written.
    package init(key: SymmetricKey) {
        self.symmetricKey = key
    }

    // MARK: - ConfigEncryption

    public func encrypt(_ plaintext: String) throws -> String {
        let data = Data(plaintext.utf8)
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        guard let combined = sealedBox.combined else {
            throw LocalKeyfileEncryptionError.encryptionFailed(
                "AES.GCM.seal produced no combined sealed box"
            )
        }
        return "\(Self.prefix)\(combined.base64EncodedString())"
    }

    public func decrypt(_ ciphertext: String) throws -> String? {
        guard isEncrypted(ciphertext) else { return nil }

        let base64 = String(ciphertext.dropFirst(Self.prefix.count))
        guard let combined = Data(base64Encoded: base64) else {
            throw LocalKeyfileEncryptionError.decryptionFailed("Invalid base64 data")
        }
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey)
        guard let plaintext = String(data: decrypted, encoding: .utf8) else {
            throw LocalKeyfileEncryptionError.decryptionFailed("Decrypted data is not valid UTF-8")
        }
        return plaintext
    }

    public func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(Self.prefix)
    }
}

// MARK: - Errors

/// Errors thrown by ``LocalKeyfileEncryption``.
public enum LocalKeyfileEncryptionError: Error, CustomStringConvertible {
    case invalidKeyFile(String)
    case keyfilePersistFailed(String)
    case encryptionFailed(String)
    case decryptionFailed(String)

    public var description: String {
        switch self {
        case .invalidKeyFile(let message): "Invalid key file: \(message)"
        case .keyfilePersistFailed(let message): "Keyfile persist failed: \(message)"
        case .encryptionFailed(let message): "Encryption failed: \(message)"
        case .decryptionFailed(let message): "Decryption failed: \(message)"
        }
    }
}

#endif
