//
//  Services.swift
//  swift-backplane
//

/// The canonical namespace for service entry declarations.
///
/// Consumers extend `Services` with computed instance properties
/// returning a typed ``ServiceKey``. The properties are then
/// addressable via keypath, which gives autocomplete-driven
/// references at every use site:
///
/// ```swift
/// extension Services {
///     public var database: ServiceKey<PostgresClient> {
///         ServiceKey(id: "database")
///     }
/// }
///
/// // Resolution — `T` is inferred from the keypath's Value:
/// let db = try await context.requireService(\.database)
///
/// // Dependency list — keypaths erase to PartialKeyPath<Services>:
/// var requiredServices: [PartialKeyPath<Services>] {
///     [\.database]
/// }
/// ```
///
/// A key's resolved `Value` need not be the registered concrete type.
/// It can be a protocol existential — register the concrete passive
/// value with `EntryDescriptor`'s `passive:` initialiser, or project a
/// concrete ``ManagedService`` onto the protocol with `factory:as:`:
///
/// ```swift
/// extension Services {
///     public var auditStore: ServiceKey<any AuditStore> {
///         ServiceKey(id: "audit-store")
///     }
/// }
///
/// // The concrete ClickHouseAuditStore never appears at the call site:
/// let audit: any AuditStore = try await context.requireService(\.auditStore)
/// ```
///
/// The type is `Sendable` and has a public initialiser so the
/// framework can instantiate one at the keypath-resolution boundary.
/// Consumers never construct it explicitly — the `\.…` keypath syntax
/// handles that.
public struct Services: Sendable {
    public init() {}
}
