//
//  AnyServiceKey.swift
//  swift-backplane
//

/// Type-erased ``ServiceKey`` for collections that mix keys with different
/// `Value` types — notably dependency lists on ``EntryDescriptor``.
///
/// Identity is the underlying string id; the typed `Value` is dropped.
/// Equality and hashing operate on `id` alone, which is the only piece
/// the graph needs to compute the dependency closure and detect cycles.
public struct AnyServiceKey: Sendable, Hashable {
    /// Stable string identity, matching ``ServiceKey/id``.
    public let id: String

    /// Erase a typed ``ServiceKey`` to its identity.
    public init<T: Sendable>(_ key: ServiceKey<T>) {
        self.id = key.id
    }

    /// Convenience for call-sites that already hold a string id.
    public init(id: String) {
        self.id = id
    }

    /// Erase from a ``Services``-rooted keypath.
    ///
    /// Used wherever a dependency list of `PartialKeyPath<Services>`
    /// needs to land in a graph-internal `[AnyServiceKey]`. Traps if
    /// the keypath's value type is not a ``ServiceKey`` — every
    /// ``Services`` extension property should return one, so a trap
    /// here indicates an extension declared with the wrong type.
    public init(keyPath: PartialKeyPath<Services>) {
        let value = Services()[keyPath: keyPath]
        guard let convertible = value as? any ServiceKeyConvertible else {
            fatalError(
                "PartialKeyPath<Services> at \(keyPath) does not resolve to a ServiceKey<T>. " +
                "Every Services extension property must return ServiceKey<Value>."
            )
        }
        self = convertible.anyServiceKey
    }
}
