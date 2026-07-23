# Encryption Backends

The two shipped ConfigEncryption implementations, and how to bring
your own.

## Overview

``ConfigEncryption`` is the only contract between a
``ConfigStore`` and its encryption: encrypt is a function, decrypt
is its partial inverse, and `isEncrypted` is a cheap recogniser.
The protocol does not dictate symmetric vs envelope encryption,
local vs remote keys, or file-backed vs HSM key storage — those
choices live entirely inside the conformer.

## PassthroughEncryption

``PassthroughEncryption`` is a no-op: values pass through
unchanged, and ``PassthroughEncryption/isEncrypted(_:)`` always
returns `false`, so ``DecryptingConfigProvider`` never attempts
decryption. Use it for:

- **Unit tests** that exercise the store API but don't care about
  ciphertext.
- **Genuinely non-secret state** (timestamps, learned preferences,
  cache snapshots) where a writable JSON store is the point and
  encryption would add nothing.

In-memory stores default to it via the
``ConfigEncryption/passthrough`` convenience. A file-backed store
constructed with passthrough is simply a writable JSON store with
no encryption.

## LocalKeyfileEncryption

``LocalKeyfileEncryption`` is the trait-gated reference
implementation: AES-256-GCM against a machine-local keyfile.
Enable the `KeyfileEncryption` package trait to build it — the
trait pulls `swift-crypto`, and consumers who don't enable it pay
nothing.

```swift
let encryption = try LocalKeyfileEncryption(
    keyPath: "/var/lib/myapp/.vault-key"
)
let store = try ConfigStore(
    filePath: "/var/lib/myapp/config.json",
    scope: "myapp",
    encryption: encryption
)
```

Operational characteristics:

- On first use, ``LocalKeyfileEncryption/init(keyPath:)``
  generates a fresh 256-bit key and writes it to `keyPath` with
  `0o600` permissions; subsequent constructions read the existing
  key.
- The initialiser **throws** if the keyfile cannot be persisted —
  it never falls back silently to in-process-only operation, so a
  misconfigured deployment is caught at construction rather than
  by losing encrypted data on the next restart.
- Encrypted values are
  `"backplane-vault:v1:<base64(nonce || ciphertext || tag)>"`,
  with a fresh nonce per encryption. The versioned prefix leaves
  room for future format migrations.
- Tampered ciphertext produces a thrown error on decryption, not
  silent corruption.
- Key rotation is not provided: rotating means re-encrypting every
  secret with a new key yourself.

## Bringing your own backend

Consumers with an existing secret-management story conform
``ConfigEncryption`` directly — typically well under a hundred
lines. A sketch of a KMS-backed conformer using envelope
encryption (each value encrypted with a unique data-encryption
key, itself wrapped by a remote key-management service):

```swift
/// Each value is encrypted with a per-value DEK, which is itself
/// wrapped with a remote KEK held by the KMS.
public struct KMSEncryption: ConfigEncryption {
    private let kms: any KMSClient
    public static let prefix = "kms:v1:"

    public func encrypt(_ plaintext: String) throws -> String {
        // Generate a DEK, encrypt the plaintext with it, wrap the
        // DEK via the KMS, and return prefix + base64(wrappedDEK || ciphertext).
    }

    public func decrypt(_ ciphertext: String) throws -> String? {
        guard isEncrypted(ciphertext) else { return nil }
        // Unwrap the DEK via the KMS, then decrypt.
    }

    public func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(Self.prefix)
    }
}
```

The contract to honour:

- The output format must be self-identifying, so `isEncrypted`
  can recognise it with a cheap, non-throwing check — typically a
  string-prefix test.
- `decrypt` returns `nil` for input that is not in your format,
  and throws only when the format *is* recognised but decryption
  fails (key mismatch, tampering, version skew).

## Co-existing backends during migration

Because `decrypt` returns `nil` for unrecognised formats, a single
store can hold values encrypted by different backends
simultaneously. A consumer rotating from
``LocalKeyfileEncryption`` to a KMS backend can ship a chained
conformer that tries the new backend first and falls back to the
old: each `setSecret` produces new-format ciphertext, while reads
transparently handle both formats for as long as the migration
takes.
