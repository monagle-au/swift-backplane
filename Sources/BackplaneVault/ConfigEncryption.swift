//
//  ConfigEncryption.swift
//  swift-backplane
//

/// Protocol abstracting encryption/decryption for configuration values.
///
/// Conformers provide the ability to encrypt strings, decrypt strings,
/// and check whether a string is in encrypted format. This allows
/// ``ConfigStore`` and ``DecryptingConfigProvider`` to work with any
/// encryption backend without depending on a specific cryptographic library.
///
/// BackplaneVault never reads or writes the encryption key directly;
/// key management lives inside the conformer. Implementations may load
/// from a keyfile (``LocalKeyfileEncryption``), a cloud KMS, an HSM,
/// or a hardware-bound store.
public protocol ConfigEncryption: Sendable {
    /// Encrypt a plaintext string.
    ///
    /// Returns a string in an implementation-defined format that can be
    /// recognized by ``isEncrypted(_:)`` and reversed by ``decrypt(_:)``.
    ///
    /// - Parameter plaintext: The string to encrypt.
    /// - Returns: The encrypted string.
    /// - Throws: If encryption fails.
    func encrypt(_ plaintext: String) throws -> String

    /// Decrypt an encrypted string.
    ///
    /// Returns `nil` if the string is not in the recognized encrypted format.
    /// Lets a ``DecryptingConfigProvider`` co-exist with mixed
    /// plaintext/ciphertext values during migration.
    ///
    /// - Parameter ciphertext: The encrypted string to decrypt.
    /// - Returns: The decrypted plaintext, or `nil` if not recognized.
    /// - Throws: If the format is recognized but decryption fails
    ///   (key mismatch, tampering, version skew).
    func decrypt(_ ciphertext: String) throws -> String?

    /// Check whether a string is in the encrypted format. Cheap and
    /// non-throwing — typically a string-prefix check.
    ///
    /// - Parameter value: The string to check.
    /// - Returns: `true` if the string appears to be encrypted.
    func isEncrypted(_ value: String) -> Bool
}

extension ConfigEncryption where Self == PassthroughEncryption {
    /// A no-op encryption that passes values through unchanged.
    public static var passthrough: PassthroughEncryption { PassthroughEncryption() }
}
