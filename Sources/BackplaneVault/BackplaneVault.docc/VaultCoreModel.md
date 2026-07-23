# Vault Core Model

How ConfigStore, ConfigEncryption, and DecryptingConfigProvider
compose into a writable, secret-aware configuration surface.

## Overview

Three distinct concerns travel together in writable configuration:

1. **Writable config** — read + write + persist a structured
   configuration tree.
2. **Encryption** — protect a subset of fields (those marked
   secret) at rest.
3. **Layered reads** — env-var override, in-memory provider, file
   provider, with conventional precedence.

Layered reads is already swift-configuration's job;
`BackplaneVault` reuses `ConfigReader` and `ConfigProvider`
directly. Writable config is the new spine. Encryption is a
cross-cutting concern that hooks into the write path (encrypt
secrets before persistence) and the read path (decrypt secrets
transparently before they reach consumers). The concerns are
bundled because the consumers who need any one of them typically
need all three — the common case is "write a secret that survives
restart, readable back through the normal `ConfigReader`".

## The five types

### ConfigEncryption — the protocol

``ConfigEncryption`` abstracts encryption behind three
requirements: encrypt a plaintext string, decrypt a recognised
ciphertext (returning `nil` for unrecognised input), and cheaply
recognise the encrypted format. The format must be
self-identifying — ``ConfigEncryption/isEncrypted(_:)`` returns
`true` for values produced by ``ConfigEncryption/encrypt(_:)`` and
`false` otherwise — so that ``DecryptingConfigProvider`` can decide
whether to invoke ``ConfigEncryption/decrypt(_:)`` on read.

`BackplaneVault` never reads or writes the encryption key
directly; key management lives inside the conformer. The protocol
stays free of crypto-library dependencies so consumers can bring
their own backend — a keyfile, a cloud KMS, an HSM, or a
hardware-bound store — without taking on `swift-crypto` or a
vendor SDK. See <doc:EncryptionBackends>.

### ConfigStore — the consumer surface

``ConfigStore`` is the consumer-facing read + write API. It is a
`Sendable` value type, cheap to copy, backed by an actor
(``ConfigStoreBackend``) that owns the file and the in-memory
state:

```swift
let store = try ConfigStore(
    filePath: "/var/lib/myapp/config.json",
    scope: "myapp",
    encryption: encryption
)

let host = store.reader.string(forKey: "bridgeIP")   // sync read
try await store.set("192.168.1.10", forKey: "bridgeIP")
try await store.setSecret("api-key-value", forKey: "appKey")
```

Reads are synchronous — they hit a thread-safe in-memory provider.
Writes are `async` — each one is serialised by the backend actor
and persisted through a locked, atomic file write. The full read
and write semantics, including the cross-process concurrency
guarantee, are covered in <doc:ReadingAndWriting>.

For tests and ephemeral state,
``ConfigStore/inMemory(values:encryption:)`` builds a store with
no file backing.

### DecryptingConfigProvider — the adapter

``DecryptingConfigProvider`` is the bridge into
swift-configuration's provider chain. It wraps any upstream
`ConfigProvider` and transparently decrypts values flagged
`isSecret` before returning them, passing non-secret values
through unchanged. The full provider behaviour — watching,
snapshots, async fetches — is preserved.

The point of the interposition is that plaintext stays
*ephemeral*: the encrypted form is what persists in the in-memory
provider and on disk, and decrypted values exist only briefly on
the stack of a read.

### PassthroughEncryption — the no-op

``PassthroughEncryption`` returns values unchanged and never
recognises anything as encrypted. It is the default for
``ConfigStore/inMemory(values:encryption:)`` (via the
``ConfigEncryption/passthrough`` convenience) and the right choice
for unit tests and genuinely non-secret writable state, where
encryption would be ceremony without benefit.

### LocalKeyfileEncryption — the reference implementation

``LocalKeyfileEncryption`` is AES-256-GCM against a
machine-local keyfile, available behind the `KeyfileEncryption`
package trait. It exists so single-binary deployments get working
encryption-at-rest without writing crypto code. See
<doc:EncryptionBackends> for its operational characteristics.

## Choosing your dependency surface

| Consumer shape | Trait | What you use |
| --- | --- | --- |
| Cloud microservice with managed secrets | — | Typically doesn't import `BackplaneVault` at all. |
| Tests / non-secret writable state | none | ``ConfigStore/inMemory(values:encryption:)`` + ``PassthroughEncryption``. No `swift-crypto` dependency. |
| Pi / NAS / on-prem single binary | `KeyfileEncryption` | ``LocalKeyfileEncryption`` — AES-256-GCM, keyfile-managed. |
| Cloud with KMS-backed secrets | none | Your own `ConfigEncryption` conformer against your cloud SDK. |

`BackplaneVault` has no dependency on the `Backplane` library. A
consumer using only `ConfigStore` against bare swift-configuration
gets the writable-config story without importing the service graph
at all.
