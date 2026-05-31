//
//  PassiveService.swift
//  swift-backplane
//

/// Generic `ManagedService` wrapper for a passive value — anything that
/// has no lifecycle of its own and is just held by the graph for
/// resolution.
///
/// `start()` and `shutdown()` are no-ops; the graph keeps the wrapper
/// alive for the duration of the surrounding `ServiceGroup`, so any
/// in-memory state on `inner` persists across resolutions.
///
/// Use when an actor or value doesn't need a `run()` loop (no
/// background refresh, no listening socket, no internal scheduler) but
/// you want it registered with the graph for typed cross-service
/// resolution:
///
/// ```swift
/// let kmsKey = ServiceKey<PassiveService<KMSClient>>(id: "kms")
///
/// public func kmsEntryDescriptor() -> EntryDescriptor {
///     EntryDescriptor(kmsKey) { context in
///         let client = KMSClient(...)
///         return PassiveService(client)
///     }
/// }
///
/// // At a call site:
/// let svc = try await context.requireService(kmsKey)
/// try await svc.inner.encrypt(payload)
/// ```
///
/// For types that *do* have a run loop, prefer ``LifecycleAdapter``.
public final class PassiveService<T: Sendable>: ManagedService, @unchecked Sendable {
    public let inner: T

    public init(_ inner: T) {
        self.inner = inner
    }

    public func start() async throws {}
    public func shutdown() async {}
}
