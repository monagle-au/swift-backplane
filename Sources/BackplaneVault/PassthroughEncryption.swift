//
//  PassthroughEncryption.swift
//  swift-backplane
//

/// A no-op encryption implementation that passes values through unchanged.
///
/// Useful for testing and for ``ConfigStore/inMemory(values:encryption:)``
/// where real encryption is not needed. ``isEncrypted(_:)`` always returns
/// `false`, so ``DecryptingConfigProvider`` will never attempt decryption.
public struct PassthroughEncryption: ConfigEncryption, Sendable {
    public init() {}

    public func encrypt(_ plaintext: String) throws -> String {
        plaintext
    }

    public func decrypt(_ ciphertext: String) throws -> String? {
        ciphertext
    }

    public func isEncrypted(_ value: String) -> Bool {
        false
    }
}
