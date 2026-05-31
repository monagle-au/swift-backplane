//
//  BlueGreenTests.swift
//  swift-backplane
//
//  Tests for the blue-green generation-swap mechanic in the ServiceGraph spike.
//

import Foundation
import Synchronization
import Testing
@testable import Backplane

// MARK: - Test doubles

/// A simple trackable service whose start() and shutdown() return immediately.
final class TrackableService: ManagedService, @unchecked Sendable {
    let instanceID = UUID()
    private(set) var shutdownWasCalled = false

    // Short grace so tests complete quickly.
    nonisolated var replacementStrategy: ReplacementStrategy {
        .blueGreen(grace: .milliseconds(50))
    }

    func start() async throws { }

    func shutdown() async {
        shutdownWasCalled = true
    }
}

/// A service whose shutdown() blocks until its task is cancelled.
///
/// Models a wedged instance (deadlocked socket, stuck event loop).
final class StuckShutdownService: ManagedService, @unchecked Sendable {
    let instanceID = UUID()
    private(set) var shutdownWasCalled = false
    private(set) var shutdownCompletedNormally = false

    nonisolated var replacementStrategy: ReplacementStrategy {
        .blueGreen(grace: .milliseconds(50))
    }

    func start() async throws { }

    func shutdown() async {
        shutdownWasCalled = true
        do {
            try await Task.sleep(for: .seconds(120), clock: .continuous)
            shutdownCompletedNormally = true
        } catch {
            // CancellationError — graph cancelled at shutdownTimeout.
        }
    }
}

// MARK: - Helpers

/// Wait for the entry to reach a state satisfying `predicate`, up to `timeout`.
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

@Suite("ServiceGraph — blue-green replacement")
struct BlueGreenTests {

    // MARK: Test 1 — swap preserves in-flight references

    /// Core blue-green guarantee:
    /// - A reference held before the swap continues to work after it.
    /// - A fresh resolve after the swap returns the new generation.
    /// - The old generation's shutdown() is called after the grace period.
    @Test("Old reference survives swap; fresh resolve returns new generation; shutdown called after grace")
    func testBlueGreenSwapPreservesInFlightReferences() async throws {
        let key = ServiceKey<TrackableService>(id: "svc")
        let createdServices = Mutex<[TrackableService]>([])

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key, subgroup: .integrations) { _ in
                    let s = TrackableService()
                    createdServices.withLock { $0.append(s) }
                    return s
                }
            ]
        )

        try await graph.boot()

        // Capture a reference to the first generation.
        let gen1 = graph.resolve(key)
        #expect(gen1 != nil)
        let gen1ID = gen1!.instanceID

        // Trigger restart.
        await graph.restart(at: key.id)

        // Wait for the swap to complete.
        try await waitFor(key.id, in: graph) { $0 == .running }

        // Fresh resolve returns the new (different) generation.
        let gen2 = graph.resolve(key)
        #expect(gen2 != nil)
        #expect(gen1ID != gen2!.instanceID, "fresh resolve after swap must return a different instance")

        // In-flight reference is unchanged — it's a strong Swift reference.
        #expect(gen1!.instanceID == gen1ID, "held reference must still identify the original instance")

        // Wait past grace (50 ms) + drain buffer.
        try await Task.sleep(for: .milliseconds(250), clock: .continuous)

        let all = createdServices.withLock { $0 }
        #expect(all[0].shutdownWasCalled, "old generation shutdown() must be called after grace")
        #expect(!all[1].shutdownWasCalled, "new generation must still be running")
    }

    // MARK: Test 2 — failed start leaves old generation serving

    /// When a replacement's start() throws:
    /// - Old generation continues to serve resolve().
    /// - Entry state becomes .degraded.
    /// - A subsequent successful restart clears the degradation and swaps in.
    @Test("Failed replacement start(): old generation keeps serving; state .degraded; recovery restart succeeds")
    func testFailedStartLeavesOldGenerationServing() async throws {
        let key = ServiceKey<TrackableService>(id: "svc")

        // Control whether the factory should throw on the NEXT call.
        let shouldFail = Mutex<Bool>(false)
        struct FactoryError: Error {}

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key, subgroup: .integrations) { _ in
                    if shouldFail.withLock({ $0 }) {
                        throw FactoryError()
                    }
                    return TrackableService()
                }
            ]
        )

        try await graph.boot()

        let originalID = graph.resolve(key)!.instanceID

        // Arm the failure for the next restart.
        shouldFail.withLock { $0 = true }
        await graph.restart(at: key.id)

        // Wait for .degraded.
        try await waitFor(key.id, in: graph) {
            if case .degraded = $0 { return true }
            return false
        }

        // Old generation still serves.
        #expect(graph.resolve(key)?.instanceID == originalID,
                "original instance must still be served after failed restart")

        // Graph is still operational.
        #expect(graph.resolve(key) != nil)

        // Arm a successful recovery restart.
        shouldFail.withLock { $0 = false }
        await graph.restart(at: key.id)

        try await waitFor(key.id, in: graph) { $0 == .running }

        let recoveryID = graph.resolve(key)!.instanceID
        #expect(recoveryID != originalID,
                "successful restart after .degraded must produce a new generation")
    }

    // MARK: Test 3 — stuck shutdown is cancelled at timeout

    /// When an old generation's shutdown() hangs:
    /// - New generation immediately serves resolve() after the swap.
    /// - shutdown() is called on the old generation after the grace period.
    /// - The graph cancels the shutdown task at shutdownTimeout.
    /// - The graph remains operational for further restarts.
    @Test("Stuck shutdown() cancelled at timeout; new generation serves; graph stays operational")
    func testStuckShutdownHonoursGraceExpiration() async throws {
        let stuckKey = ServiceKey<StuckShutdownService>(id: "stuck")
        let callNumber = Mutex<Int>(0)

        // Capture the first (stuck) service so we can inspect it later.
        let firstService = StuckShutdownService()

        // Very short shutdown timeout (100 ms) so the test completes quickly.
        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(stuckKey, subgroup: .integrations) { _ in
                    let n = callNumber.withLock { n -> Int in n += 1; return n }
                    return n == 1 ? firstService : StuckShutdownService()
                }
            ],
            shutdownTimeout: .milliseconds(100)
        )

        try await graph.boot()

        let gen1ID = graph.resolve(stuckKey)!.instanceID
        #expect(gen1ID == firstService.instanceID)

        // Restart — swaps in a new generation; first service (stuck) drains.
        await graph.restart(at: stuckKey.id)
        try await waitFor(stuckKey.id, in: graph) { $0 == .running }

        // New generation is serving.
        let gen2ID = graph.resolve(stuckKey)!.instanceID
        #expect(gen1ID != gen2ID, "resolve after swap must return new generation")

        // Wait for grace (50 ms) + shutdown timeout (100 ms) + buffer.
        // After grace: shutdown() is called.
        // After timeout: shutdown task is cancelled.
        try await Task.sleep(for: .milliseconds(400), clock: .continuous)

        // Shutdown was called on the old (stuck) generation.
        #expect(firstService.shutdownWasCalled,
                "shutdown() must be called on the drained generation after grace")

        // Shutdown did NOT complete normally — it was cancelled.
        #expect(!firstService.shutdownCompletedNormally,
                "stuck shutdown() must have been cancelled, not completed normally")

        // Graph is not blocked — entry is still .running and resolvable.
        #expect(graph.state(of: stuckKey.id) == .running,
                "entry must be .running, not blocked by stuck shutdown")
        #expect(graph.resolve(stuckKey) != nil)

        // A further restart proves the graph is fully operational.
        await graph.restart(at: stuckKey.id)
        try await waitFor(stuckKey.id, in: graph) { $0 == .running }

        let gen3ID = graph.resolve(stuckKey)!.instanceID
        #expect(gen3ID != gen2ID,
                "second restart must produce a third generation — graph not blocked by prior stuck shutdown")
    }
}
