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
///     public var databaseKey: ServiceKey<PostgresClient> {
///         ServiceKey(id: "database")
///     }
/// }
///
/// // Resolution — `T` is inferred from the keypath's Value:
/// let db = try await context.requireService(\.databaseKey)
///
/// // Dependency list — keypaths erase to PartialKeyPath<Services>:
/// var requiredServices: [PartialKeyPath<Services>] {
///     [\.databaseKey]
/// }
/// ```
///
/// The type is `Sendable` and has a public initialiser so the
/// framework can instantiate one at the keypath-resolution boundary.
/// Consumers never construct it explicitly — the `\.…` keypath syntax
/// handles that.
public struct Services: Sendable {
    public init() {}
}
