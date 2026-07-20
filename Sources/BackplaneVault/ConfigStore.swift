//
//  ConfigStore.swift
//  swift-backplane
//

import Configuration
import Foundation

/// Combined configuration reader + writer backed by a JSON file.
///
/// Provides the standard `ConfigReader` for reading (with env var override),
/// plus async write methods that update both the JSON file and the in-memory
/// provider immediately (write-through). Secrets are encrypted via a shared
/// ``ConfigEncryption`` implementation.
///
/// ## Reading
///
/// Reads go through the standard `ConfigReader` which queries providers in order:
/// 1. Environment variables (highest precedence — for deployment overrides)
/// 2. `MutableInMemoryProvider` (loaded from JSON file)
///
/// ```swift
/// let value = configStore.reader.string(forKey: "bridgeIP")
/// ```
///
/// ## Writing
///
/// Writes update both the in-memory provider (immediate) and the JSON file
/// (atomic write). All write methods are `async` since file I/O is serialized
/// by the actor backend.
///
/// ```swift
/// try await configStore.set("192.168.1.10", forKey: "bridgeIP")
/// ```
///
/// ## Concurrent stores on one file
///
/// Multiple `ConfigStore`s may safely share one file — across processes
/// (e.g. the daemon and the home process by design) and within one process.
/// Every write is a locked read-merge-write under an advisory ``FileLock``:
/// the file is re-read fresh and only the written key changes, so a write
/// can never erase keys another store wrote after this store last loaded.
/// The guarantee is **no lost keys** with per-key last-writer-wins; it is
/// *not* snapshot isolation. Reads still come from this store's in-memory
/// state — call ``reload()`` when you need to *see* keys written externally
/// (a local write also refreshes opportunistically from the merged file).
///
/// ## Secrets
///
/// Secrets are stored encrypted both on disk (JSON file) and in-memory
/// (``MutableInMemoryProvider``) using the provided ``ConfigEncryption``
/// implementation. A ``DecryptingConfigProvider`` transparently decrypts
/// values marked `isSecret` on read, so consumers always receive plaintext.
/// This keeps plaintext values ephemeral — they exist only during reads.
///
/// ```swift
/// try await configStore.setSecret("my-api-key", forKey: "appKey")
/// let key = configStore.secret(forKey: "appKey")  // "my-api-key"
/// ```
///
/// ## Scoping
///
/// `scoped(to:)` returns a new `ConfigStore` sharing the same backend with an
/// extended scope prefix. The reader is scoped via `ConfigReader.scoped(to:)`.
/// Writes prepend the scope to keys in the JSON file.
///
/// ```swift
/// let bridgeStore = configStore.scoped(to: "bridge")
/// // Reads/writes keys under {"bridge": {...}} in the JSON file
/// ```
public struct ConfigStore: Sendable {
    private let backend: ConfigStoreBackend

    /// The scope prefix applied to this store's keys.
    /// Empty for the root store; non-empty for scoped stores.
    private let scopePrefix: [String]

    // MARK: - Initialization

    /// Create a config store backed by a JSON file.
    ///
    /// If the JSON file does not exist, the store starts empty — reads fall
    /// through to environment variables. The file is created on first write
    /// with `0o600` permissions (owner read+write only) since it may contain
    /// encrypted secrets.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the JSON config file.
    ///   - scope: The configuration scope (used as prefix for env var lookups).
    ///   - encryption: The encryption implementation for secret encryption/decryption.
    ///   - environmentProvider: Optional env var provider for override support.
    ///     Pass `nil` to disable env var override (useful for testing).
    public init(
        filePath: String,
        scope: String,
        encryption: any ConfigEncryption,
        environmentProvider: (any ConfigProvider)? = EnvironmentVariablesProvider()
    ) throws {
        let backend = try ConfigStoreBackend(
            filePath: filePath,
            scope: scope,
            encryption: encryption,
            environmentProvider: environmentProvider
        )
        self.backend = backend
        self.scopePrefix = []
    }

    /// Create a config store with an explicit backend and scope prefix (for scoping).
    private init(backend: ConfigStoreBackend, scopePrefix: [String]) {
        self.backend = backend
        self.scopePrefix = scopePrefix
    }

    /// Create a config store for testing with in-memory values only.
    ///
    /// No file backing — writes update only the in-memory provider.
    /// Useful for unit tests that don't need persistence.
    public static func inMemory(
        values: [String: String] = [:],
        encryption: any ConfigEncryption = .passthrough
    ) -> ConfigStore {
        let backend = ConfigStoreBackend(
            inMemoryValues: values,
            encryption: encryption
        )
        return ConfigStore(backend: backend, scopePrefix: [])
    }

    // MARK: - Reading

    /// The `ConfigReader` for reading configuration values.
    ///
    /// Environment variables take precedence over JSON file values.
    /// This property is synchronous — reads go through the thread-safe
    /// `MutableInMemoryProvider`.
    public var reader: ConfigReader {
        if scopePrefix.isEmpty {
            return backend.reader
        }
        return backend.reader.scoped(to: ConfigKey(scopePrefix.joined(separator: ".")))
    }

    /// Read a secret value.
    ///
    /// Secrets are stored encrypted in-memory. The ``DecryptingConfigProvider``
    /// transparently decrypts on read, so this method returns plaintext.
    /// Returns `nil` if the key doesn't exist.
    ///
    /// - Parameter key: The configuration key.
    /// - Returns: The decrypted secret value, or `nil` if the key doesn't exist.
    public func secret(forKey key: String) -> String? {
        reader.string(forKey: ConfigKey(key))
    }

    // MARK: - Writing

    /// Write a string value to the JSON config file.
    ///
    /// Updates both the in-memory provider (immediate) and the JSON file (atomic).
    ///
    /// - Parameters:
    ///   - value: The string value to write.
    ///   - key: The configuration key.
    public func set(_ value: String, forKey key: String) async throws {
        try await backend.setValue(.string(value), forKey: prefixedKey(key), isSecret: false)
    }

    /// Write an integer value to the JSON config file.
    public func set(_ value: Int, forKey key: String) async throws {
        try await backend.setValue(.int(value), forKey: prefixedKey(key), isSecret: false)
    }

    /// Write a boolean value to the JSON config file.
    public func set(_ value: Bool, forKey key: String) async throws {
        try await backend.setValue(.bool(value), forKey: prefixedKey(key), isSecret: false)
    }

    /// Write a double value to the JSON config file.
    public func set(_ value: Double, forKey key: String) async throws {
        try await backend.setValue(.double(value), forKey: prefixedKey(key), isSecret: false)
    }

    /// Remove a key from the JSON config file.
    public func remove(key: String) async throws {
        try await backend.removeValue(forKey: prefixedKey(key))
    }

    /// Write an encrypted secret value to the JSON config file.
    ///
    /// The value is encrypted using the configured ``ConfigEncryption``
    /// implementation before being stored.
    ///
    /// - Parameters:
    ///   - value: The plaintext secret to encrypt and store.
    ///   - key: The configuration key.
    public func setSecret(_ value: String, forKey key: String) async throws {
        let encrypted = try backend.encryption.encrypt(value)
        try await backend.setValue(.string(encrypted), forKey: prefixedKey(key), isSecret: true)
    }

    // MARK: - Reload

    /// Re-read the JSON file from disk.
    ///
    /// Call this after external modifications to the config file (manual edits,
    /// CLI commands, etc.) to pick up the changes in the in-memory provider.
    public func reload() async throws {
        try await backend.reload()
    }

    // MARK: - Scoping

    /// Create a scoped config store sharing the same backend.
    ///
    /// The returned store reads and writes keys under the given scope prefix.
    /// For example, `store.scoped(to: "bridge")` reads `"bridge.ip"` when you
    /// call `reader.string(forKey: "ip")`.
    ///
    /// - Parameter scope: The scope prefix to add.
    /// - Returns: A scoped `ConfigStore` sharing the same backend.
    public func scoped(to scope: String) -> ConfigStore {
        ConfigStore(backend: backend, scopePrefix: scopePrefix + [scope])
    }

    // MARK: - Info

    /// The file path of the backing JSON file.
    public var filePath: String { backend.filePath }

    // MARK: - Private

    /// Compute the full key with the scope prefix prepended.
    private func prefixedKey(_ key: String) -> String {
        if scopePrefix.isEmpty {
            return key
        }
        return (scopePrefix + [key]).joined(separator: ".")
    }
}

// MARK: - Backend (Actor)

/// Actor that serializes file writes and manages the in-memory config state.
///
/// Uses `MutableInMemoryProvider` from swift-configuration for thread-safe
/// write-through semantics. Writes within this backend are serialized by
/// actor isolation; writes from *other* backends on the same file (other
/// processes, or other instances in this process — actor isolation does not
/// cover those) are excluded by the per-write ``FileLock`` and survive
/// because every write merges into a fresh read of the file rather than
/// rewriting from this backend's snapshot.
public actor ConfigStoreBackend {
    let filePath: String
    let scope: String
    let encryption: any ConfigEncryption

    /// The mutable in-memory provider that backs the ConfigReader.
    /// Thread-safe via Swift Synchronization's Mutex.
    nonisolated let mutableProvider: MutableInMemoryProvider

    /// The composed ConfigReader: env vars (if present) + mutable provider.
    nonisolated let reader: ConfigReader

    /// Cache of the flat key-value file state as of the last locked
    /// write/reload. Never used as the source for a file write — writes
    /// re-read the file under the lock — so staleness here can delay read
    /// visibility but can never destroy another writer's keys.
    private var currentValues: [String: Any]

    // MARK: - Init (file-backed)

    init(
        filePath: String,
        scope: String,
        encryption: any ConfigEncryption,
        environmentProvider: (any ConfigProvider)?
    ) throws {
        self.filePath = filePath
        self.scope = scope
        self.encryption = encryption

        // Load existing JSON file (empty dict if missing)
        let values = try ConfigWriter.read(filePath: filePath)
        self.currentValues = values

        // Populate MutableInMemoryProvider with scoped keys
        var initial: [AbsoluteConfigKey: ConfigValue] = [:]
        for (key, value) in values {
            let absKey = Self.absoluteKey(scope: scope, key: key)
            let configValue = Self.toConfigValue(value, encryption: encryption)
            initial[absKey] = configValue
        }

        let mutable = MutableInMemoryProvider(name: "config-store[\(scope)]", initialValues: initial)
        self.mutableProvider = mutable

        // Wrap the mutable provider to decrypt secrets on read
        let decrypting = DecryptingConfigProvider(upstream: mutable, encryption: encryption)

        // Compose reader: env vars (highest precedence) + decrypting provider
        if let envProvider = environmentProvider {
            self.reader = ConfigReader(providers: [envProvider, decrypting]).scoped(to: ConfigKey(scope))
        } else {
            self.reader = ConfigReader(provider: decrypting).scoped(to: ConfigKey(scope))
        }
    }

    // MARK: - Init (in-memory only, for testing)

    init(inMemoryValues: [String: String], encryption: any ConfigEncryption) {
        self.filePath = ""
        self.scope = ""
        self.encryption = encryption
        self.currentValues = inMemoryValues

        var initial: [AbsoluteConfigKey: ConfigValue] = [:]
        for (key, value) in inMemoryValues {
            let absKey = Self.absoluteKey(scope: "", key: key)
            initial[absKey] = ConfigValue(.string(value), isSecret: false)
        }

        let mutable = MutableInMemoryProvider(name: "config-store[in-memory]", initialValues: initial)
        self.mutableProvider = mutable

        // Wrap with DecryptingConfigProvider for consistency with file-backed init
        let decrypting = DecryptingConfigProvider(upstream: mutable, encryption: encryption)
        self.reader = ConfigReader(provider: decrypting)
    }

    // MARK: - Write Operations

    /// Build the absolute in-memory key for a config key under this store's scope.
    ///
    /// Both the scope and the key are split on "." — a scope may itself be a
    /// dotted identifier (e.g. `"service.database"`), and the reader is
    /// scoped via `ConfigReader.scoped(to:)` which splits the same way.
    /// Every read AND write path must build keys through this one helper: a
    /// scope kept as a single component writes to `["service.database", key]`
    /// while the scoped reader queries `["service", "database", key]`,
    /// silently breaking write-through until the file is re-read from disk.
    static func absoluteKey(scope: String, key: String) -> AbsoluteConfigKey {
        let components = scope.isEmpty ? [key] : [scope, key]
        return AbsoluteConfigKey(components.flatMap { $0.split(separator: ".").map(String.init) })
    }

    /// Set a value in both the in-memory provider and the JSON file.
    ///
    /// The file update is a locked read-merge-write: acquire the file's
    /// cross-process ``FileLock``, re-read the file fresh, apply this single
    /// key, write back atomically, release. The in-memory snapshot is never
    /// what gets written, so keys another process (or another store on the
    /// same file) wrote after this store loaded can never be erased —
    /// the guarantee is *no lost keys*, per-key last-writer-wins.
    func setValue(_ content: ConfigContent, forKey key: String, isSecret: Bool) async throws {
        let absKey = Self.absoluteKey(scope: scope, key: key)
        let jsonValue: Any = switch content {
        case .string(let s): s
        case .int(let i): i
        case .double(let d): d
        case .bool(let b): b
        default: String(describing: content)
        }

        guard !filePath.isEmpty else {
            // In-memory only (testing) — no file, no lock.
            mutableProvider.setValue(ConfigValue(content, isSecret: isSecret), forKey: absKey)
            currentValues[key] = jsonValue
            return
        }

        let merged: [String: Any]
        do {
            let lock = try await FileLock.acquire(forProtecting: filePath)
            defer { lock.release() }
            merged = try ConfigWriter.mergeHoldingLock(key: key, value: jsonValue, filePath: filePath)
        }
        syncInMemory(with: merged)

        // Re-assert the written key with the caller-declared secrecy:
        // syncInMemory re-derives isSecret by ciphertext detection, but the
        // caller knows authoritatively whether this value is a secret.
        mutableProvider.setValue(ConfigValue(content, isSecret: isSecret), forKey: absKey)
    }

    /// Remove a value from both the in-memory provider and the JSON file.
    ///
    /// Same locked read-merge-write as `setValue` — only this key is
    /// removed; keys written by other processes survive.
    func removeValue(forKey key: String) async throws {
        let absKey = Self.absoluteKey(scope: scope, key: key)

        guard !filePath.isEmpty else {
            mutableProvider.setValue(nil, forKey: absKey)
            currentValues.removeValue(forKey: key)
            return
        }

        let merged: [String: Any]
        do {
            let lock = try await FileLock.acquire(forProtecting: filePath)
            defer { lock.release() }
            merged = try ConfigWriter.mergeHoldingLock(key: key, value: nil, filePath: filePath)
        }
        syncInMemory(with: merged)
        mutableProvider.setValue(nil, forKey: absKey)
    }

    /// Reload the JSON file from disk and update the in-memory provider.
    ///
    /// Held under the same ``FileLock`` as writes so a reload can never
    /// observe (or race) a concurrent read-merge-write from another store.
    func reload() async throws {
        guard !filePath.isEmpty else { return }

        let newValues: [String: Any]
        do {
            let lock = try await FileLock.acquire(forProtecting: filePath)
            defer { lock.release() }
            newValues = try ConfigWriter.read(filePath: filePath)
        }
        syncInMemory(with: newValues)
    }

    /// Replace in-memory state (`currentValues` + the mutable provider) with
    /// an authoritative file snapshot: clears keys no longer present, then
    /// sets every key from the snapshot.
    ///
    /// Called after every locked write with the merged result, so keys other
    /// processes wrote become *visible opportunistically* here — but the only
    /// guarantee is that they are never destroyed. Deterministic read
    /// visibility of external writes still requires ``reload()``.
    private func syncInMemory(with newValues: [String: Any]) {
        for key in currentValues.keys where newValues[key] == nil {
            mutableProvider.setValue(nil, forKey: Self.absoluteKey(scope: scope, key: key))
        }
        for (key, value) in newValues {
            let configValue = Self.toConfigValue(value, encryption: encryption)
            mutableProvider.setValue(configValue, forKey: Self.absoluteKey(scope: scope, key: key))
        }
        currentValues = newValues
    }

    // MARK: - Private

    /// Convert a JSON-compatible value to a ConfigValue.
    ///
    /// Encrypted strings are stored as-is with `isSecret: true` — the
    /// ``DecryptingConfigProvider`` handles decryption on read so that
    /// plaintext only exists briefly during access.
    private static func toConfigValue(_ value: Any, encryption: any ConfigEncryption) -> ConfigValue {
        // Bool must be checked before Int — NSNumber from JSONSerialization
        // matches both `as Int` and `as Bool`, so whichever comes first wins.
        switch value {
        case let s as String:
            if encryption.isEncrypted(s) {
                return ConfigValue(.string(s), isSecret: true)
            }
            return ConfigValue(.string(s), isSecret: false)
        case let b as Bool:
            return ConfigValue(.bool(b), isSecret: false)
        case let i as Int:
            return ConfigValue(.int(i), isSecret: false)
        case let d as Double:
            return ConfigValue(.double(d), isSecret: false)
        default:
            return ConfigValue(.string(String(describing: value)), isSecret: false)
        }
    }
}
