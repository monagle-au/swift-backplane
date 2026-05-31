//
//  BootDeadlockTests.swift
//  swift-backplane
//
//  Tests for the boot-deadlock fix in the ServiceGraph spike.
//  `bootEntry` swaps the active generation *before* calling `start()`, and
//  `requireService` treats `.starting`-with-instance as resolution-ready —
//  together they let factories whose `start()`s would otherwise serialise
//  resolve each other while their start tasks run concurrently.
//

import Foundation
import Synchronization
import Testing
@testable import Backplane

// MARK: - Suite

@Suite("ServiceGraph — boot-deadlock fix (.starting-with-instance)")
struct BootDeadlockTests {

    // MARK: Test 1 — factories cross-resolving don't wait for start()

    /// A's factory returns immediately; A's `start()` sleeps 200 ms.
    /// B's factory calls `requireService(\.a)` — must return *well before*
    /// A's `start()` completes, because A's instance is observable in
    /// `.starting` once the factory has swapped the active generation.
    /// This is the design-note §7 deadlock fix.
    @Test("B's requireService(\\.a) returns while A's start() is still running")
    func testFactoriesCrossResolvingDoNotDeadlock() async throws {
        let keyA = ServiceKey<SlowStartService>(id: "a")
        let keyB = ServiceKey<ResolvingService<SlowStartService>>(id: "b")

        let aStartDelay: Duration = .milliseconds(200)

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(
                keyA,
                subgroup: .integrations
            ) { _ in
                SlowStartService(startDelay: aStartDelay)
            },
            EntryDescriptor(
                keyB,
                subgroup: .integrations,
                dependencies: [AnyServiceKey(keyA)]
            ) { context in
                let started = Date()
                let a: SlowStartService = try await context.requireService(keyA)
                return ResolvingService(
                    resolved: a,
                    factoryStartedAt: started,
                    resolvedReturnedAt: Date()
                )
            },
        ])

        try await graph.boot()

        // Both reach .running.
        #expect(graph.state(of: keyA.id) == .running)
        #expect(graph.state(of: keyB.id) == .running)

        // B captured the live A.
        let aLive = graph.resolve(keyA)
        let bLive = graph.resolve(keyB)
        #expect(aLive != nil)
        #expect(bLive != nil)
        #expect(bLive!.resolved.instanceID == aLive!.instanceID,
                "B's captured A must equal the live A in the graph")

        // The critical assertion: B's requireService returned well before
        // A's start() completed (start() sleeps 200 ms; we cap at 150 ms).
        // Without the .starting+instance fix B would have to wait ~200 ms.
        let elapsed = bLive!.resolvedReturnedAt.timeIntervalSince(bLive!.factoryStartedAt)
        #expect(elapsed < 0.150,
                "B's factory must return before A's start() completes; observed \(elapsed * 1000) ms (start() sleeps 200 ms)")
    }

    // MARK: Test 2 — resolve returns the live handle during .starting

    /// A service whose `start()` blocks on a gate stays in `.starting`
    /// until the test releases the gate. While in `.starting`,
    /// `graph.resolve(\.a)` must return the live instance. This is the
    /// observable enabled by the bootEntry-order change.
    @Test("resolve(_:) returns the live handle during .starting")
    func testResolveReturnsLiveHandleDuringStartingState() async throws {
        let key = ServiceKey<MaybeBlockingService>(id: "gated")
        let gate = StartGate()

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                MaybeBlockingService(gate: gate)
            },
        ])

        // Boot in the background — the entry will park in .starting on the gate.
        let bootTask = Task { try await graph.boot() }

        // Poll resolve until non-nil. This is the moment `bootEntry` has
        // run the factory and swapped the active generation; the entry is
        // still in `.starting` because `start()` is blocked on the gate.
        // (We can't just watch the stateStream for `.starting` because the
        // transition to `.starting` happens *before* the factory runs —
        // observing the state alone doesn't tell us the swap has happened.)
        let pollStart = ContinuousClock.now
        var liveInstance: MaybeBlockingService?
        while liveInstance == nil {
            liveInstance = graph.resolve(key)
            if liveInstance != nil { break }
            if ContinuousClock.now - pollStart > .seconds(2) {
                Issue.record("Timed out waiting for resolve(_:) to become non-nil during .starting")
                return
            }
            try await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }

        let startingInstanceID = liveInstance!.instanceID

        // At this moment, the entry must still be in .starting — start()
        // is gated, so the transition to .running hasn't happened.
        #expect(graph.state(of: key.id) == .starting,
                "expected .starting when resolve becomes non-nil (start() is gated); got \(graph.state(of: key.id))")

        // Release the gate; entry transitions to .running.
        await gate.release()
        try await waitFor(key.id, in: graph) { $0 == .running }
        try await bootTask.value

        // The same instance is now served from .running.
        let afterRunning = graph.resolve(key)
        #expect(afterRunning != nil)
        #expect(afterRunning!.instanceID == startingInstanceID,
                "the running instance must be the same one that was observable during .starting")
    }

    // MARK: Test 3 — requireService resolves a .starting entry from outside

    /// External (non-factory) caller of `requireService` against a gated
    /// service in `.starting`. Must return the live instance immediately
    /// rather than waiting for `start()` — the §7 semantic applies to
    /// every caller, not just factories.
    @Test("requireService from outside resolves a .starting entry")
    func testRequireServiceResolvesStartingEntryFromExternalCaller() async throws {
        let key = ServiceKey<MaybeBlockingService>(id: "gated-ext")
        let gate = StartGate()

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                MaybeBlockingService(gate: gate)
            },
        ])

        let bootTask = Task { try await graph.boot() }

        // Wait until the entry is in .starting (i.e. factory has run and
        // swapped the active generation; start() is gated).
        try await waitFor(key.id, in: graph) { $0 == .starting }

        // requireService from this (external) context must return the
        // live instance well within the 2s timeout — the entry is in
        // .starting with a non-nil currentHandle, which is now
        // resolution-ready.
        let started = ContinuousClock.now
        let resolved = try await graph.requireService(key, timeout: .seconds(2))
        let elapsed = ContinuousClock.now - started

        // Should return promptly (the handle is already available), well
        // under the timeout.
        #expect(elapsed < .milliseconds(100),
                "requireService should return promptly while .starting; took \(elapsed)")

        let resolvedID = resolved.instanceID

        // Release the gate and let boot complete.
        await gate.release()
        try await bootTask.value

        // The same instance is now in .running.
        #expect(graph.resolve(key)?.instanceID == resolvedID,
                "the post-boot live instance must match the one requireService returned during .starting")
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
}
