//
//  PostgresServiceKey.swift
//  swift-backplane
//

#if BACKPLANE_POSTGRES

import Backplane
import Logging
import PostgresNIO
import Synchronization

// MARK: - BackplanePostgresService

/// `ManagedService` wrapper around `PostgresClient`.
///
/// The underlying `PostgresClient` is a `ServiceLifecycle.Service`
/// whose `run()` opens connections and stays running for the lifetime
/// of the service. This wrapper adapts it to the
/// `ManagedService` two-phase contract used by ``ServiceGraph``:
/// `start()` spawns the client's run loop in a detached task and
/// returns immediately; `shutdown()` cancels the task and awaits its
/// termination.
///
/// **Readiness:** `PostgresClient.run()` has no "client is ready"
/// signal. `start()` returns once the run task has been scheduled, not
/// once a connection has been established. Code resolving the client
/// immediately after `start()` may see queries fail until the pool's
/// first connection is established. For production wiring, a thin
/// supervisor task can verify readiness (e.g. `SELECT 1`) and gate
/// dependent services with ``HotReloadable``.
public final class BackplanePostgresService: ManagedService, @unchecked Sendable {
    /// The wrapped `PostgresClient`. Resolve the service via
    /// ``Services/postgres`` and access this property to drive queries.
    ///
    /// Aliased to ``inner`` for consumers that prefer the Backplane-wide
    /// `.inner` convention used by ``LifecycleAdapter`` and
    /// ``PassiveService``.
    public let client: PostgresClient

    /// Backplane-wide alias for ``client``. Use whichever reads better
    /// at the call site — `pg.client.query(...)` is more semantic in
    /// Postgres context; `pg.inner` is consistent across all Backplane
    /// `ManagedService` wrappers.
    public var inner: PostgresClient { client }

    private let runTask: Mutex<Task<Void, Never>?> = Mutex(nil)

    public init(client: PostgresClient) {
        self.client = client
    }

    /// Spawn the underlying client's run loop. Returns immediately.
    public func start() async throws {
        let task = Task<Void, Never> { [client] in
            await client.run()
        }
        runTask.withLock { $0 = task }
    }

    /// Cancel the run task and await its completion. Bounded by the
    /// graph's draining grace period; if `PostgresClient.run()` hangs
    /// past the grace, the graph cancels the surrounding task and the
    /// generation is leaked at the task level — see
    /// `docs/design/backplane.md` §7 "Recovering from a stuck
    /// instance".
    public func shutdown() async {
        let task = runTask.withLock { (state: inout Task<Void, Never>?) -> Task<Void, Never>? in
            let captured = state
            state = nil
            return captured
        }
        task?.cancel()
        await task?.value
    }
}

// MARK: - postgres key

extension Services {
    /// Service key for ``BackplanePostgresService``.
    ///
    /// Resolve via keypath from inside a service factory or task
    /// command:
    ///
    /// ```swift
    /// let pg = try await context.requireService(\.postgres)
    /// let result = try await pg.client.query("SELECT 1")
    /// ```
    public var postgres: ServiceKey<BackplanePostgresService> {
        ServiceKey(id: "postgres")
    }

    /// Deprecated alias for ``postgres``. Renamed in 1.1.0 to drop the
    /// `Key` suffix; both resolve the same entry (`id: "postgres"`).
    /// Removed in 2.0.0.
    @available(*, deprecated, renamed: "postgres")
    public var postgresKey: ServiceKey<BackplanePostgresService> {
        postgres
    }
}

// MARK: - Descriptor

/// Build a ``EntryDescriptor`` for a Postgres client.
///
/// The descriptor's factory reads connection parameters from the
/// `postgres` scope of the application's `ConfigReader` (supplied by
/// the graph via ``ServiceContext/config``). Required keys (depending
/// on connection mode):
///
/// - `postgres.host` (default `"localhost"`)
/// - `postgres.port` (default `5432`)
/// - `postgres.username` (default `"postgres"`)
/// - `postgres.password`
/// - `postgres.database`
/// - `postgres.unixSocketPath` (optional, mutually exclusive with host/port)
///
/// TLS options are read from `postgres.tls.*`. See
/// ``Postgres+Config`` for the full set.
///
/// ```swift
/// static func services() -> [EntryDescriptor] {
///     [postgresEntryDescriptor()]
/// }
/// ```
///
/// - Parameters:
///   - subgroup: subgroup tag for failure-policy partitioning.
///     Defaults to ``SubgroupTag/core``.
///   - dependencies: other entries this Postgres service's factory
///     resolves through `context.requireService(_:)`.
public func postgresEntryDescriptor(
    subgroup: SubgroupTag = .core,
    dependencies: [PartialKeyPath<Services>] = []
) -> EntryDescriptor {
    EntryDescriptor(
        \.postgres,
        subgroup: subgroup,
        dependencies: dependencies
    ) { context in
        let config = try context.requireConfig().scoped(to: "postgres")
        let pgConfig = PostgresClient.Configuration(config: config)
        let client = PostgresClient(configuration: pgConfig, backgroundLogger: context.logger)
        return BackplanePostgresService(client: client)
    }
}

#endif
