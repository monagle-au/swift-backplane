//
//  RestartAvailabilityTests.swift
//  swift-backplane
//
//  Stress and concurrency tests for the blue-green restart machinery.
//  Asserts that consumers never observe nil during a swap, that
//  restart storms converge, that the `.replacing` state is
//  consumer-observable, that parallel multi-entry restarts don't
//  deadlock, and that held references survive even when the graph
//  cancels a stuck shutdown task.
//

import Foundation
import Synchronization
import Testing
@testable import Backplane

// MARK: - Helpers

/// Wait for the entry to reach a state satisfying `predicate`, up to `timeout`.
private func waitFor(
    _ id: String,
    in graph: ServiceGraph,
    timeout: Duration = .seconds(5),
    predicate: @Sendable @escaping (ServiceState) -> Bool
) async throws {
    let start = ContinuousClock.now
    for await state in graph.stateStream(of: id) {
        if predicate(state) { return }
        if ContinuousClock.now - start > timeout {
            throw RestartAvailabilityTimeout(last: state)
        }
    }
}

private struct RestartAvailabilityTimeout: Error { let last: ServiceState }

/// Sendable list wrapper. Used in tests that spawn task groups
/// recording IDs / states from concurrent contexts (raw `Mutex` is
/// non-Copyable and can't be captured directly into `@Sendable`
/// closures).
private final class SyncList<T: Sendable>: @unchecked Sendable {
    private let mutex = Mutex<[T]>([])
    func append(_ value: T) {
        mutex.withLock { (xs: inout [T]) in xs.append(value) }
    }
    var count: Int { mutex.withLock { $0.count } }
    var values: [T] { mutex.withLock { $0 } }
}

private final class SyncCounter: @unchecked Sendable {
    private let mutex = Mutex<Int>(0)
    func increment() -> Int {
        mutex.withLock { (n: inout Int) -> Int in
            n += 1
            return n
        }
    }
    var value: Int { mutex.withLock { $0 } }
}

// MARK: - Suite

@Suite("ServiceGraph — restart and availability")
struct RestartAvailabilityTests {

    // MARK: Test 1 — Concurrent resolves never observe nil

    @Test("20 concurrent readers observe no nil during a restart in flight")
    func concurrentResolvesNeverNil() async throws {
        let key = ServiceKey<TrackableService>(id: "svc")
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in TrackableService() },
        ])
        try await graph.boot()

        let harness = ConcurrentReaderHarness(
            graph: graph,
            key: key,
            fingerprint: { $0.instanceID.uuidString }
        )
        harness.start(readers: 20, iterations: 200)

        // Give readers a few ticks to enter their loops before the swap.
        try await Task.sleep(for: .milliseconds(5))
        await graph.restart(at: key.id)

        // Let readers continue past the swap.
        try await Task.sleep(for: .milliseconds(100))

        await harness.stop()

        let total = harness.observationCount
        let nilCount = harness.nilCount
        #expect(
            nilCount == 0,
            "no reader should observe nil during a blue-green restart — got \(nilCount) of \(total)"
        )
        #expect(total > 0, "harness recorded \(total) observations — readers must actually have run")
    }

    // MARK: Test 2 — Reader observations cover both old and new

    @Test("Concurrent readers observe both old and new generations across a restart")
    func concurrentReadersObserveBothGenerations() async throws {
        // Use a deterministic gate to control swap timing. The first
        // boot is gate-free; the replacement's `start()` blocks on a
        // gate that the test releases after readers have demonstrably
        // observed the old generation. This eliminates the sleep-vs-
        // CI-scheduling race that a bare-timing test exhibits on
        // loaded macOS runners.
        let key = ServiceKey<MaybeBlockingService>(id: "svc")
        let factoryCalls = SyncCounter()
        let replacementGate = StartGate()

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                let n = factoryCalls.increment()
                return n == 1
                    ? MaybeBlockingService(gate: nil)
                    : MaybeBlockingService(gate: replacementGate)
            },
        ])
        try await graph.boot()

        let harness = ConcurrentReaderHarness(
            graph: graph,
            key: key,
            fingerprint: { $0.instanceID.uuidString }
        )
        // Loop until stopped — guarantees readers are running across
        // the whole gate sequence regardless of CI scheduling latency.
        harness.startUntilStop(readers: 10)

        // Trigger the restart. The new instance's `start()` will
        // block on `replacementGate` so the swap is suspended at the
        // graph's pre-swap point — readers continue to see the old
        // generation throughout this window.
        await graph.restart(at: key.id)

        // Let readers accumulate observations of the old generation.
        try await Task.sleep(for: .milliseconds(100), clock: .continuous)

        // Release the gate. The new instance's `start()` returns; the
        // graph swaps; subsequent resolves return the new generation.
        await replacementGate.release()

        try await waitFor(key.id, in: graph) { $0 == .running }
        // Let readers continue past the swap so the new generation
        // is observed.
        try await Task.sleep(for: .milliseconds(100), clock: .continuous)

        await harness.stop()

        let distinct = harness.distinctFingerprints
        #expect(
            distinct.count >= 2,
            "readers should have observed at least two distinct generations — got \(distinct.count): \(distinct)"
        )
        #expect(
            harness.nilCount == 0,
            "no reader should observe nil — got \(harness.nilCount) of \(harness.observationCount)"
        )
    }

    // MARK: Test 3 — requireService waiters resolve cleanly during a restart

    @Test("requireService waiters return a valid instance while a restart is happening concurrently")
    func requireServiceWaitersDuringRestart() async throws {
        let key = ServiceKey<TrackableService>(id: "svc")
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in TrackableService() },
        ])
        try await graph.boot()

        let taskCount = 10
        let resolved = SyncList<UUID>()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    if let svc = try? await graph.requireService(key, timeout: .seconds(2)) {
                        resolved.append(svc.instanceID)
                    }
                }
            }
            // Concurrently trigger restart shortly after the waiters start.
            group.addTask {
                try? await Task.sleep(for: .milliseconds(1))
                await graph.restart(at: key.id)
            }
        }

        #expect(
            resolved.count == taskCount,
            "every requireService caller should have resolved — got \(resolved.count)/\(taskCount)"
        )
    }

    // MARK: Test 4 — Restart storm converges

    @Test("Restart storm: 10 rapid restarts converge to a single .running generation")
    func restartStormConverges() async throws {
        let key = ServiceKey<TrackableService>(id: "svc")
        let factoryCalls = SyncCounter()

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                _ = factoryCalls.increment()
                return TrackableService()
            },
        ])
        try await graph.boot()

        // Fire 10 restarts back-to-back; the spike's "latest restart
        // wins" semantic should cancel earlier replacement tasks.
        for _ in 0..<10 {
            await graph.restart(at: key.id)
        }

        // Wait for the storm to settle.
        try await waitFor(key.id, in: graph) { $0 == .running }
        // Past grace + buffer.
        try await Task.sleep(for: .milliseconds(300))

        #expect(graph.state(of: key.id) == .running,
                "after the storm the entry must be .running — got \(graph.state(of: key.id))")
        #expect(graph.resolve(key) != nil, "resolve should return a live instance after settling")

        // The factory was called at least for the initial boot + one
        // successful replacement; possibly more (intermediate replacements
        // that got cancelled). The latest-wins invariant means no leaks —
        // the test asserts external observability, not internal counters.
        #expect(factoryCalls.value >= 2,
                "expected at least initial + 1 replacement factory call — got \(factoryCalls.value)")
    }

    // MARK: Test 5 — State stream emits .replacing

    @Test("State stream emits .running → .replacing → .running across a restart")
    func stateStreamEmitsReplacing() async throws {
        let key = ServiceKey<TrackableService>(id: "svc")
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in TrackableService() },
        ])
        try await graph.boot()

        let states = SyncList<ServiceState>()

        let observerTask = Task<Void, Never> {
            for await state in graph.stateStream(of: key.id) {
                states.append(state)
                if Task.isCancelled { return }
            }
        }

        // Let the stream emit the initial .running.
        try await Task.sleep(for: .milliseconds(10))

        await graph.restart(at: key.id)
        try await waitFor(key.id, in: graph) { $0 == .running }

        // Give the stream a moment to deliver any tail events.
        try await Task.sleep(for: .milliseconds(50))
        observerTask.cancel()

        let seen = states.values
        #expect(seen.contains(.running),
                "should observe .running at least once — got \(seen)")
        #expect(seen.contains(.replacing),
                "should observe .replacing during the restart — got \(seen)")
    }

    // MARK: Test 6 — Parallel multi-entry restart

    @Test("Parallel restart of 5 independent entries all reach .running without deadlock")
    func parallelMultiEntryRestart() async throws {
        let keys = (0..<5).map { ServiceKey<TrackableService>(id: "svc\($0)") }
        let descriptors = keys.map { key in
            EntryDescriptor(key, subgroup: .integrations) { _ in TrackableService() }
        }
        let graph = try ServiceGraph(descriptors: descriptors)
        try await graph.boot()

        // Snapshot initial instance IDs so we can verify each entry
        // got a new generation.
        let initialIDs: [UUID] = keys.map { graph.resolve($0)!.instanceID }

        // Trigger every restart concurrently.
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                let id = key.id
                group.addTask { await graph.restart(at: id) }
            }
        }

        // Each entry should reach .running with a new generation.
        // Bound the wait so a deadlock surfaces as a timeout, not a hang.
        for (idx, key) in keys.enumerated() {
            let initial = initialIDs[idx]
            try await waitFor(key.id, in: graph, timeout: .seconds(3)) { state in
                guard state == .running else { return false }
                guard let live = graph.resolve(key) else { return false }
                return live.instanceID != initial
            }
        }

        // Final assertion: all entries have new generations.
        for (idx, key) in keys.enumerated() {
            let newID = graph.resolve(key)!.instanceID
            #expect(
                newID != initialIDs[idx],
                "key \(key.id) should have a new generation after restart"
            )
        }
    }

    // MARK: Test 7 — Held reference survives stuck-shutdown cancellation

    @Test("A held reference to the old generation survives the graph cancelling its stuck shutdown task")
    func heldReferenceSurvivesStuckShutdownCancellation() async throws {
        let key = ServiceKey<StuckShutdownService>(id: "stuck")
        let firstService = StuckShutdownService()
        let callCount = SyncCounter()

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key, subgroup: .integrations) { _ in
                    let n = callCount.increment()
                    return n == 1 ? firstService : StuckShutdownService()
                },
            ],
            shutdownTimeout: .milliseconds(100)
        )
        try await graph.boot()

        // Capture a strong reference to the initial instance before the
        // restart, modelling a consumer that resolved once and is still
        // using its captured handle.
        let heldOld = graph.resolve(key)!
        let heldID = heldOld.instanceID
        #expect(heldID == firstService.instanceID)

        // Restart — old generation enters draining, graph schedules
        // its shutdown() (which is stuck), eventually cancels at
        // shutdownTimeout.
        await graph.restart(at: key.id)
        try await waitFor(key.id, in: graph) { $0 == .running }

        // Wait for the shutdown task to be cancelled (grace 50ms +
        // shutdownTimeout 100ms + slack).
        try await Task.sleep(for: .milliseconds(400))

        // The shutdown was attempted and did not complete normally.
        #expect(firstService.shutdownWasCalled, "shutdown() should have been called on the draining generation")
        #expect(!firstService.shutdownCompletedNormally,
                "stuck shutdown() must have been cancelled rather than running to completion")

        // The held reference still identifies the original instance.
        // Swift reference semantics keep the instance alive as long
        // as any strong reference exists — the graph cancelling its
        // shutdown task doesn't deallocate it. This is the
        // consumer-facing availability promise: a reference resolved
        // before a restart remains valid for the duration of its scope.
        #expect(heldOld.instanceID == heldID,
                "held reference must still identify the original instance")
    }
}
