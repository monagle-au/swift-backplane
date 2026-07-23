# ``BackplaneVault``

Writable, encryption-aware configuration layered over
swift-configuration's read-only `ConfigReader`.

## Overview

`swift-configuration` provides read-only configuration: a
`ConfigReader` that layers environment variables, files, and
in-memory defaults. That is the right shape for cloud deployments
where config arrives via deployment substitution and secrets are
rotated externally. `BackplaneVault` serves the consumers that need
*writes* as well:

- **Single-binary deployments** (Raspberry Pi, NAS, on-prem, dev)
  where the running process is the configuration owner. State
  learned at runtime — OAuth tokens, learned device addresses,
  last-known-good credentials — must persist across restarts, and
  some of it is sensitive enough to encrypt at rest.
- **Embedded frameworks** whose integrations authenticate against
  external services and need a uniform "save this secret; load it
  back later; survive restart" API.
- **Operational tooling** (admin CLIs, setup wizards, recovery
  scripts) that writes the same config a long-running service
  reads, and must agree with it on file format, scoping, and
  encryption.

The surface is deliberately small: a ``ConfigStore`` that composes
swift-configuration's reader chain with async, atomically-persisted
writers; a ``ConfigEncryption`` protocol for backend-agnostic
secret handling; and a ``DecryptingConfigProvider`` that keeps
plaintext ephemeral by decrypting secrets only at the moment of a
read. Multiple stores may safely share one file — each write is a
locked read-merge-write under an advisory ``FileLock``, so
concurrent stores (across processes or within one) never lose each
other's keys.

Two encryption backends ship. ``PassthroughEncryption`` (a no-op)
is always available. ``LocalKeyfileEncryption`` (AES-256-GCM
against a machine-local keyfile) is gated behind the
`KeyfileEncryption` package trait, which pulls `swift-crypto`;
consumers who don't enable the trait pay nothing for it. Consumers
with their own secret-management story (KMS, HSM, Keychain)
conform ``ConfigEncryption`` directly.

`BackplaneVault` does not depend on the `Backplane` library — it
sits directly on `swift-configuration`, so it works in applications
that use no other part of this package.

## Topics

### Essentials

- <doc:VaultCoreModel>
- <doc:ReadingAndWriting>

### Guides

- <doc:EncryptionBackends>
- <doc:FileLocking>

### Store

- ``ConfigStore``
- ``ConfigStoreBackend``

### Encryption

- ``ConfigEncryption``
- ``PassthroughEncryption``
- ``LocalKeyfileEncryption``
- ``LocalKeyfileEncryptionError``

### Providers

- ``DecryptingConfigProvider``

### Persistence and locking

- ``ConfigWriter``
- ``ConfigWriterError``
- ``FileLock``
- ``FileLockError``
