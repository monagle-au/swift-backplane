//
//  BackplaneContext.swift
//  swift-backplane
//

import Configuration
import Logging

/// Reader passed to a service's factory closure.
///
/// Carries identity, a pre-scoped logger, the entry's lifecycle handle,
/// the self-report channel for health, and forwarders for cross-service
/// resolution.
///
/// `service(_:)` and `requireService(_:)` route to the underlying
/// ``ServiceGraph`` without exposing the actor existential on the
/// public surface — the graph reference is private.
///
/// **Naming note:** distinct from `ServiceContextModule.ServiceContext`
/// (swift-service-context's tracing-baggage type). The two are different
/// concepts; the 1.0 extensions on the SSWG type are preserved unchanged.
public final class BackplaneContext: Sendable {

    /// Entry identifier. Stable for the entry's lifetime.
    public let entryID: String

    /// Logger pre-scoped to the entry (metadata key `entry` set).
    public let logger: Logger

    /// Lifecycle handle for the entry that owns this context.
    public let lifecycle: any ServiceLifecycleHandle

    /// Self-report channel for this entry's running service. Used by
    /// the service to signal its own degradation (and recovery) without
    /// affecting routing — `resolve(_:)` continues to return the live
    /// instance. The graph never reads this; it's a write-only surface
    /// for the service.
    public let health: any ServiceHealthReporter

    /// Configuration reader **scoped to the entry's id**. An entry with
    /// id `"postgres"` reads `postgres.host` as `host` — no hand-scoping
    /// at the call site, and the same service type registered under two
    /// keys reads two config scopes (multi-instance).
    ///
    /// `nil` when the graph was constructed without a config (e.g. unit
    /// tests of the graph machinery itself). Factories that need
    /// configuration unconditionally should prefer ``requireConfig()``
    /// to avoid open-coding the nil check. For cross-cutting keys
    /// outside the entry's scope, use ``rootConfig``.
    public let config: ConfigReader?

    /// The application's unscoped configuration reader — the escape
    /// hatch for cross-cutting keys (`logging.level`, feature flags)
    /// that live outside the entry's scope. `nil` exactly when
    /// ``config`` is nil.
    public let rootConfig: ConfigReader?

    /// Captured graph reference for forwarding lookups. Hidden from the
    /// public surface so callers can't reach into actor-isolated state.
    private let graph: ServiceGraph

    package init(
        entryID: String,
        logger: Logger,
        lifecycle: any ServiceLifecycleHandle,
        health: any ServiceHealthReporter,
        config: ConfigReader? = nil,
        rootConfig: ConfigReader? = nil,
        graph: ServiceGraph
    ) {
        self.entryID = entryID
        self.logger = logger
        self.lifecycle = lifecycle
        self.health = health
        self.config = config
        self.rootConfig = rootConfig ?? config
        self.graph = graph
    }

    // MARK: - Cross-service resolution

    /// Synchronous resolve. Returns nil if the entry has no live handle
    /// (never-booted, `.stopped`, `.failed`). Returns the
    /// currently-active generation during `.replacing` — the no-gap
    /// property holds.
    public func service<T: Sendable>(_ key: ServiceKey<T>) -> T? {
        graph.resolve(key)
    }

    /// Async resolve that waits for the named entry to reach a
    /// resolution-ready state.
    ///
    /// Pass `timeout: nil` (the default) to wait indefinitely.
    /// Pass a `Duration` to bound the wait — exceeding it throws
    /// ``ServiceGraphError/timedOut(id:expectedType:after:)``.
    /// Recommended in production to prevent a slow dependency from
    /// causing the caller's `start()` to hang.
    ///
    /// Throws ``ServiceGraphError`` if the entry is unknown, has a
    /// wrong instance type, settles into a terminal non-running state,
    /// or exceeds the timeout.
    public func requireService<T: Sendable>(
        _ key: ServiceKey<T>,
        timeout: Duration? = nil
    ) async throws -> T {
        try await graph.requireService(key, timeout: timeout)
    }

    // MARK: - Keypath-based resolution

    /// Keypath-flavoured synchronous resolve.
    ///
    /// ```swift
    /// if let pg = context.service(\.postgres) { … }
    /// ```
    ///
    /// `T` is inferred from the keypath's `Value` type.
    public func service<T: Sendable>(
        _ keyPath: KeyPath<Services, ServiceKey<T>>
    ) -> T? {
        graph.resolve(Services()[keyPath: keyPath])
    }

    /// Keypath-flavoured async resolve.
    ///
    /// ```swift
    /// let pg = try await context.requireService(\.postgres)
    /// ```
    ///
    /// `T` is inferred from the keypath's `Value` type. Throwing
    /// behaviour matches ``requireService(_:timeout:)-(ServiceKey<T>,_)``.
    public func requireService<T: Sendable>(
        _ keyPath: KeyPath<Services, ServiceKey<T>>,
        timeout: Duration? = nil
    ) async throws -> T {
        try await graph.requireService(Services()[keyPath: keyPath], timeout: timeout)
    }

    // MARK: - Configuration

    /// Return the entry-scoped `ConfigReader`, or throw
    /// ``ServiceGraphError/missingConfigReader(entryID:)`` if the
    /// graph was constructed without one.
    ///
    /// Convenience for descriptors that require config unconditionally
    /// — avoids open-coding the same `guard let config = context.config
    /// else { fatalError(...) }` block on every entry.
    ///
    /// ```swift
    /// // Entry id "postgres" — the reader is already scoped to it.
    /// let pgConfig = PostgresClient.Configuration(config: try context.requireConfig())
    /// ```
    public func requireConfig() throws -> ConfigReader {
        guard let config else {
            throw ServiceGraphError.missingConfigReader(entryID: entryID)
        }
        return config
    }
}
