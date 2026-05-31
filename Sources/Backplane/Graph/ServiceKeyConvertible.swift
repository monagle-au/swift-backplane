//
//  ServiceKeyConvertible.swift
//  swift-backplane
//

/// Existential the framework uses to recover the type-erased identity
/// of a service key from a `PartialKeyPath<Services>` value.
///
/// `ServiceKey<T>` is the only conforming type — every consumer-defined
/// keypath into ``Services`` resolves to a `ServiceKey<T>` for some
/// `T`. At dependency-list resolution time the framework reads
/// `Services()[keyPath: kp]`, casts the result to
/// `any ServiceKeyConvertible`, and asks for ``anyServiceKey`` to
/// obtain the ``AnyServiceKey`` identity the graph indexes on.
///
/// Not consumer-facing — present in the public surface only so the
/// keypath-erasure cast can succeed across module boundaries.
public protocol ServiceKeyConvertible: Sendable {
    /// The type-erased ``AnyServiceKey`` identity for this key.
    var anyServiceKey: AnyServiceKey { get }
}

extension ServiceKey: ServiceKeyConvertible {
    public var anyServiceKey: AnyServiceKey {
        AnyServiceKey(self)
    }
}
