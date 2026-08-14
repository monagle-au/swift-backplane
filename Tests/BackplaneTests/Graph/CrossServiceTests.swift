//
//  CrossServiceTests.swift
//  swift-backplane
//
//  Tests for cross-service resolution via BackplaneContext in the
//  ServiceGraph spike.
//

import Foundation
import Logging
import Synchronization
import Testing
@testable import Backplane

// MARK: - Test doubles

/// A simple identity-bearing service. start() and shutdown() are no-ops.
final class IdentityService: ManagedService, @unchecked Sendable {
    let instanceID = UUID()

    func start() async throws { }
    func shutdown() async { }
}

/// A service whose start() sleeps for a configurable delay, so cross-service
/// resolution can verify that requireService() genuinely waited.
final class SlowStartService: ManagedService, @unchecked Sendable {
    let instanceID = UUID()
    let startDelay: Duration

    init(startDelay: Duration) { self.startDelay = startDelay }

    func start() async throws {
        try await Task.sleep(for: startDelay, clock: .continuous)
    }
    func shutdown() async { }
}

/// A service whose factory resolves another service via `requireService`
/// and captures the resolved instance for the test to introspect.
final class ResolvingService<Resolved: ManagedService>: ManagedService, @unchecked Sendable {
    let instanceID = UUID()
    let resolved: Resolved
    /// The wall-clock instants captured by the factory — used by the
    /// concurrent-boot test to assert that requireService genuinely waited.
    let factoryStartedAt: Date
    let resolvedReturnedAt: Date

    init(resolved: Resolved, factoryStartedAt: Date, resolvedReturnedAt: Date) {
        self.resolved = resolved
        self.factoryStartedAt = factoryStartedAt
        self.resolvedReturnedAt = resolvedReturnedAt
    }

    func start() async throws { }
    func shutdown() async { }
}

/// A service whose factory captures its `BackplaneContext`, exposing it
/// for the test to use after boot. Allows the test to call `.service(_:)`
/// from a real context (rather than constructing one inline).
final class TapService: ManagedService, @unchecked Sendable {
    let context: BackplaneContext

    init(context: BackplaneContext) { self.context = context }

    func start() async throws { }
    func shutdown() async { }
}

/// A one-shot gate the test can release at a chosen moment.
///
/// Handles the "release before wait" race gracefully: `wait()` returns
/// immediately if `release()` was already called.
actor StartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { cont in
            self.continuation = cont
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// A service whose start() either returns immediately (gate == nil) or
/// blocks on a `StartGate` until the test releases it.
///
/// Used by test 5 to deterministically observe an entry in `.replacing`.
final class MaybeBlockingService: ManagedService, @unchecked Sendable {
    let instanceID = UUID()
    let gate: StartGate?

    init(gate: StartGate? = nil) { self.gate = gate }

    func start() async throws {
        if let gate { await gate.wait() }
    }

    func shutdown() async { }
}

/// A null lifecycle handle for tests that need to construct a
/// ``BackplaneContext`` inline without referencing a specific entry.
struct NullLifecycleHandle: ServiceLifecycleHandle {
    var state: ServiceState { .unconfigured }
    func stateStream() -> AsyncStream<ServiceState> { AsyncStream { $0.finish() } }
    func requestRestart() async { }
}

/// Companion to ``NullLifecycleHandle`` for tests that construct a
/// ``BackplaneContext`` inline without a real entry.
struct NullHealthReporter: ServiceHealthReporter {
    func markDegraded(fault: ServiceFault) { }
    func markHealthy() { }
}

// MARK: - Helpers

private func waitFor(
    _ id: String,
    in graph: ServiceGraph,
    timeout: Duration = .seconds(5),
    predicate: (ServiceState) -> Bool
) async throws {
    let start = ContinuousClock.now
    for await state in graph.stateStream(of: id) {
        if predicate(state) { return }
        if ContinuousClock.now - start > timeout {
            throw TestTimeoutError(last: state)
        }
    }
}

private struct TestTimeoutError: Error { let last: ServiceState }

// MARK: - Suite

@Suite("ServiceGraph — cross-service resolution")
struct CrossServiceTests {

    // MARK: Test 1 — requireService returns the live instance

    /// `requireService(\.a)` from B's factory returns A's live instance.
    @Test("requireService returns the live instance once the target is running")
    func testRequireServiceReturnsLiveInstance() async throws {
        let keyA = ServiceKey<IdentityService>(id: "a")
        let keyB = ServiceKey<ResolvingService<IdentityService>>(id: "b")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(keyA) { _ in
                IdentityService()
            },
            EntryDescriptor(keyB) { context in
                let started = Date()
                let a: IdentityService = try await context.requireService(keyA)
                return ResolvingService(
                    resolved: a,
                    factoryStartedAt: started,
                    resolvedReturnedAt: Date()
                )
            },
        ])

        try await graph.boot()

        let aLive = graph.resolve(keyA)
        let bLive = graph.resolve(keyB)
        #expect(aLive != nil)
        #expect(bLive != nil)
        #expect(bLive!.resolved.instanceID == aLive!.instanceID,
                "B's captured resolved-A must equal the graph's live A")

        #expect(graph.state(of: keyA.id) == .running)
        #expect(graph.state(of: keyB.id) == .running)
    }

    // MARK: Test 2 — requireService waits for the target's factory

    /// B's factory runs concurrently with A's boot. A's *factory* sleeps
    /// 80 ms. B's factory must observe at least that delay before
    /// `requireService(\.a)` returns.
    ///
    /// Note: post slice-5a (boot-deadlock fix), `requireService` no longer
    /// waits for `start()` to complete — it waits for the factory to
    /// return and the active generation to be swapped in. The slow part
    /// of the dependency is the factory accordingly.
    @Test("requireService waits for the target's factory to complete")
    func testRequireServiceWaitsForConcurrentBoot() async throws {
        let keyA = ServiceKey<IdentityService>(id: "a-slow-factory")
        let keyB = ServiceKey<ResolvingService<IdentityService>>(id: "b-resolver")

        let aFactoryDelay: Duration = .milliseconds(80)

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(keyA) { _ in
                // Slow factory — no instance stashed during the sleep, so
                // B's requireService cannot resolve early.
                try await Task.sleep(for: aFactoryDelay, clock: .continuous)
                return IdentityService()
            },
            EntryDescriptor(keyB) { context in
                let started = Date()
                let a: IdentityService = try await context.requireService(keyA)
                return ResolvingService(
                    resolved: a,
                    factoryStartedAt: started,
                    resolvedReturnedAt: Date()
                )
            },
        ])

        try await graph.boot()

        let b = graph.resolve(keyB)
        #expect(b != nil)

        let elapsed = b!.resolvedReturnedAt.timeIntervalSince(b!.factoryStartedAt)

        // B's factory should have waited at least A's factory delay, minus
        // a small tolerance for scheduling jitter.
        #expect(elapsed >= 0.070,
                "B's factory should have waited at least ~80 ms for A's factory; observed \(elapsed * 1000) ms")
    }

    // MARK: Test 3 — sync resolve returns nil before boot

    /// Pre-boot: `graph.resolve(_:)` and a fresh `BackplaneContext.service(_:)`
    /// both return nil. Post-boot: both return the live instance.
    @Test("synchronous service(_:) returns nil before boot, live instance after")
    func testSynchronousServiceReturnsNilBeforeBoot() async throws {
        let key = ServiceKey<IdentityService>(id: "x")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key) { _ in IdentityService() },
        ])

        // Pre-boot: graph.resolve returns nil.
        #expect(graph.resolve(key) == nil)

        // Construct a context inline using the package init. The
        // lifecycle handle is irrelevant for this test — only the graph
        // reference matters for forwarding `service(_:)`.
        let context = BackplaneContext(
            entryID: "test-driver",
            logger: Logger(label: "test"),
            lifecycle: NullLifecycleHandle(),
            health: NullHealthReporter(),
            graph: graph
        )

        #expect(context.service(key) == nil)

        // Post-boot: both return the live instance.
        try await graph.boot()

        let viaGraph = graph.resolve(key)
        let viaContext = context.service(key)
        #expect(viaGraph != nil)
        #expect(viaContext != nil)
        #expect(viaGraph!.instanceID == viaContext!.instanceID,
                "the two paths must return the same live instance")
    }

    // MARK: Test 4 — requireService throws for unknown key

    /// A factory that calls `requireService(unknownKey)` propagates a
    /// `ServiceGraphError.missingService` through to the entry's
    /// `.failed` state.
    @Test("requireService throws missingService when the target is unregistered")
    func testRequireServiceThrowsForUnknownKey() async throws {
        let registered = ServiceKey<ResolvingService<IdentityService>>(id: "b")
        let unknown = ServiceKey<IdentityService>(id: "does-not-exist")

        // Use .integrations so the entry's failure stays isolated (degraded
        // mode). In .core the failFast policy would propagate as a
        // .subgroupBootFailed throw — distinct from this test's intent,
        // which is to verify `requireService` error propagation into the
        // entry's `.failed` state.
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(registered, subgroup: .integrations) { context in
                // This call must throw — the unknown key has no descriptor.
                let stub: IdentityService = try await context.requireService(unknown)
                // Should never be reached.
                return ResolvingService(
                    resolved: stub,
                    factoryStartedAt: Date(),
                    resolvedReturnedAt: Date()
                )
            },
        ])

        try await graph.boot()

        let state = graph.state(of: registered.id)
        guard case .failed(let fault) = state else {
            Issue.record("Expected .failed; got \(state)")
            return
        }

        #expect(fault.errorType.contains("ServiceGraphError"),
                "errorType should reflect ServiceGraphError; got: \(fault.errorType)")
        #expect(fault.description.contains("missingService"),
                "description should mention .missingService; got: \(fault.description)")
    }

    // MARK: Test 6 — requireService honours its timeout

    /// When the target's *factory* is slow (so no instance has been
    /// stashed and `currentHandle` is nil during `.starting`), a bounded
    /// `requireService` call throws `.timedOut` rather than waiting
    /// indefinitely.
    ///
    /// Note: prior to the boot-deadlock fix (slice 5a) this test used a
    /// slow `start()` to model "service not yet ready." With the
    /// `.starting`+instance fix, `start()` running is no longer a barrier
    /// to resolution — the factory completing *is*. The slow part has
    /// moved into the factory accordingly.
    @Test("requireService throws .timedOut when the target's factory hasn't returned in time")
    func testRequireServiceHonoursTimeout() async throws {
        let key = ServiceKey<IdentityService>(id: "slow-factory")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key) { _ in
                // Slow factory: nothing is stashed yet; the entry is in
                // `.starting` but currentHandle remains nil.
                try await Task.sleep(for: .milliseconds(500), clock: .continuous)
                return IdentityService()
            },
        ])

        // Boot in the background — factory will sleep 500 ms.
        let bootTask = Task { try await graph.boot() }

        // Query with a 50 ms timeout — should fire well before factory completes.
        let timeoutDuration: Duration = .milliseconds(50)
        let started = ContinuousClock.now
        do {
            let _: IdentityService = try await graph.requireService(key, timeout: timeoutDuration)
            Issue.record("Expected requireService to throw .timedOut")
        } catch let error as ServiceGraphError {
            guard case .timedOut(let id, _, let after) = error else {
                Issue.record("Expected .timedOut; got \(error)")
                return
            }
            #expect(id == key.id)
            #expect(after == timeoutDuration)
        }
        let elapsed = ContinuousClock.now - started

        // Verify we waited about the timeout duration — not longer.
        // Lower bound: timeout was honoured (we did wait).
        // Upper bound: we didn't end up waiting for the factory.
        #expect(elapsed >= timeoutDuration,
                "expected to wait at least \(timeoutDuration); waited \(elapsed)")
        #expect(elapsed < .milliseconds(400),
                "expected timeout to fire well before factory completes; waited \(elapsed)")

        // Let boot finish so the test cleans up.
        try await bootTask.value

        // After boot, requireService returns the live instance without timing out.
        let live: IdentityService = try await graph.requireService(key, timeout: .seconds(1))
        #expect(live.instanceID == graph.resolve(key)!.instanceID,
                "post-boot requireService should return the live instance")
    }

    // MARK: Test 5 — synchronous service(_:) returns old generation during .replacing

    /// During a blue-green replacement, `context.service(\.a)` returns
    /// the *old* generation. After the swap, it returns the new one.
    /// This validates that the no-gap property holds at the
    /// `BackplaneContext` resolution layer.
    @Test("service(_:) returns old generation during .replacing; new generation after swap")
    func testServiceResolvesOldGenerationDuringReplacement() async throws {
        let keyA = ServiceKey<MaybeBlockingService>(id: "a")
        let keyTap = ServiceKey<TapService>(id: "tap")

        // First boot: no gate (start returns immediately). Restart:
        // start() blocks on this gate until the test releases it.
        let restartGate = StartGate()
        let callCount = Mutex<Int>(0)

        let aFactory: @Sendable (BackplaneContext) async throws -> MaybeBlockingService = { _ in
            let n = callCount.withLock { c -> Int in c += 1; return c }
            return MaybeBlockingService(gate: n == 1 ? nil : restartGate)
        }

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(keyA, subgroup: .integrations, replacement: .blueGreen(grace: .milliseconds(50)), factory: aFactory),
            EntryDescriptor(keyTap) { ctx in TapService(context: ctx) },
        ])

        try await graph.boot()

        let tap = graph.resolve(keyTap)!
        let gen1ID = tap.context.service(keyA)!.instanceID
        #expect(graph.state(of: keyA.id) == .running)

        // Trigger restart — the new generation's start() will block on the gate.
        await graph.restart(at: keyA.id)

        // Wait for the entry to land in .replacing.
        try await waitFor(keyA.id, in: graph) { $0 == .replacing }

        // While in .replacing, context.service(\.a) must return the old generation.
        let duringReplacing = tap.context.service(keyA)
        #expect(duringReplacing != nil)
        #expect(duringReplacing!.instanceID == gen1ID,
                "during .replacing, context.service must return the old generation")

        // Release the gate so the new generation's start() can complete.
        await restartGate.release()

        // Wait for the swap to complete.
        try await waitFor(keyA.id, in: graph) { $0 == .running }

        // After swap, context.service(\.a) returns the new generation.
        let afterSwap = tap.context.service(keyA)
        #expect(afterSwap != nil)
        #expect(afterSwap!.instanceID != gen1ID,
                "after .running, context.service must return the new generation")
    }
}
