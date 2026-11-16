//
//  ConfigPersistence.swift
//  swift-backplane
//

/// A scalar config value as a ``ConfigPersistence`` stores it.
public enum ConfigScalar: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

/// One config value as a ``ConfigStore`` keeps it, and whether it is a secret.
///
/// A secret's value is exactly what the store holds: ciphertext under a real
/// ``ConfigEncryption`` (``ConfigStore/setSecret(_:forKey:)`` encrypts before
/// the value reaches the persistence), or plaintext under `.passthrough`.
public struct ConfigEntry: Sendable, Equatable, Codable {
    public var value: ConfigScalar
    public var isSecret: Bool

    public init(value: ConfigScalar, isSecret: Bool) {
        self.value = value
        self.isSecret = isSecret
    }
}

/// Where a ``ConfigStore`` keeps its document when it isn't a local JSON file:
/// a database, a secrets manager, or a remote owner of the configuration.
///
/// Keys are flat and dot-separated, the same keys ``ConfigWriter/read(filePath:)``
/// returns for a file. Secrets are flagged with ``ConfigEntry/isSecret``, rather
/// than detected by ciphertext as the file-backed store does, so a persistence
/// can hold plaintext secrets when it encrypts at rest itself.
///
/// ``save(_:)`` receives the **whole document** every time. Unlike the file-backed
/// store, which merges each write into a fresh read of the file under a lock,
/// nothing is merged with other writers: the store assumes it is the only writer
/// of its document. A store serialises its own saves, never has more than one in
/// flight, and changes its in-memory state only after a save succeeds — so a
/// throwing save leaves both the store and (as far as the store knows) the
/// persistence as they were.
public protocol ConfigPersistence: Sendable {
    /// The stored document, or an empty one if nothing has been saved.
    func load() async throws -> [String: ConfigEntry]

    /// Replace the stored document with `entries`.
    func save(_ entries: [String: ConfigEntry]) async throws
}
