//
//  MockEncryption.swift
//  swift-backplane
//

import BackplaneVault

/// A mock encryption implementation that uses a prefix to identify encrypted values.
///
/// Useful for testing that encryption is called without depending on real cryptography.
/// Encrypted values have the format `"mock-encrypted:{plaintext}"`.
struct MockEncryption: ConfigEncryption {
    static let prefix = "mock-encrypted:"

    func encrypt(_ plaintext: String) throws -> String {
        "\(Self.prefix)\(plaintext)"
    }

    func decrypt(_ ciphertext: String) throws -> String? {
        guard isEncrypted(ciphertext) else { return nil }
        return String(ciphertext.dropFirst(Self.prefix.count))
    }

    func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(Self.prefix)
    }
}
