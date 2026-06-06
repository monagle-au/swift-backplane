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
///     public var database: ServiceKey<PostgresClient> { "database" }
/// }
///
/// let db = try await context.requireService(\.database)
/// ```
///
/// `ServiceKey` is `ExpressibleByStringLiteral`, so a declaration body is
/// just the `id` string. `ServiceKey(id: "database")` and `"database"`
/// are equivalent; the literal form keeps the per-key line to the three
/// things that matter — property name, resolved type, and the id (which
/// also drives the entry's `ConfigReader` scope).
///
/// `Value` is the *resolved* type, which need not equal the registered
/// concrete type — it can be a protocol existential backed by a concrete
/// registration. See ``EntryDescriptor``'s `passive:` and `factory:as:`
/// initialisers.
///
/// With the package's `Macros` trait enabled, the `#service` macro is the
/// opt-in shorthand for the computed-property declaration above:
///
/// ```swift
/// extension Services {
///     #service(PostgresClient.self, name: "database")
/// }
/// ```
public struct ServiceKey<Value: Sendable>: Hashable, Sendable {
    /// Stable string identity. Drives log labels, entry lookup, and the
    /// entry's `ConfigReader` scope prefix.
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

extension ServiceKey: ExpressibleByStringLiteral {
    /// Construct a key from its `id` string literal — the terse form used
    /// in a `Services` declaration body, e.g.
    /// `var database: ServiceKey<PostgresClient> { "database" }`.
    public init(stringLiteral value: String) {
        self.id = value
    }
}
