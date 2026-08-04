//
//  ServiceList.swift
//  swift-backplane
//

/// An ordered list of ``Services``-rooted key paths — the currency for
/// declaring which services something needs.
///
/// Used by ``BackplaneCommand``'s `requiredServices`,
/// ``BackplaneService/dependencies``, and ``EntryDescriptor``'s
/// keypath-flavoured `dependencies:` parameters. Build one from an
/// array literal or variadically:
///
/// ```swift
/// var requiredServices: ServiceList { [\.postgres, \.http] }
/// static var dependencies: ServiceList { ServiceList(\.postgres) }
/// ```
///
/// `ServiceList` exists so the raw element type —
/// `PartialKeyPath<Services> & Sendable`, the Sendable-constrained
/// composition Swift 6 requires for key paths that cross isolation —
/// never appears in a consumer-facing signature. Key-path literals
/// satisfy the constraint automatically.
public struct ServiceList: Sendable, ExpressibleByArrayLiteral {
    /// The element type: a `Services`-rooted partial key path that is
    /// provably `Sendable` (every key-path literal is).
    public typealias Element = PartialKeyPath<Services> & Sendable

    /// The listed key paths, in declaration order.
    public let elements: [Element]

    /// Variadic form: `ServiceList(\.postgres, \.http)`.
    public init(_ elements: Element...) {
        self.elements = elements
    }

    /// Array form, for call sites that already hold a list.
    public init(_ elements: [Element]) {
        self.elements = elements
    }

    /// Array-literal form: `[\.postgres, \.http]`.
    public init(arrayLiteral elements: Element...) {
        self.elements = elements
    }

    /// True when the list names no services.
    public var isEmpty: Bool { elements.isEmpty }
}

extension ServiceList: Sequence {
    public func makeIterator() -> IndexingIterator<[Element]> {
        elements.makeIterator()
    }
}
