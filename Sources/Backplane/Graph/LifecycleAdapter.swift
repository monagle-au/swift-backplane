//
//  LifecycleAdapter.swift
//  swift-backplane
//

import ServiceLifecycle
import Synchronization

/// Generic adapter that wraps a `ServiceLifecycle.Service`-conforming
/// inner type as a `ManagedService` suitable for registration with a
/// ``ServiceGraph``.
///
/// `start()` spawns a detached task running `inner.run()`; `shutdown()`
/// cancels that task and awaits its completion. The inner instance
/// itself is exposed via ``inner`` so consumers reach for the
/// resource directly (`adapter.inner.someAPI(...)`).
///
/// Use this when a third-party (or consumer-owned) type already
/// conforms to `Service` and you want it managed by the graph without
/// writing the same start/cancel boilerplate every time:
///
/// ```swift
/// let firebaseKey = ServiceKey<LifecycleAdapter<FirebasePublicKeys>>(id: "firebase")
///
/// public func firebaseEntryDescriptor() -> EntryDescriptor {
///     EntryDescriptor(firebaseKey) { context in
///         let keys = FirebasePublicKeys(...)
///         return LifecycleAdapter(keys)
///     }
/// }
///
/// // At a call site:
/// let svc = try await context.requireService(firebaseKey)
/// svc.inner.verify(token)
/// ```
///
/// When the inner type warrants a more semantic accessor name
/// (`.client`, `.server`, etc.), write a thin domain wrapper that
/// holds a `LifecycleAdapter` internally and exposes the alias —
/// see `BackplanePostgresService` for an example.
///
/// ## Type-erased inner via `AnyService`
///
/// Inner types with generic parameters that don't survive as a
/// stored property (e.g. `GRPCServer<HTTP2ServerTransport.Posix>`,
/// Hummingbird's `Application<RequestContext>`) compose cleanly with
/// `LifecycleAdapter` by going through ``AnyService`` first:
///
/// ```swift
/// let server = GRPCServer(transport: ...)
/// let descriptor = EntryDescriptor(grpcKey) { _ in
///     LifecycleAdapter(AnyService(server))   // <- erase generics, then adapt
/// }
/// ```
///
/// `AnyService` conforms to `Service & Sendable`, satisfying the
/// adapter's constraint. The key type becomes
/// `ServiceKey<LifecycleAdapter<AnyService>>` — slightly cumbersome,
/// but the alternative (preserving the inner generic through the
/// graph) leaks the inner's transport / request-context parameters
/// into every resolution call.
public final class LifecycleAdapter<S: Service & Sendable>: ManagedService, @unchecked Sendable {
    public let inner: S

    private let runTask: Mutex<Task<Void, Never>?> = Mutex(nil)

    public init(_ inner: S) {
        self.inner = inner
    }

    public func start() async throws {
        let task = Task<Void, Never> { [inner] in
            try? await inner.run()
        }
        runTask.withLock { $0 = task }
    }

    public func shutdown() async {
        let task = runTask.withLock { (state: inout Task<Void, Never>?) -> Task<Void, Never>? in
            let captured = state
            state = nil
            return captured
        }
        task?.cancel()
        await task?.value
    }
}
