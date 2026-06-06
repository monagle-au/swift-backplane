//
//  ServiceKeyMacro.swift
//  swift-backplane
//

#if BACKPLANE_MACROS

/// Declare a service key on the ``Services`` namespace in one line.
///
/// `#service` is the opt-in shorthand for the hand-written pattern
///
/// ```swift
/// public var database: ServiceKey<PostgresClient> {
///     ServiceKey(id: "database")
/// }
/// ```
///
/// Used inside an `extension Services`, it expands to exactly that —
/// a `public var` returning a typed ``ServiceKey``:
///
/// ```swift
/// extension Services {
///     #service(PostgresClient.self)                       // var postgresClient, id "postgresClient"
///     #service(PostgresClient.self, id: "database")       // id override
///     #service(PostgresClient.self, name: "database")     // var database
///     #service((any AuditStore).self, name: "auditStore") // ServiceKey<any AuditStore>
/// }
/// ```
///
/// **Name derivation.** The property name defaults to the lower-cased
/// first letter of the type's trailing identifier (`PostgresClient` →
/// `postgresClient`, `any AuditStore` → `auditStore`). For a type the
/// macro can't reduce to a simple identifier — a generic such as
/// `PassiveService<PowerTopology>`, for instance — pass an explicit
/// `name:`; the macro emits a diagnostic otherwise.
///
/// **Identifier (`id`).** Defaults to the property name; override with
/// `id:` when you need a stable string distinct from the Swift name
/// (e.g. `"service.clickhouse-time-series"`).
///
/// **Access level.** The generated property is always `public` — the
/// common case for keys that cross a module boundary. If you need a
/// non-public key, hand-write the computed property instead.
///
/// Available only when the package's `Macros` trait is enabled, which
/// adds the build-time swift-syntax dependency.
@freestanding(declaration, names: arbitrary)
public macro service<Value: Sendable>(
    _ type: Value.Type,
    name: String? = nil,
    id: String? = nil
) = #externalMacro(module: "BackplaneMacros", type: "ServiceKeyMacro")

#endif
