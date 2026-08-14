//
//  ColdRestartTests.swift
//  swift-backplane
//
//  Tests for the coldRestart replacement strategy: old-before-new, the
//  intentional resolution gap, and .failed (not .degraded) failure
//  semantics.
//

import Foundation
import Synchronization
import Testing
@testable import Backplane

// MARK: - Test doubles

/// A service whose shutdown() blocks until the test releases it, so the
/// cold-restart gap can be observed deterministically.
final class GatedShutdownService: ManagedService, @unchecked Sendable {
    let instanceID = UUID()
    private let gate = Mutex<(started: Bool, mayFinish: Bool)>((false, false))

    func start() async throws {}

    func shutdown() async {
        gate.withLock { $0.started = true }
        while !gate.withLock({ $0.mayFinish }) && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }
    }

    var shutdownStarted: Bool { gate.withLock { $0.started } }
    func releaseShutdown() { gate.withLock { $0.mayFinish = true } }
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
            throw ColdRestartTimeoutError(last: state)
        }
    }
}

private struct ColdRestartTimeoutError: Error { let last: ServiceState }

// MARK: - Suite

@Suite("ServiceGraph — cold restart")
struct ColdRestartTests {

    // MARK: Test 1 — old shutdown completes before new factory runs

    /// The defining coldRestart property: two instances never coexist.
    /// The old generation's shutdown() must complete before the
    /// replacement factory is invoked.
    @Test("Old generation's shutdown() completes before the new factory runs")
    func testOldShutdownPrecedesNewFactory() async throws {
        let events = Mutex<[String]>([])

        final class LoggingService: ManagedService, @unchecked Sendable {
            let onShutdown: @Sendable () -> Void
            init(onShutdown: @escaping @Sendable () -> Void) { self.onShutdown = onShutdown }
            func start() async throws {}
            func shutdown() async { onShutdown() }
        }

        let loggingKey = ServiceKey<LoggingService>(id: "svc")

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(loggingKey, subgroup: .integrations, replacement: .coldRestart) { _ in
                    events.withLock { $0.append("factory") }
                    return LoggingService(onShutdown: {
                        events.withLock { $0.append("shutdown") }
                    })
                }
            ]
        )

        try await graph.boot()
        await graph.restart(at: loggingKey.id)
        try await waitFor(loggingKey.id, in: graph) { $0 == .running }

        let log = events.withLock { $0 }
        #expect(log == ["factory", "shutdown", "factory"],
                "old shutdown must complete before the replacement factory runs; got \(log)")
    }

    // MARK: Test 2 — the gap is real and requireService waits through it

    /// While the old generation drains, resolve() returns nil (the
    /// intentional gap) and the entry is .replacing. A requireService
    /// waiter parks through the gap and receives the new generation.
    @Test("resolve() is nil during the gap; requireService waits through it")
    func testGapObservableAndWaitersPark() async throws {
        let key = ServiceKey<GatedShutdownService>(id: "gated")
        let created = Mutex<[GatedShutdownService]>([])

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key, subgroup: .integrations, replacement: .coldRestart) { _ in
                    let s = GatedShutdownService()
                    created.withLock { $0.append(s) }
                    return s
                }
            ]
        )

        try await graph.boot()
        let first = created.withLock { $0.first! }
        let firstID = first.instanceID

        await graph.restart(at: key.id)

        // Spin until the old generation's shutdown() has started — the
        // drain is now parked on the gate, so the gap is stable.
        let deadline = ContinuousClock.now + .seconds(5)
        while !first.shutdownStarted {
            #expect(ContinuousClock.now < deadline, "old shutdown never started")
            try await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }

        // The gap: nothing is serving, state is .replacing.
        #expect(graph.resolve(key) == nil,
                "resolve() must return nil during the cold-restart gap")
        #expect(graph.state(of: key.id) == .replacing)

        // Park a waiter in the gap.
        let waiter = Task { try await graph.requireService(key, timeout: .seconds(5)) }

        first.releaseShutdown()

        let replacement = try await waiter.value
        #expect(replacement.instanceID != firstID,
                "waiter must receive the new generation, not the drained one")
        try await waitFor(key.id, in: graph) { $0 == .running }
    }

    // MARK: Test 3 — factory failure lands .failed and recover() works

    /// A replacement factory throw after the old generation is gone
    /// leaves the entry .failed — nothing is serving, so .degraded's
    /// "old generation keeps serving" contract would be a lie. The
    /// entry stays recoverable via recover(at:).
    @Test("Factory failure → .failed (not .degraded); recover(at:) re-boots")
    func testFactoryFailureLandsFailedAndRecovers() async throws {
        let key = ServiceKey<TrackableService>(id: "svc")
        let shouldFail = Mutex<Bool>(false)
        struct FactoryError: Error {}

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key, subgroup: .integrations, replacement: .coldRestart) { _ in
                    if shouldFail.withLock({ $0 }) { throw FactoryError() }
                    return TrackableService()
                }
            ]
        )

        try await graph.boot()
        let originalID = graph.resolve(key)!.instanceID

        shouldFail.withLock { $0 = true }
        await graph.restart(at: key.id)

        try await waitFor(key.id, in: graph) {
            if case .failed = $0 { return true }
            return false
        }
        #expect(graph.resolve(key) == nil, "nothing may serve after a failed cold restart")

        shouldFail.withLock { $0 = false }
        await graph.recover(at: key.id)
        try await waitFor(key.id, in: graph) { $0 == .running }

        let recoveredID = graph.resolve(key)!.instanceID
        #expect(recoveredID != originalID, "recovery must produce a fresh generation")
    }

    // MARK: Test 4 — start() failure lands .failed

    @Test("start() failure → .failed (not .degraded)")
    func testStartFailureLandsFailed() async throws {
        final class FailOnSecondStart: ManagedService, @unchecked Sendable {
            let failOnStart: Bool
            init(failOnStart: Bool) { self.failOnStart = failOnStart }
            struct StartError: Error {}
            func start() async throws {
                if failOnStart { throw StartError() }
            }
            func shutdown() async {}
        }

        let key = ServiceKey<FailOnSecondStart>(id: "svc")
        let callCount = Mutex<Int>(0)

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key, subgroup: .integrations, replacement: .coldRestart) { _ in
                    let n = callCount.withLock { n -> Int in n += 1; return n }
                    return FailOnSecondStart(failOnStart: n > 1)
                }
            ]
        )

        try await graph.boot()
        await graph.restart(at: key.id)

        try await waitFor(key.id, in: graph) {
            if case .failed = $0 { return true }
            return false
        }
        #expect(graph.resolve(key) == nil)
    }

    // MARK: Test 5 — stuck old shutdown is bounded by shutdownTimeout

    /// A wedged old generation must not block the cold restart forever:
    /// the drain cancels its shutdown at shutdownTimeout and the
    /// replacement proceeds.
    @Test("Stuck old shutdown() is cancelled at shutdownTimeout; restart completes")
    func testStuckOldShutdownIsBounded() async throws {
        let key = ServiceKey<StuckShutdownService>(id: "stuck")
        let callNumber = Mutex<Int>(0)
        let firstService = StuckShutdownService()

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key, subgroup: .integrations, replacement: .coldRestart) { _ in
                    let n = callNumber.withLock { n -> Int in n += 1; return n }
                    return n == 1 ? firstService : StuckShutdownService()
                }
            ],
            shutdownTimeout: .milliseconds(100)
        )

        try await graph.boot()
        let gen1ID = graph.resolve(key)!.instanceID

        await graph.restart(at: key.id)
        try await waitFor(key.id, in: graph) { $0 == .running }

        #expect(firstService.shutdownWasCalled)
        #expect(!firstService.shutdownCompletedNormally,
                "stuck shutdown must have been cancelled at shutdownTimeout")

        let gen2ID = graph.resolve(key)!.instanceID
        #expect(gen1ID != gen2ID, "replacement generation must be serving")
    }
}
