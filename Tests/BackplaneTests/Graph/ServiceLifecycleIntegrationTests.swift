//
//  ServiceLifecycleIntegrationTests.swift
//  swift-backplane
//
//  Tests for ServiceGraph's ServiceLifecycle.Service conformance:
//  embedding the graph inside an outer ServiceGroup, per-entry adapters
//  driving start()/shutdown() in two-phase boot, and graceful-shutdown
//  propagation.
//

import Foundation
import Logging
import ServiceLifecycle
import Synchronization
import Testing
@testable import Backplane

// MARK: - Test doubles

/// A service that records start/shutdown calls in order.
private final class RecordingService: ManagedService, @unchecked Sendable {
    let instanceID = UUID()
    private(set) var startWasCalled = false
    private(set) var shutdownWasCalled = false

    nonisolated var replacementStrategy: ReplacementStrategy {
        .blueGreen(grace: .milliseconds(50))
    }

    func start() async throws {
        startWasCalled = true
    }

    func shutdown() async {
        shutdownWasCalled = true
    }
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

@Suite("ServiceGraph — ServiceLifecycle integration")
struct ServiceLifecycleIntegrationTests {

    // MARK: Test 1 — graph runs inside an outer ServiceGroup and drains

    /// Place the graph inside an outer `ServiceGroup`. Both entries
    /// reach `.running` via the per-entry adapter's `start()`. Trigger
    /// `triggerGracefulShutdown()` on the outer group. The inner group's
    /// shutdown propagates to every adapter, which calls `shutdown()`
    /// and transitions the entry to `.stopped`.
    @Test("Graph in outer ServiceGroup: entries reach .running and drain on gracefulShutdown")
    func testGraphRunsInsideOuterServiceGroupAndDrains() async throws {
        let keyA = ServiceKey<RecordingService>(id: "a")
        let keyB = ServiceKey<RecordingService>(id: "b")
        let services = Mutex<[RecordingService]>([])

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(keyA, subgroup: .integrations) { _ in
                let s = RecordingService()
                services.withLock { $0.append(s) }
                return s
            },
            EntryDescriptor(keyB, subgroup: .integrations) { _ in
                let s = RecordingService()
                services.withLock { $0.append(s) }
                return s
            },
        ])

        let outer = ServiceGroup(
            services: [graph],
            gracefulShutdownSignals: [],
            cancellationSignals: [],
            logger: Logger(label: "test-outer")
        )

        // Run the outer group in a background task. It returns once
        // `outer.triggerGracefulShutdown()` propagates through.
        let runTask = Task { try await outer.run() }

        // Wait for both entries to reach .running (the adapter has called
        // start() and transitioned the entry).
        try await waitFor(keyA.id, in: graph) { $0 == .running }
        try await waitFor(keyB.id, in: graph) { $0 == .running }

        // Both services' start() was called.
        let captured = services.withLock { $0 }
        #expect(captured.count == 2)
        #expect(captured.allSatisfy { $0.startWasCalled },
                "every service's start() should have been called by its adapter")
        #expect(captured.allSatisfy { !$0.shutdownWasCalled },
                "no service should be shut down yet — graceful-shutdown hasn't been triggered")

        // Trigger graceful shutdown on the outer group.
        await outer.triggerGracefulShutdown()
        try await runTask.value

        // After the outer group returns, every entry is `.stopped` and
        // every service had `shutdown()` observed.
        #expect(graph.state(of: keyA.id) == .stopped,
                "A should be .stopped after graceful shutdown; got \(graph.state(of: keyA.id))")
        #expect(graph.state(of: keyB.id) == .stopped,
                "B should be .stopped after graceful shutdown; got \(graph.state(of: keyB.id))")
        let post = services.withLock { $0 }
        #expect(post.allSatisfy { $0.shutdownWasCalled },
                "every service's shutdown() must have been called via the adapter")
    }

    // MARK: Test 2 — outer cancellation propagates to adapters

    /// Cancel the outer `Task` driving the group's `run()`. The
    /// cancellation cascades through the inner group to every adapter.
    /// `run()` returns within a bounded time. Entries land in a terminal
    /// state — `.stopped` if `shutdown()` ran cleanly, possibly other
    /// terminal-ish states under cancellation. This test focuses on the
    /// invariant: the outer `run()` returns promptly, no entries are
    /// stuck in `.running`.
    @Test("Cancelling the outer Task causes inner adapters to wind down")
    func testRunPropagatesCancellation() async throws {
        let key = ServiceKey<RecordingService>(id: "cancellable")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                RecordingService()
            },
        ])

        let outer = ServiceGroup(
            services: [graph],
            gracefulShutdownSignals: [],
            cancellationSignals: [],
            logger: Logger(label: "test-outer-cancel")
        )

        let runTask = Task { try await outer.run() }

        // Wait for .running so the adapter has fully started.
        try await waitFor(key.id, in: graph) { $0 == .running }

        // Cancel the outer task; the inner group should observe
        // cancellation and the adapter's `try await gracefulShutdown()`
        // should return (or throw CancellationError). Either way the
        // adapter proceeds to call `shutdown()` and transition the
        // entry out of `.running`.
        let cancelInstant = ContinuousClock.now
        runTask.cancel()

        // Wait for the outer task to actually exit. We accept either
        // a clean return or a thrown error (CancellationError typically).
        _ = try? await runTask.value
        let elapsed = ContinuousClock.now - cancelInstant
        #expect(elapsed < .seconds(2),
                "outer run() should return promptly after cancel; took \(elapsed)")

        // Entry is no longer `.running` — it's in some terminal state.
        let finalState = graph.state(of: key.id)
        let isTerminal: Bool
        switch finalState {
        case .stopped, .failed:
            isTerminal = true
        default:
            isTerminal = false
        }
        #expect(isTerminal,
                "entry should land in a terminal state after cancellation; got \(finalState)")
    }

    // MARK: Test 3 — requireService works while the graph is in run()

    /// Cross-service resolution composes with the SL.Service envelope.
    /// External observer awaits `graph.requireService(\.a)` while the
    /// graph is running inside an outer group; once the adapter has
    /// transitioned A to `.running`, the call returns the live instance.
    @Test("requireService works during run() — cross-resolution composes with the SL envelope")
    func testRequireServiceWorksDuringRun() async throws {
        let key = ServiceKey<RecordingService>(id: "during-run")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                RecordingService()
            },
        ])

        let outer = ServiceGroup(
            services: [graph],
            gracefulShutdownSignals: [],
            cancellationSignals: [],
            logger: Logger(label: "test-outer-require")
        )

        let runTask = Task { try await outer.run() }

        // requireService resolves as soon as the entry is `.starting`
        // with the active generation swapped in (the §7 boot-deadlock
        // fix's observable). The adapter's `start()` may not have
        // completed yet at this moment — that's expected.
        let resolved: RecordingService = try await graph.requireService(key, timeout: .seconds(2))
        #expect(resolved.instanceID == graph.resolve(key)?.instanceID,
                "requireService must return the same instance as graph.resolve")

        // After the adapter has run start(), the entry is `.running` and
        // the service records startWasCalled.
        try await waitFor(key.id, in: graph) { $0 == .running }
        #expect(resolved.startWasCalled,
                "after `.running`, the adapter should have called start() on the resolved instance")

        // Cleanup: trigger graceful shutdown and await.
        await outer.triggerGracefulShutdown()
        try await runTask.value
    }

    // MARK: Test 4 — restart works during run()

    /// `restart(at:)` on a restartable (`.integrations`) entry produces
    /// a new generation while the graph is inside an outer group. The
    /// restart path is detached from the inner group's per-entry adapter
    /// — it does its own factory + start + swap + drain — so it should
    /// continue to work in this composition mode.
    @Test("restart(at:) works while the graph is in run()")
    func testRestartWorksDuringRun() async throws {
        let key = ServiceKey<RecordingService>(id: "restart-during-run")
        let services = Mutex<[RecordingService]>([])

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                let s = RecordingService()
                services.withLock { $0.append(s) }
                return s
            },
        ])

        let outer = ServiceGroup(
            services: [graph],
            gracefulShutdownSignals: [],
            cancellationSignals: [],
            logger: Logger(label: "test-outer-restart")
        )

        let runTask = Task { try await outer.run() }
        try await waitFor(key.id, in: graph) { $0 == .running }

        let gen1 = graph.resolve(key)!
        let gen1ID = gen1.instanceID

        // Restart should produce a new generation. Note: the restart
        // path inside the spike runs detached from the adapter, so it
        // calls start() directly on the new instance (no second adapter).
        // We exercise it here to confirm composition with the SL envelope.
        await graph.restart(at: key.id)

        // After restart, state goes .replacing → .running and a new
        // generation is active.
        try await waitFor(key.id, in: graph) { state in
            // We want to land back at .running with a different instance.
            if state == .running, let live = graph.resolve(key), live.instanceID != gen1ID {
                return true
            }
            return false
        }

        let gen2 = graph.resolve(key)!
        #expect(gen2.instanceID != gen1ID,
                "restart during run() should produce a new generation")

        // Wait past the 50 ms grace period so the old generation drains.
        try await Task.sleep(for: .milliseconds(250), clock: .continuous)
        let captured = services.withLock { $0 }
        #expect(captured.count >= 2)
        #expect(captured[0].shutdownWasCalled,
                "old generation's shutdown() should have been called after the grace period")

        // Cleanup.
        await outer.triggerGracefulShutdown()
        try await runTask.value
    }
}
