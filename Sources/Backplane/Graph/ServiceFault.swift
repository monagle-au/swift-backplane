//
//  ServiceFault.swift
//  swift-backplane
//

import Foundation

/// A `Sendable`, `Hashable` description of a service fault.
///
/// Carried by ``ServiceState/degraded(fault:)`` and
/// ``ServiceState/failed(fault:)``. Using a value-type description rather
/// than `any Error` directly keeps ``ServiceState`` `Hashable` —
/// necessary for stream-subscriber deduplication and state-comparison
/// across concurrency boundaries.
public struct ServiceFault: Sendable, Hashable {
    /// Human-readable description, typically `String(describing: error)`.
    public let description: String

    /// Reflected type name of the underlying error, e.g. `"PostgresError"`.
    public let errorType: String

    /// The instant the fault was first observed.
    public let firstObservedAt: Date

    /// Number of consecutive failures since `firstObservedAt`.
    public let consecutiveCount: Int

    public init(
        description: String,
        errorType: String,
        firstObservedAt: Date,
        consecutiveCount: Int = 1
    ) {
        self.description = description
        self.errorType = errorType
        self.firstObservedAt = firstObservedAt
        self.consecutiveCount = consecutiveCount
    }

    /// Build a fault description from any `Error`.
    public init(from error: any Error, at instant: Date = Date()) {
        self.description = String(describing: error)
        self.errorType = String(reflecting: type(of: error))
        self.firstObservedAt = instant
        self.consecutiveCount = 1
    }
}
