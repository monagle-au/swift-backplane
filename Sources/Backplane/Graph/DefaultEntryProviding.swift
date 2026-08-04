//
//  DefaultEntryProviding.swift
//  swift-backplane
//

/// Existential the framework uses to recover a default
/// ``EntryDescriptor`` from a type-erased key whose `Value` conforms to
/// ``BackplaneService``.
///
/// `ServiceKey<T> where T: BackplaneService` is the only conforming
/// type. At materialisation time the framework reads
/// `Services()[keyPath: kp]` and casts the result to
/// `any DefaultEntryProviding` — runtime casts honour the conditional
/// conformance — to ask for ``defaultDescriptor``.
///
/// Not consumer-facing — present in the public surface only so the
/// keypath-erasure cast can succeed across module boundaries (the same
/// pattern as ``ServiceKeyConvertible``).
public protocol DefaultEntryProviding: Sendable {
    /// The descriptor the graph materialises when this key is required
    /// but not explicitly registered.
    var defaultDescriptor: EntryDescriptor { get }
}

extension ServiceKey: DefaultEntryProviding where Value: BackplaneService {
    public var defaultDescriptor: EntryDescriptor {
        EntryDescriptor(self)
    }
}
