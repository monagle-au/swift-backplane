# BackplaneVault: Writable, Encryption-Aware Configuration

> Design note for the `BackplaneVault` satellite target — a write
> path, secret-aware fields, and persistence layered over
> swift-configuration's read-only `ConfigReader`.

---

## 0. Framing

`swift-configuration` (Apple's SSWG-track config library) provides
read-only configuration: a `ConfigReader` that layers env vars, files,
and in-memory defaults, with a watchful `ConfigProvider` chain
underneath. It is excellent for cloud-microservice deployments where
config arrives via deployment substitution and is rotated externally.

There is a meaningful class of consumers that needs more than reads:

- **Single-binary deployments** (Raspberry Pi, NAS, on-prem, dev) where
  the running process *is* the configuration owner. State learned at
  runtime — OAuth tokens, learned device addresses, last-known-good
  credentials — must persist across restarts, and some of it is
  sensitive enough to encrypt at rest.
- **Embedded frameworks** like Acumen, where integrations
  authenticate against external services, complete OAuth flows, and
  store the resulting secrets locally. The framework needs a uniform
  API for "save this secret; load it back later; survive restart."
- **Operational tooling** (admin CLIs, setup wizards, recovery
  scripts) that needs to write the same config a long-running service
  reads. The two paths must agree on file format, scoping, and
  encryption.

These consumers map exactly onto deployment shapes (b) and (c) of
`backplane.md`'s §0 — the same shapes that benefit from the §7
restart-aware machinery. Shape (a) (stateless cloud microservice) gets
secrets from external secret stores at deploy time and doesn't import
`BackplaneVault` at all.

BackplaneVault is the writable-config satellite target. Its scope is
intentionally narrow: provide a `ConfigStore` API (read + write +
persist) layered on top of `swift-configuration`'s `ConfigReader`, with
a `ConfigEncryption` protocol for secret handling and a reference
implementation behind a trait gate.

---

## 1. Positioning

### Why a satellite target

The trait-gated satellite-target pattern already exists in
`swift-backplane` for `BackplanePostgres`, `BackplaneOTel`, `BackplaneGCP`,
and `BackplaneMetrics`. Each lives in its own target with its own
optional dependency, opt-in via a package trait. Consumers who don't
need the feature don't pay for it.

BackplaneVault follows the same pattern:

- The bare `Backplane` library has no transitive dependency on
  `BackplaneVault`.
- Consumers add `BackplaneVault` to their `Package.swift` if they want
  the writable-config surface.
- Within `BackplaneVault`, a `KeyfileEncryption` trait pulls
  `swift-crypto` and exposes a concrete `LocalKeyfileEncryption`
  implementation of `ConfigEncryption`. Without the trait, only the
  protocol and a `PassthroughEncryption` no-op are visible.

This keeps the dependency surface honest: a cloud-microservice
consumer that picks up `BackplaneVault` for non-secret writable state
doesn't pay for `swift-crypto`; a single-binary consumer that opts in
gets a working AES-256-GCM keyfile-managed backend without writing it
themselves.

### Why these layers

There are three distinct concerns travelling together:

1. **Writable config** — read + write + persist a structured
   configuration tree.
2. **Encryption** — protect a subset of fields (those marked secret)
   at rest.
3. **Layered reads** — env-var override, in-memory provider, file
   provider, with conventional precedence.

Layered reads is already swift-configuration's job; BackplaneVault
re-uses `ConfigReader` and `ConfigProvider` directly. Writable config
is the new spine. Encryption is a *cross-cutting* concern that hooks
into the write path (encrypt secrets before persistence) and the read
path (decrypt secrets transparently before they reach consumers).

These three concerns are separable in principle. They are bundled in
BackplaneVault for the same reason they are bundled in Acumen's
`PersistableEncryptableConfig`: the consumers who need any one of them
typically need all three, and splitting them creates a coordination
problem for the common case (write a secret that survives restart with
read-time access via the normal `ConfigReader`).

### Impact on existing Backplane consumers

None unless they opt in. The introduction of BackplaneVault leaves the
existing `ConfigReader` story unchanged for consumers that don't
import it. The Backplane `ServiceContext` gains an optional
`configStore: ConfigStore?` property (see §7 below) that is `nil` for
consumers without BackplaneVault.

---

## 2. Core model

Five concepts: **`ConfigEncryption`** (the protocol), **`ConfigStore`**
(the consumer-facing read+write surface), **`DecryptingConfigProvider`**
(the swift-configuration adapter that decrypts on read),
**`PassthroughEncryption`** (no-op default), and
**`LocalKeyfileEncryption`** (trait-gated AES-256-GCM reference
implementation).

### 2.1 `ConfigEncryption` — the protocol

```swift
/// Backend-agnostic encryption for configuration values.
///
/// A `ConfigEncryption` conformer encrypts plaintext strings into an
/// opaque, recognizable format and reverses the operation. The format
/// must be self-identifying — `isEncrypted(_:)` returns true for
/// values produced by `encrypt(_:)` and false otherwise — so that
/// ``DecryptingConfigProvider`` can decide whether to invoke
/// `decrypt(_:)` on read.
///
/// BackplaneVault never reads or writes the encryption key directly;
/// key management lives inside the conformer. Implementations may
/// load from a keyfile, a cloud KMS, an HSM, or a hardware-bound
/// store. The protocol stays free of crypto-library dependencies so
/// consumers can bring their own backend without taking on
/// swift-crypto / libsodium / a vendor SDK.
public protocol ConfigEncryption: Sendable {
    /// Encrypt plaintext. The result is an implementation-defined
    /// string in a format that ``isEncrypted(_:)`` recognises.
    /// Throws if the underlying crypto operation fails or if the
    /// implementation's key material is unavailable.
    func encrypt(_ plaintext: String) throws -> String

    /// Decrypt a previously-encrypted string. Returns nil if the
    /// input is not in this implementation's recognised format
    /// (lets a `DecryptingConfigProvider` co-exist with mixed
    /// plaintext/ciphertext values during migration). Throws if the
    /// format is recognised but decryption fails (key mismatch,
    /// tampering, version skew).
    func decrypt(_ ciphertext: String) throws -> String?

    /// Recognise the format. Cheap and non-throwing — typically a
    /// string-prefix check.
    func isEncrypted(_ value: String) -> Bool
}

extension ConfigEncryption where Self == PassthroughEncryption {
    /// A no-op encryption that passes values through unchanged.
    public static var passthrough: PassthroughEncryption {
        PassthroughEncryption()
    }
}
```

This is lifted directly from Acumen's `PersistableEncryptableConfig`.
The shape is the right one: minimal surface, self-identifying format,
no library coupling. Consumers conform on their own backend in 50
lines (and a stub `KMSEncryption` example ships in DocC).

### 2.2 `ConfigStore` — the consumer surface

```swift
/// Read + write + persist a configuration tree.
///
/// `ConfigStore` is the consumer-facing API for writable configuration.
/// It composes a swift-configuration `ConfigReader` (env vars +
/// in-memory provider, with `DecryptingConfigProvider` wrapping the
/// in-memory provider to decrypt secrets on read) with async write
/// methods that update both the in-memory state and an on-disk file
/// atomically.
///
/// The store is `Sendable` and cheap to copy — `scoped(to:)` returns a
/// new value sharing the same backend with an extended scope prefix.
public struct ConfigStore: Sendable {
    // MARK: - Construction

    /// Construct a file-backed store.
    ///
    /// If `filePath` does not exist, the store starts empty; reads
    /// fall through to environment variables. The file is created
    /// on first write with `0o600` permissions (owner read+write
    /// only) since it may contain encrypted secrets.
    public init(
        filePath: String,
        scope: String,
        encryption: any ConfigEncryption,
        environmentProvider: (any ConfigProvider)? = EnvironmentVariablesProvider()
    ) throws

    /// Construct an in-memory-only store (no file backing). Useful
    /// in tests and ephemeral cases. Writes update the in-memory
    /// provider but do not persist.
    public static func inMemory(
        values: [String: String] = [:],
        encryption: any ConfigEncryption = .passthrough
    ) -> ConfigStore

    // MARK: - Reading

    /// The `ConfigReader` exposed to consumers. Synchronous reads
    /// hit the in-memory provider (thread-safe via swift-configuration's
    /// `MutableInMemoryProvider`); env-var lookups take precedence.
    public var reader: ConfigReader { get }

    /// Convenience for reading a single secret value (decrypted).
    /// Equivalent to `reader.string(forKey:)` but documents that the
    /// key is expected to hold a secret. Returns `nil` if the key
    /// is absent.
    public func secret(forKey key: String) -> String?

    // MARK: - Writing

    public func set(_ value: String, forKey key: String) async throws
    public func set(_ value: Int,    forKey key: String) async throws
    public func set(_ value: Bool,   forKey key: String) async throws
    public func set(_ value: Double, forKey key: String) async throws

    /// Encrypt the plaintext and persist it with the secret flag set.
    /// Subsequent reads via `reader.string(forKey:)` or
    /// `secret(forKey:)` return the decrypted plaintext.
    public func setSecret(_ value: String, forKey key: String) async throws

    public func remove(key: String) async throws

    // MARK: - Reload

    /// Re-read the backing file from disk and update the in-memory
    /// provider. Call after external edits (admin tooling, CLI,
    /// manual). State-stream subscribers (see §7) observe a fresh
    /// snapshot once `reload()` returns.
    public func reload() async throws

    // MARK: - Scoping

    /// Return a new `ConfigStore` sharing the same backend with an
    /// extended scope prefix. Reads and writes through the returned
    /// store key on `<scope>.<key>`.
    public func scoped(to scope: String) -> ConfigStore

    // MARK: - Info

    public var filePath: String { get }
}
```

The API is deliberately small. Writes are async because file I/O is
serialised by the actor backend; reads are sync because they hit a
thread-safe in-memory provider. Scoping is a value-type operation —
no actor hop, just a different prefix on the shared backend.

### 2.3 `DecryptingConfigProvider` — the swift-configuration adapter

```swift
/// A `ConfigProvider` that decrypts secret values transparently on
/// read. Wraps any upstream provider; passes non-secret values
/// through unchanged.
///
/// Plaintext exists only briefly inside the call stack of a read —
/// the encrypted form persists in the in-memory provider and on disk.
public struct DecryptingConfigProvider<Upstream: ConfigProvider>: Sendable, ConfigProvider {
    public init(upstream: Upstream, encryption: any ConfigEncryption)

    public var providerName: String { "Decrypting[\(upstream.providerName)]" }

    public func value(forKey: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult
    public func fetchValue(forKey: AbsoluteConfigKey, type: ConfigType) async throws -> LookupResult
    public func watchValue<R: ~Copyable>(forKey: AbsoluteConfigKey, type: ConfigType, ...) async throws -> R
    public func snapshot() -> any ConfigSnapshot
    public func watchSnapshot<R: ~Copyable>(...) async throws -> R
}
```

This is the bridge between BackplaneVault and `swift-configuration`'s
provider chain. The pattern preserves swift-configuration's full
behaviour (watching, snapshots, async fetches) while interposing
transparent decryption on values flagged `isSecret: true`. Lifted
unchanged from Acumen's implementation.

### 2.4 `PassthroughEncryption` — the default

```swift
/// A no-op `ConfigEncryption` that returns values unchanged.
/// `isEncrypted(_:)` always returns false, so
/// ``DecryptingConfigProvider`` never invokes `decrypt(_:)`.
///
/// Default in `ConfigStore.inMemory(...)`. Use in unit tests and for
/// genuinely non-secret writable state (last-run timestamps, learned
/// preferences, cache snapshots) where encryption would be ceremony
/// without benefit.
public struct PassthroughEncryption: ConfigEncryption {
    public init()
    public func encrypt(_ plaintext: String) throws -> String
    public func decrypt(_ ciphertext: String) throws -> String?
    public func isEncrypted(_ value: String) -> Bool
}
```

### 2.5 `LocalKeyfileEncryption` — trait-gated reference implementation

```swift
#if BACKPLANE_VAULT_KEYFILE

import Crypto

/// AES-256-GCM encryption backed by a machine-local keyfile.
///
/// On first use, generates a fresh 256-bit symmetric key and writes
/// it to `keyPath` with `0o600` permissions (owner read+write only).
/// Subsequent constructions read the existing key. Encrypted-value
/// format: `"backplane-vault:v1:<base64-nonce+ciphertext+tag>"`.
///
/// Available behind the `KeyfileEncryption` package trait, which
/// pulls `swift-crypto` as a dependency.
public struct LocalKeyfileEncryption: ConfigEncryption {
    /// The encrypted-value prefix. Versioned to allow format
    /// evolution; `isEncrypted(_:)` matches any "backplane-vault:v"
    /// prefix and `decrypt(_:)` dispatches on the version.
    public static let prefix = "backplane-vault:v1:"

    /// Construct with a keyfile path. Generates the keyfile if
    /// absent (with `0o600` permissions). Throws if the file exists
    /// but is malformed, if the parent directory cannot be created,
    /// or if the keyfile cannot be persisted to disk.
    public init(keyPath: String) throws

    /// Test-only constructor with an explicit `SymmetricKey`.
    package init(key: SymmetricKey)

    public func encrypt(_ plaintext: String) throws -> String
    public func decrypt(_ ciphertext: String) throws -> String?
    public func isEncrypted(_ value: String) -> Bool
}

#endif
```

**Implementation notes worth fixing from Acumen's version:**

- `init(keyPath:)` *must* throw if `createFile(...)` returns `false`.
  Acumen's current `SecurityService.swift:88` swallows the failure
  with a comment acknowledging it; the failure mode is silent
  in-process-only operation that loses state on next start. The
  reference implementation throws.
- Keyfile permissions are set with `attributes: [.posixPermissions: 0o600]`
  at `createFile` time, *and* re-applied with `setAttributes` after
  write — defensive against umask interactions.
- The version prefix accommodates future migration (`v2`, etc.)
  without breaking existing files. `decrypt(_:)` dispatches on the
  numeric version; `encrypt(_:)` always produces the latest.

### 2.6 The package wiring

```swift
// Package.swift — new trait + target

traits: [
    // ... existing traits ...
    .trait(
        name: "KeyfileEncryption",
        description: "Enable LocalKeyfileEncryption (AES-256-GCM, machine-local keyfile) and the swift-crypto dependency."
    ),
],
dependencies: [
    // ... existing dependencies ...
    .package(
        url: "https://github.com/apple/swift-crypto.git",
        from: "3.10.0"
    ),
],
targets: [
    // ... existing targets ...
    .target(
        name: "BackplaneVault",
        dependencies: [
            "Backplane",
            .product(name: "Configuration", package: "swift-configuration"),
            .product(
                name: "Crypto",
                package: "swift-crypto",
                condition: .when(traits: ["KeyfileEncryption"])
            ),
        ],
        swiftSettings: [
            .define("BACKPLANE_VAULT_KEYFILE", .when(traits: ["KeyfileEncryption"])),
        ]
    ),
    .testTarget(
        name: "BackplaneVaultTests",
        dependencies: ["BackplaneVault"]
    ),
],
products: [
    // ... existing products ...
    .library(name: "BackplaneVault", targets: ["BackplaneVault"]),
],
```

Three consumer shapes:

| Shape | `Package.swift` trait | What they get |
|---|---|---|
| Cloud microservice with managed secrets | none | They typically don't import BackplaneVault at all. |
| Test / non-secret writable state | none | `ConfigStore.inMemory(...)` + `PassthroughEncryption`. Zero `swift-crypto` dep. |
| Pi / NAS / on-prem / Acumen | `["KeyfileEncryption"]` | `LocalKeyfileEncryption(keyPath:)` is available; AES-256-GCM keyfile-managed. |
| Cloud with KMS-backed secrets | none (or custom trait) | Consumer writes `KMSEncryption: ConfigEncryption` against their cloud SDK. ~50 lines. |

---

## 3. Reading and writing

### 3.1 The read path

`ConfigStore.reader` is a `ConfigReader` composed as follows:

```
ConfigReader
  ├─ EnvironmentVariablesProvider             (highest precedence)
  └─ DecryptingConfigProvider
       └─ MutableInMemoryProvider             (populated from the JSON file)
```

Reads are synchronous and thread-safe (via swift-configuration's
internal locking on `MutableInMemoryProvider`). The
`DecryptingConfigProvider` only invokes `decrypt(_:)` for values
flagged `isSecret: true` — plaintext entries pass through with zero
crypto cost.

Env-var precedence preserves deployment-substitution semantics: a
container orchestrator overriding `MY_APP_DB_HOST` wins over the
file-backed value, exactly as a vanilla `ConfigReader` would behave.

### 3.2 The write path

All writes are `async`. The backend is an internal actor that
serialises:

1. Update the `MutableInMemoryProvider` (immediate; subsequent reads
   see the new value).
2. Update an internal `[String: Any]` mirror of the on-disk values.
3. Atomically write the mirror to the JSON file via
   `Data.write(...options: .atomic)` — temp file + `rename(2)`.

A `setSecret(_:forKey:)` call invokes `encryption.encrypt(_:)`
*before* both writes, so the in-memory provider holds the ciphertext
just like the file does. The `DecryptingConfigProvider` decrypts on
read. Plaintext exists only:

- In the `setSecret` argument (briefly, on the caller's stack), and
- In the `decrypt(_:)` return value (briefly, on the reader's stack).

Never on disk, never in the in-memory provider, never in a long-lived
heap allocation.

### 3.3 Removal

`remove(key:)` clears the value from both the in-memory provider and
the file. The key is genuinely absent from `reader.string(forKey:)`
afterwards — not present-as-empty.

### 3.4 Batch updates

For multi-key updates, callers can serialise themselves:

```swift
try await store.set("…", forKey: "a")
try await store.set("…", forKey: "b")
```

Each `set` performs one file write. For atomicity across multiple
keys, a `transaction { store in … }` API would consolidate into one
file write at the end. Currently deferred to §9 — Acumen has not
needed it. Adding it later is non-breaking.

---

## 4. Scoping

A `ConfigStore` can be sliced into a subtree:

```swift
let root = try ConfigStore(filePath: "/var/lib/myapp/config.json",
                           scope: "",
                           encryption: keyfileEncryption)

// Per-feature slice. Reads/writes target keys under "metrics.*"
let metrics = root.scoped(to: "metrics")
try await metrics.set("https://otlp.example", forKey: "endpoint")
// Persists as {"metrics": {"endpoint": "..."}} in the JSON.
```

Scoped stores share the underlying backend; calling `reload()` on any
of them reloads the file once. The scope prefix is a value-type
property, so a scoped store is cheap to mint and cheap to pass into
nested contexts.

This is the natural surface for per-entry config in Backplane (§7
below): the service graph mints one scoped `ConfigStore` per
`EntryDescriptor`, and the entry's factory receives it as
`context.configStore`. Different entries cannot accidentally read or
write each other's slices unless they explicitly resolve a sibling's
store.

---

## 5. Persistence

### 5.1 JSON, by default

BackplaneVault writes JSON files. Specifically:

- One file per `ConfigStore` root. Scoping uses prefixed keys *within*
  the file, not separate files. (Acumen happens to mint one store per
  integration, producing one file per integration — that's a consumer
  choice, not a vault-level requirement.)
- Pretty-printed with sorted keys (`JSONSerialization.WritingOptions
  [.prettyPrinted, .sortedKeys]`) so files are human-readable and
  diff-friendly. Useful for ops tooling, code review of committed
  config, and manual recovery.
- Atomic writes via `Data.write(to:options: .atomic)`. The temp-file
  + `rename(2)` pattern ensures a crashed write never leaves the file
  half-written; a reader observing the file mid-write sees either the
  old version or the new, never a partial blob.
- `0o600` permissions (owner read+write only). Even though secrets are
  encrypted at rest, defence-in-depth says other local users shouldn't
  be able to read the file.

### 5.2 Flat-key ↔ nested-dict translation

Internally the backend stores values in a flat `[String: Any]` keyed
by dot-separated strings (`"bridge.ip"`). On write, the dictionary is
expanded into nested JSON objects (`{"bridge": {"ip": "..."}}`); on
read, the JSON is flattened back. This keeps the in-memory map cheap
while producing JSON that matches how humans expect to read it.

### 5.3 Alternative backends

JSON is the only backend in v1. Plausible alternatives:

- **YAML / TOML.** More human-friendly for hand-edited config.
  Requires an additional dependency. Defer until a consumer asks.
- **Keychain (Darwin) / SecretService (Linux).** OS-level secret
  storage. Could replace the encryption layer entirely on Darwin.
  Distinct enough in shape to be a separate trait
  (`KeychainPersistence`?), not a v1 concern.
- **GCP Cloud KMS / AWS KMS with envelope encryption.** Different
  enough in topology (no local keyfile; remote unwrap on read) that
  it's better modelled as a `ConfigEncryption` conformer than a
  persistence-backend swap. The JSON file stays; the wrapped key
  lives elsewhere.

The point: BackplaneVault's persistence layer is one decision (JSON
files with atomic writes). Encryption is a separate, more pluggable
decision via `ConfigEncryption`. A consumer who wants
KMS-with-local-cache writes one conformer; they don't have to fork
the persistence layer.

If multi-backend persistence proves needed, a `ConfigPersistence`
protocol around the `ConfigWriter` utility is the extension point.
That refactor is non-breaking on the `ConfigStore` surface — the
extension is internal.

### 5.4 Default file locations

BackplaneVault does not pick a default file path. The consumer
explicitly passes one to `ConfigStore.init`. Reasoning: the right
location is deployment-shape-specific (project root in dev, `/var/lib`
on prod Linux, `~/Library/Application Support` on macOS,
`/data/...` on a container). A convention helper might be useful but
is out of scope for v1.

For the keyfile (`LocalKeyfileEncryption.keyPath`), the same applies.
A consumer typically derives both paths from a `BackplaneApplication.
identifier` plus an `Environment` lookup; the design note for §7
integration below sketches the recommended convention.

---

## 6. Encryption backends

### 6.1 PassthroughEncryption — the default

In-memory stores default to passthrough. `setSecret` becomes
indistinguishable from `set` (the value is stored verbatim); reads
return the raw value. Useful for:

- **Unit tests** that exercise the store API but don't care about
  ciphertext.
- **Genuinely non-secret state** (timestamps, learned preferences,
  cache snapshots) where the `setSecret` API offers convenient
  semantics even though the value isn't secret.

A file-backed store can also be constructed with passthrough; the
result is a writable JSON store with no encryption. Suitable for
non-secret persistent state.

### 6.2 LocalKeyfileEncryption — the reference implementation

Trait-gated under `KeyfileEncryption`. Pulls `swift-crypto`. Behaves
as documented in §2.5. Suitable for any consumer that wants local
encryption-at-rest and is comfortable owning the keyfile lifecycle.

**Operational characteristics:**

- Keyfile is 32 bytes (256-bit AES key), `0o600` permissions.
- Encryption uses AES-GCM with a fresh 12-byte nonce per `encrypt`
  call. The output is base64(`nonce || ciphertext || tag`) prefixed
  with `backplane-vault:v1:`.
- `decrypt` parses the version, decodes base64, splits into
  components, and runs AES-GCM verification + decryption.
  Tampered ciphertext produces a thrown error, not a silent
  corruption.
- Key rotation requires re-reading every value and re-encrypting
  with the new key. Not provided automatically in v1; documented as
  an open question (§9.2).

### 6.3 Consumer-provided backends

Any consumer with their own secret-management story conforms
`ConfigEncryption` directly. Example sketches (DocC catalog, not
shipped):

```swift
// KMS-backed encryption: each value is encrypted with a unique
// per-value DEK, which itself is wrapped with a remote KEK.
public struct KMSEncryption: ConfigEncryption {
    private let kms: any KMSClient
    public static let prefix = "kms:v1:"

    public func encrypt(_ plaintext: String) throws -> String {
        // … generate DEK, encrypt, wrap with KMS, return prefix + b64(wrapped || ciphertext) …
    }

    public func decrypt(_ ciphertext: String) throws -> String? {
        guard isEncrypted(ciphertext) else { return nil }
        // … unwrap DEK via KMS, decrypt …
    }

    public func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(Self.prefix)
    }
}
```

The protocol shape doesn't dictate symmetric vs envelope, local vs
remote, file-backed vs HSM. The only contract is: encrypt is a
function, decrypt is its (partial) inverse, isEncrypted is a cheap
recognizer.

### 6.4 Co-existing backends during migration

`isEncrypted(_:)` returning `nil` from `decrypt(_:)` for unrecognised
formats means a single `ConfigStore` can hold values encrypted by
different backends simultaneously. Useful during migrations: a
consumer rotating from `LocalKeyfileEncryption` to `KMSEncryption`
can ship a `ChainedEncryption` that tries the new backend first and
falls back to the old. Each `setSecret` produces new-format
ciphertext; reads transparently handle both.

This is a small power-user pattern, not a primary v1 surface, but
the protocol design admits it.

---

## 7. Integration with Backplane

### 7.1 `ServiceContext.configStore`

Backplane's `ServiceContext` (see `backplane.md` §2.7) gains
an optional property:

```swift
public final class ServiceContext: Sendable {
    // ... existing properties ...

    /// Per-entry writable configuration store. Non-nil when the
    /// consumer has wired BackplaneVault into the application;
    /// nil otherwise. The store is scoped to the entry's
    /// `leafName` — reads and writes through this property
    /// affect only this entry's slice.
    public var configStore: ConfigStore? { get }
}
```

The property is optional because not every consumer brings
BackplaneVault. Cloud-microservice consumers operating on read-only
`ConfigReader` see `nil` and never reach for it.

The store is *per-entry-scoped*. A service declared at
`\Services.bridge` gets `configStore` pointing into the "bridge"
prefix of the application's shared vault file (or, in Acumen's
existing model, a dedicated `bridge.json` — the choice between shared
and per-entry files is a consumer concern, not a BackplaneVault
concern).

### 7.2 Wiring via `BackplaneApplication`

A consumer that wants vault integration produces a `ConfigStore`
during application bootstrap and hands it to the service graph:

```swift
@main
struct MyApp: BackplaneApplication {
    typealias RootCommand = AppCommand
    static let identifier = "my-app"

    static func vault(for environment: Environment) async throws -> ConfigStore {
        let keyfile = try LocalKeyfileEncryption(
            keyPath: environment.configDirectory + "/.vault-key"
        )
        return try ConfigStore(
            filePath: environment.configDirectory + "/vault.json",
            scope: identifier,
            encryption: keyfile
        )
    }

    @ServiceGraphBuilder
    static func services() -> [EntryDescriptor] {
        // Descriptors as usual; ServiceContext.configStore is
        // populated automatically by the graph when a vault is
        // present in the bootstrap.
    }
}
```

The exact bootstrap-plumbing API will be designed alongside the
Backplane production migration; the design note for that
migration is the right place to specify the precise method names
and the way `ServiceGraph.init` consumes the optional vault. The key
property: `configStore` is `nil` in a consumer that hasn't wired one
up; it's `ConfigStore` (non-optional) for a consumer that has.

### 7.3 Hot-reload integration with `HotReloadable`

`backplane.md` §7 defines `HotReloadable.reload(config:)` — services
that support in-place reconfiguration take a fresh `ConfigReader` and
apply it atomically. BackplaneVault closes the loop:

```swift
extension ConfigStore {
    /// Subscribe to file-changed events. Each yield delivers a
    /// freshly-reloaded snapshot reader. Subscribers typically
    /// call `graph.reload(at: \.x)` on services whose config
    /// keys intersect with the changed keys.
    public var changes: AsyncStream<ConfigReader> { get }
}
```

Two trigger paths:

- **Explicit.** A consumer calls `store.reload()` after writing or
  receiving an external signal; the `changes` stream yields.
- **File watcher (optional).** Constructed with `watch: true`,
  the store sets up a `DispatchSource` file-system event observer.
  External modifications (admin CLI, manual edit, `scp` deploy)
  trigger automatic `reload()` calls that yield to the stream.

The watcher path requires platform-specific event sources
(`DispatchSource.makeFileSystemObjectSource` on Darwin, the
inotify-backed swift-NIO file watcher on Linux). The default is
`watch: false` — explicit reload only. Consumers that want auto-watch
opt in.

Connecting the stream to the graph is one supervisor task:

```swift
Task {
    for await reader in store.changes {
        for descriptor in graph.descriptors where descriptor.usesVault {
            await graph.reload(at: descriptor.id)
        }
    }
}
```

This is in the consumer layer, not in BackplaneVault. The vault
provides the stream; the consumer wires it to whatever subset of
services should react.

### 7.4 What BackplaneVault does *not* know about Backplane

The vault target compiles and runs without `ServiceGraph`,
`ManagedService`, or any of the §7 restart-aware machinery. A
consumer using only `ConfigStore` against bare swift-configuration
(no Backplane graph at all) gets the writable-config story
without paying for anything else.

This is the inverse of BackplaneVault depending on Backplane: vault
depends on swift-configuration and (optionally) swift-crypto, period.
Backplane *consumes* vault if the consumer wires it in.

---

## 8. Acumen migration

`Sources/PersistableEncryptableConfig/` migrates to BackplaneVault
with mostly file moves and a small set of refinements. Mapping:

| Acumen file | BackplaneVault disposition |
|---|---|
| `ConfigEncryption.swift` | Lifted unchanged to `Sources/BackplaneVault/ConfigEncryption.swift`. |
| `ConfigStore.swift` | Lifted to `Sources/BackplaneVault/ConfigStore.swift`. Internal `ConfigStoreBackend` actor preserved. |
| `ConfigWriter.swift` | Lifted to `Sources/BackplaneVault/ConfigWriter.swift`. |
| `DecryptingConfigProvider.swift` | Lifted unchanged. |
| `PassthroughEncryption.swift` | Lifted unchanged. |
| (none) | New file `Sources/BackplaneVault/LocalKeyfileEncryption.swift`, `#if BACKPLANE_VAULT_KEYFILE`-guarded. Built from Acumen's `SecurityService` AES-GCM logic minus PBKDF2. |

Acumen's `SecurityService` then thins out:

- The `ConfigEncryption` conformance is deleted. Acumen imports
  `BackplaneVault` with the `KeyfileEncryption` trait and instantiates
  `LocalKeyfileEncryption(keyPath:)` directly.
- The PBKDF2 hashing functions stay in `SecurityService` (or move to
  a smaller `AcumenHashing` target). Hashing is unrelated to
  encryption-at-rest and shouldn't bloat BackplaneVault's surface.
- `AcumenProject.swift`'s per-integration `ConfigStore` minting code
  stays as-is — it already uses the `ConfigStore` API surface
  BackplaneVault preserves.

Breaking changes for Acumen consumers:

- `import PersistableEncryptableConfig` → `import BackplaneVault`.
- Package trait must include `KeyfileEncryption`.
- `SecurityService` is no longer a `ConfigEncryption`; consumers
  passing `security` to `ConfigStore.init` pass an explicit
  `LocalKeyfileEncryption` instead. (Acumen does this in one place,
  `AcumenProject.swift`.)

### `SecurityService`'s dual role

A wrinkle the table above understates: `SecurityService` in Acumen is
passed to **two** consumers — `ConfigStore.init`'s `encryption:`
parameter *and* `ServiceContextExtras` so that individual services
(e.g. `UniFiProtectAgent`'s cert pinning, `AcumenCloudService`) can
call its hashing/PBKDF2 helpers (`AcumenProject.swift:468`). After the
migration `SecurityService` keeps the hashing role but is no longer
the encryption backend, so the context-extras struct now needs *two*
fields — one for `LocalKeyfileEncryption` (the vault encryption
backend) and one for `SecurityService` (the hasher) — or
`SecurityService` keeps an internal reference to its
`LocalKeyfileEncryption` to retain a single conduit. The
single-conduit option is the smaller diff but couples the two
concerns; two fields is honest about the split. Recommend two fields.

### Unifying the factory's `ConfigReader` with `configStore.reader`

Today Acumen's `IntegrationRegistry.composeReader`
(`Integration/IntegrationRegistry.swift:553`) passes the factory a
plain `ConfigReader` that sees encrypted-secret JSON values as
opaque strings. The factory must reach for `context.configStore`
separately to read decrypted secrets — two different readers for two
different value classes. Under Backplane + BackplaneVault the
factory's `ConfigReader` *could* be `configStore.reader` (which
already wraps `DecryptingConfigProvider`), unifying the two paths.

**Lean:** unify. The factory always sees decrypted values when the
service is wired with a vault; non-vault consumers see whatever
their `ConfigReader` produces. This drops one of the two parallel
read paths and removes the "did I use the right reader for this
key" trap. Decide during the production-migration PR.

Acumen's existing `PersistableEncryptableConfigTests` translate
file-for-file to `BackplaneVaultTests`.

### What about the keyfile-creation fragility?

Acumen's `SecurityService.init(keyPath:)` swallows a `createFile`
failure and proceeds with an in-process-only key. The migration is
the right time to fix it: `LocalKeyfileEncryption.init` throws on
persist failure, surfacing the problem at construction rather than
losing user data on next start. Acumen picks up the fix as a
side-effect of the migration.

---

## 9. Open questions

### 9.1 File watcher implementation and policy

The §7 integration sketches a file-watcher option for `ConfigStore`.
Open sub-questions:

- **Platform abstraction.** `DispatchSource.makeFileSystemObjectSource`
  on Darwin; some inotify-backed equivalent on Linux. Swift NIO has a
  watcher; pulling NIO into BackplaneVault adds a meaningful dep.
- **Debouncing.** A `vi`-style write produces multiple FS events
  (open → write → rename); the watcher should debounce.
- **Reload-failure handling.** If the new file is malformed, do we
  yield a "reload failed" event, retain the old reader, or fall
  back? Lean: retain old reader, log + yield a failure on a separate
  stream.

**Lean:** ship in v1 without the watcher; ship watcher in v1.1 once
the platform-abstraction story is settled. `changes` stream still
exists in v1 but yields only on explicit `reload()`.

### 9.2 Key rotation

`LocalKeyfileEncryption` uses one key for the lifetime of the keyfile.
Plausible rotation API:

```swift
extension LocalKeyfileEncryption {
    /// Generate a new key, re-encrypt every secret in the store
    /// with it, and replace the keyfile atomically. Returns the
    /// new instance.
    public func rekey(store: ConfigStore, newKeyPath: String) async throws -> LocalKeyfileEncryption
}
```

Open: does the old keyfile get retained for rollback? What's the
crash-safety story (rename order matters)? Lean: defer to v1.1;
shipping a working rotation primitive requires more thought than v1
needs.

### 9.3 Batch / transactional writes

Currently each `set(_:forKey:)` writes the file once. For a flow
that updates ten keys, that's ten file writes. A `transaction { store in ... }`
API consolidating into one final write would be cheaper.

**Lean:** Ship without it; add when a real consumer hits the
performance corner. Acumen's existing pattern is one-write-per-set;
no observed performance issue.

### 9.4 Schema validation hook

`ConfigStore.validate(_:)` — a closure that runs against the in-memory
state before any file write, throwing to reject an invalid update.

**Lean:** Out of scope. Validation is consumer-specific; build it on
top of `set` calls.

### 9.5 Env-var naming convention

`ConfigStore.scoped(to: "bridge")` produces keys like `"bridge.host"`
that swift-configuration's `EnvironmentVariablesProvider` looks up.
The exact transformation (camel-case to upper-snake-case? dots to
underscores?) depends on the env-var provider's configuration; the
default may or may not match what consumers expect.

**Lean:** Document the default transformation in BackplaneVault's
DocC catalog with a worked example. If consumers consistently want
a different transformation, ship a `vaultEnvironmentProvider`
helper that pre-configures the mapping.

### 9.6 Multiple stores sharing one file

`ConfigStore.scoped(to:)` produces a derived store sharing the
*backend* (so the file is shared). A consumer wanting truly
independent files mints multiple top-level `ConfigStore` instances
with distinct `filePath` values.

Open: if two top-level stores accidentally point at the same file,
what happens? Independent in-memory state diverges; whichever writes
last wins on disk. Either detect (refuse to construct a second store
on the same path) or document.

**Lean:** Detect — refuse to construct a second store on a path
already held by a live `ConfigStore`. Use a process-local registry
inside BackplaneVault. The detection isn't bulletproof against
multi-process access (no fcntl locks), but covers the common case
of accidental double-construction within one process.

### 9.7 Default file/keyfile location convention

A `BackplaneVault.defaultPath(for: app, environment:)` helper that
returns `$XDG_CONFIG_HOME/<app.identifier>/vault.json` (or
platform-appropriate alternatives) would save consumers from
inventing their own convention.

**Lean:** Ship the convention as documentation rather than code in
v1 — the helper is a 10-liner consumers can write or copy from
DocC. If multiple consumers converge on the same answer, promote
the helper into the target.

### 9.8 Secret-detection on read

`DecryptingConfigProvider` decrypts only values flagged
`isSecret: true`. A value that's been encrypted at rest but
*not* flagged (because of a write-path bug, an external edit, or a
schema-evolution mistake) will return the raw ciphertext to the
consumer.

Open: should `DecryptingConfigProvider` also check
`encryption.isEncrypted(_:)` on string values whose `isSecret` flag
is false, as a defence-in-depth measure? Cost: one prefix-check
per read.

**Lean:** Yes — add the prefix check as a fall-through. Trivial cost,
non-trivial improvement to "I edited the JSON file by hand"
ergonomics. Document that secret values are always decrypted on
read regardless of the in-memory flag, so consumers can't
accidentally leak ciphertext to logs.

---

## Summary

BackplaneVault is the satellite target that augments
swift-configuration's read-only story with writable, persistable,
encryption-aware config. It composes with Backplane's
`ServiceContext` to give every service entry an optional, scoped
`ConfigStore`, and ties into §7's `HotReloadable` machinery via an
optional file-changes stream.

The core surface is small: a `ConfigEncryption` protocol, a
`ConfigStore` struct that wraps swift-configuration's reader chain
plus async writers, and a `DecryptingConfigProvider` that keeps
plaintext ephemeral. Two encryption backends ship: a
`PassthroughEncryption` no-op (always available) and a trait-gated
`LocalKeyfileEncryption` reference implementation (AES-256-GCM,
keyfile-managed, requires `swift-crypto`). Consumers who need a
different backend (KMS, HSM, Keychain) conform `ConfigEncryption`
directly in ~50 lines.

Reference consumer: Acumen's `PersistableEncryptableConfig`. The
target migrates file-for-file with a small set of refinements,
chiefly the fix to keyfile-persist failure handling.

Open questions in §9 are operational (watcher, key rotation,
batching) rather than architectural; none block v1.
