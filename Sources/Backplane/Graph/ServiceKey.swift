//
//  ServiceKey.swift
//  swift-backplane
//

/// A phantom-typed identity for a service entry in a ``ServiceGraph``.
///
/// The `Value` type parameter enforces that ``ServiceGraph/resolve(_:)``
/// returns the right type at the call site without a dynamic cast visible
/// to callers. Entries are stored by `key.id` (a `String`) internally.
///
/// Consumers don't usually construct a `ServiceKey` at the call site —
/// they declare one as a computed property on the ``Services`` namespace
/// and address it by keypath:
///
/// ```swift
/// extension Services {
///     public var database: ServiceKey<PostgresClient> {
///         ServiceKey(id: "database")
///     }
/// }
///
/// let db = try await context.requireService(\.database)
/// ```
///
/// `Value` is the *resolved* type, which need not equal the registered
/// concrete type — it can be a protocol existential backed by a concrete
/// registration. See ``EntryDescriptor``'s `passive:` and `factory:as:`
/// initialisers.
public struct ServiceKey<Value: Sendable>: Hashable, Sendable {
    /// Stable string identity. Drives log labels and entry lookup.
    public let id: String

    public init(id: String) {
        self.id = id
    }
}
