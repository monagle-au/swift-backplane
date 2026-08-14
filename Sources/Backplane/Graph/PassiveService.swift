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
/// resolution.
///
/// You rarely name `PassiveService` directly. Register the passive
/// value with the `passive:` initialiser on ``EntryDescriptor`` — the
/// graph wraps it for lifecycle and unwraps it on resolution, so the
/// key's `Value` is the value itself, not the wrapper:
///
/// ```swift
/// let kmsKey = ServiceKey<KMSClient>(id: "kms")
///
/// public func kmsEntryDescriptor() -> EntryDescriptor {
///     EntryDescriptor(kmsKey) { context in     // passive: label
///         KMSClient(...)
///     }
/// }
///
/// // At a call site — no `.inner`, the resolved value is the client:
/// let kms = try await context.requireService(kmsKey)
/// try await kms.encrypt(payload)
/// ```
///
/// Because the `Value` can be a protocol existential, `passive:` also
/// keys a protocol against a concrete passive implementation — see
/// ``EntryDescriptor/init(_:subgroup:dependencies:replacement:passive:)-(ServiceKey<Value>,_,_,_,_)``.
///
/// For types that *do* have a run loop, prefer ``LifecycleAdapter``;
/// to project a concrete `ManagedService` onto a protocol key, use the
/// `factory:as:` initialiser on ``EntryDescriptor``.
public final class PassiveService<T: Sendable>: ManagedService, @unchecked Sendable {
    public let inner: T

    public init(_ inner: T) {
        self.inner = inner
    }

    public func start() async throws {}
    public func shutdown() async {}
}
