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

/// `BackplaneService` wrapper around `PostgresClient`.
///
/// The underlying `PostgresClient` is a `ServiceLifecycle.Service`
/// whose `run()` opens connections and stays running for the lifetime
/// of the service. This wrapper adapts it to the
/// `ManagedService` two-phase contract used by `ServiceGraph`:
/// `start()` spawns the client's run loop in a detached task and
/// returns immediately; `shutdown()` cancels the task and awaits its
/// termination.
///
/// Because the type conforms to `BackplaneService`, declaring
/// `\.postgres` in a command's `requiredServices` is all it takes — no
/// `services()` entry needed. ``make(context:)`` reads connection
/// parameters from the entry's config scope (the entry id, `postgres.*`
/// for the stock key). Required keys (depending on connection mode):
///
/// - `postgres.host` (default `"localhost"`)
/// - `postgres.port` (default `5432`)
/// - `postgres.username` (default `"postgres"`)
/// - `postgres.password`
/// - `postgres.database`
/// - `postgres.unixSocketPath` (optional, mutually exclusive with host/port)
///
/// TLS options are read from `postgres.tls.*`. See
/// `Postgres+Config.swift` for the full set.
///
/// **Multi-instance:** register a second key with a different id and
/// the same type — its entry reads its own config scope:
///
/// ```swift
/// extension Services {
///     public var analyticsDB: ServiceKey<BackplanePostgresService> {
///         ServiceKey(id: "analytics")     // reads analytics.host, …
///     }
/// }
/// ```
///
/// **Readiness:** `PostgresClient.run()` has no "client is ready"
/// signal. `start()` returns once the run task has been scheduled, not
/// once a connection has been established. Code resolving the client
/// immediately after `start()` may see queries fail until the pool's
/// first connection is established. For production wiring, a thin
/// supervisor task can verify readiness (e.g. `SELECT 1`) and gate
/// dependent services with `HotReloadable`.
public final class BackplanePostgresService: BackplaneService, @unchecked Sendable {
    /// The wrapped `PostgresClient`. Resolve the service via
    /// ``Backplane/Services/postgres`` and access this property to drive queries.
    ///
    /// Aliased to ``inner`` for consumers that prefer the Backplane-wide
    /// `.inner` convention used by `LifecycleAdapter` and
    /// `PassiveService`.
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

    /// Build a client from the entry's config scope. The reader in
    /// `context.config` is already scoped to the entry id, so the same
    /// type serves any number of keys, each with its own scope.
    public static func make(context: BackplaneContext) async throws -> BackplanePostgresService {
        let config = try context.requireConfig()
        let pgConfig = PostgresClient.Configuration(config: config)
        let client = PostgresClient(configuration: pgConfig, backgroundLogger: context.logger)
        return BackplanePostgresService(client: client)
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
    /// The type conforms to `BackplaneService`, so naming this key in a
    /// command's `requiredServices` is the entire registration:
    ///
    /// ```swift
    /// var requiredServices: ServiceList { [\.postgres] }
    ///
    /// // …
    /// let pg = try await context.requireService(\.postgres)
    /// let result = try await pg.client.query("SELECT 1")
    /// ```
    ///
    /// To override the default subgroup or replacement strategy, add an
    /// explicit descriptor to `services()`:
    ///
    /// ```swift
    /// EntryDescriptor(\.postgres, subgroup: .integrations)
    /// ```
    public var postgres: ServiceKey<BackplanePostgresService> {
        ServiceKey(id: "postgres")
    }
}

#endif
