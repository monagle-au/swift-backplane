//
//  DecryptingConfigProvider.swift
//  swift-backplane
//

import Configuration

/// A configuration provider that decrypts secret values on read.
///
/// Wraps an upstream provider and transparently decrypts any values marked
/// with `isSecret: true` before returning them. This allows secrets to remain
/// encrypted in the in-memory provider — plaintext values exist only briefly
/// during reads, providing better runtime protection.
///
/// Non-secret values pass through unchanged.
public struct DecryptingConfigProvider<Upstream: ConfigProvider>: Sendable {
    private let upstream: Upstream
    private let encryption: any ConfigEncryption

    public init(upstream: Upstream, encryption: any ConfigEncryption) {
        self.upstream = upstream
        self.encryption = encryption
    }

    // MARK: - Decryption

    /// Decrypt the value in a LookupResult if it is a secret encrypted string.
    private func decryptResult(_ result: LookupResult) -> LookupResult {
        guard let value = result.value, value.isSecret,
              case .string(let encrypted) = value.content,
              encryption.isEncrypted(encrypted),
              let decrypted = try? encryption.decrypt(encrypted)
        else {
            return result
        }
        var modified = result
        modified.value = ConfigValue(.string(decrypted), isSecret: true)
        return modified
    }
}

// MARK: - ConfigProvider

extension DecryptingConfigProvider: ConfigProvider {
    public var providerName: String {
        "Decrypting[\(upstream.providerName)]"
    }

    public func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
        decryptResult(try upstream.value(forKey: key, type: type))
    }

    public func fetchValue(forKey key: AbsoluteConfigKey, type: ConfigType) async throws -> LookupResult {
        decryptResult(try await upstream.fetchValue(forKey: key, type: type))
    }

    public func watchValue<Return: ~Copyable>(
        forKey key: AbsoluteConfigKey,
        type: ConfigType,
        updatesHandler: nonisolated(nonsending) (
            _ updates: ConfigUpdatesAsyncSequence<Result<LookupResult, any Error>, Never>
        ) async throws -> Return
    ) async throws -> Return {
        try await upstream.watchValue(forKey: key, type: type) { upstreamSequence in
            try await updatesHandler(
                ConfigUpdatesAsyncSequence(
                    upstreamSequence.map { result in
                        result.map { self.decryptResult($0) }
                    }
                )
            )
        }
    }

    public func snapshot() -> any ConfigSnapshot {
        DecryptingSnapshot(upstream: upstream.snapshot(), encryption: encryption)
    }

    public func watchSnapshot<Return: ~Copyable>(
        updatesHandler: nonisolated(nonsending) (_ updates: ConfigUpdatesAsyncSequence<any ConfigSnapshot, Never>) async throws -> Return
    ) async throws -> Return {
        try await upstream.watchSnapshot { upstreamSequence in
            try await updatesHandler(
                ConfigUpdatesAsyncSequence(
                    upstreamSequence.map { snapshot in
                        DecryptingSnapshot(upstream: snapshot, encryption: self.encryption)
                    }
                )
            )
        }
    }
}

// MARK: - Snapshot

/// A configuration snapshot that decrypts secret values on read.
private struct DecryptingSnapshot: ConfigSnapshot {
    let upstream: any ConfigSnapshot
    let encryption: any ConfigEncryption

    var providerName: String {
        "Decrypting[\(upstream.providerName)]"
    }

    func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
        let result = try upstream.value(forKey: key, type: type)
        guard let value = result.value, value.isSecret,
              case .string(let encrypted) = value.content,
              encryption.isEncrypted(encrypted),
              let decrypted = try? encryption.decrypt(encrypted)
        else {
            return result
        }
        var modified = result
        modified.value = ConfigValue(.string(decrypted), isSecret: true)
        return modified
    }
}
