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
/// In Backplane 2.0 the consumer-facing identity is the `@Register`
/// macro-generated keypath over the ``Services`` namespace; `ServiceKey<T>`
/// is the type-erased back-end the macro lowers to.
public struct ServiceKey<Value: Sendable>: Hashable, Sendable {
    /// Stable string identity. Drives log labels and entry lookup.
    public let id: String

    public init(id: String) {
        self.id = id
    }
}
