//
//  FactoryOnlyBootTests.swift
//  swift-backplane
//
//  `bootFactories(roots:)` and the adapter behaviours the composed mode
//  depends on: an entry left resolvable in `.starting` without waiting on
//  `start()`, adapters still built for those entries by `run()`, a
//  cancelled start treated as a stop rather than a fault, `shutdown()`
//  reaching the generation that is actually serving, and a restart
//  requested during `.starting` being applied rather than dropped.
//

import Foundation
import Logging
import ServiceLifecycle
import Synchronization
import Testing
@testable import Backplane

// MARK: - Test doubles

/// Blocks in `start()` until released, recording what happened to it.
private final class GatedStartService: ManagedService, @unchecked Sendable {
    let instanceID = UUID()
    private let gate: StartHold?
    private let state = Mutex(Observed())

    struct Observed: Sendable {
        var startEntered = false
        var startCompleted = false
        var startCancelled = false
        var shutdownCalled = false
    }

    init(gate: StartHold? = nil) { self.gate = gate }

    var observed: Observed { state.withLock { $0 } }

    func start() async throws {
        state.withLock { $0.startEntered = true }
        if let gate {
            do {
                try await gate.wait()
            } catch {
                state.withLock { $0.startCancelled = true }
                throw error
            }
        }
        state.withLock { $0.startCompleted = true }
    }

    func shutdown() async {
        state.withLock { $0.shutdownCalled = true }
    }
}

/// One-shot release gate backed by a continuation, so a test can hold a
/// `start()` open without sleeping.
private final class StartHold: @unchecked Sendable {
    private let mutex = Mutex<CheckedContinuation<Void, any Error>?>(nil)
    private let released = Mutex(false)

    func wait() async throws {
        if released.withLock({ $0 }) { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if released.withLock({ $0 }) { cont.resume(); return }
                mutex.withLock { $0 = cont }
            }
        } onCancel: {
            resume(throwing: CancellationError())
        }
    }

    func release() { resume(throwing: nil) }

    private func resume(throwing error: (any Error)?) {
        released.withLock { $0 = true }
        let cont = mutex.withLock { (c: inout CheckedContinuation<Void, any Error>?) in
            defer { c = nil }
            return c
        }
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
    }
}

/// Poll for a state rather than consuming the entry's state stream.
///
/// The stream-consuming spelling used elsewhere in these graph tests
/// checks its deadline *inside* the `for await` body, so it only notices a
/// timeout when another state happens to arrive. An entry that settles
/// somewhere unexpected and then stops transitioning — exactly what a
/// regression in the adapter produces — parks the test forever instead of
/// failing it. That turned a two-second red into a ten-minute hang the
/// first time it was exercised here.
private func waitFor(
    _ id: String,
    in graph: ServiceGraph,
    timeout: Duration = .seconds(5),
    predicate: @Sendable @escaping (ServiceState) -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate(graph.state(of: id)) { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    throw FactoryOnlyBootTimeout(last: graph.state(of: id))
}

private struct FactoryOnlyBootTimeout: Error { let last: ServiceState }

// MARK: - Tests

@Suite("Factory-only boot", .timeLimit(.minutes(1)))
struct FactoryOnlyBootTests {

    @Test("bootFactories returns without waiting for start(), leaving the entry resolvable")
    func doesNotWaitForStart() async throws {
        let key = ServiceKey<GatedStartService>(id: "svc")
        let gate = StartHold()
        let service = GatedStartService(gate: gate)

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in service },
        ])

        // The whole point: this returns even though `start()` would block
        // indefinitely. Under `boot()` it could not.
        try await graph.bootFactories()

        #expect(graph.state(of: "svc") == .starting)
        #expect(service.observed.startEntered == false,
                "factory-only boot must not have called start() at all")
        #expect(graph.resolve(key) != nil,
                "the instance must be resolvable in .starting, or consumers cannot enumerate it")

        gate.release()
    }

    @Test("boot() by contrast does wait for start()")
    func singlePhaseStillStarts() async throws {
        let key = ServiceKey<GatedStartService>(id: "svc")
        let service = GatedStartService()   // no gate: start() returns at once

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in service },
        ])
        try await graph.boot()

        #expect(graph.state(of: "svc") == .running)
        #expect(service.observed.startCompleted,
                "single-phase boot awaits start() before .running")
    }

    @Test("run() adopts entries left in .starting and drives their start()")
    func runAdoptsPreBootedEntries() async throws {
        let key = ServiceKey<GatedStartService>(id: "svc")
        let service = GatedStartService()

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in service },
        ])
        try await graph.bootFactories()
        #expect(graph.state(of: "svc") == .starting)

        let runner = Task { try await graph.run() }
        try await waitFor("svc", in: graph) { $0 == .running }

        #expect(service.observed.startCompleted,
                "the adapter must drive start() for an entry pre-booted to .starting")

        runner.cancel()
        _ = try? await runner.value
    }

    /// The bug this closes: under single-phase `boot()` every entry is
    /// already past `.starting`, so `run()`'s phase 2 selects nothing, no
    /// adapter is built, and `shutdown()` is never called on anything.
    @Test("shutdown() reaches a pre-booted entry, which single-phase boot never managed")
    func shutdownReachesPreBootedEntry() async throws {
        let key = ServiceKey<GatedStartService>(id: "svc")
        let service = GatedStartService()

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in service },
        ])
        try await graph.bootFactories()

        let runner = Task { try await graph.run() }
        try await waitFor("svc", in: graph) { $0 == .running }

        runner.cancel()
        _ = try? await runner.value
        try await waitFor("svc", in: graph) { $0 == .stopped }

        #expect(service.observed.shutdownCalled,
                "an adapter-supervised entry must get shutdown() at teardown")
    }

    /// A cancelled start is the group draining, not a fault. Transitioning
    /// to `.failed` would invite a recovery supervisor to build a fresh
    /// instance mid-shutdown.
    @Test("A start cancelled by shutdown stops the entry rather than failing it")
    func cancelledStartStopsRatherThanFails() async throws {
        let key = ServiceKey<GatedStartService>(id: "svc")
        let gate = StartHold()
        let service = GatedStartService(gate: gate)

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in service },
        ])
        try await graph.bootFactories()

        let runner = Task { try await graph.run() }
        // Wait until start() is genuinely in flight before cancelling.
        while !service.observed.startEntered { await Task.yield() }

        runner.cancel()
        _ = try? await runner.value
        try await waitFor("svc", in: graph) { $0 == .stopped }

        let observed = service.observed
        #expect(observed.startCancelled, "start() should have seen the cancellation")
        #expect(observed.shutdownCalled,
                "a half-open service still needs shutdown() to close what it opened")
        if case .failed = graph.state(of: "svc") {
            Issue.record("a cancelled start must not be reported as a fault")
        }
    }

    /// The adapter captures its instance once, at phase 2a. `restart(at:)`
    /// and `recover(at:)` build a new generation and start it inline,
    /// without an adapter — so after a restart the entry serves something
    /// the adapter task has never seen. Shutting down the captured value
    /// would close an already-drained generation and leave the live one
    /// holding its connection for the life of the process.
    @Test("shutdown() reaches the generation actually serving, not the one captured at start")
    func shutdownReachesLiveGenerationAfterRestart() async throws {
        let key = ServiceKey<GatedStartService>(id: "svc")
        let built = Mutex<[GatedStartService]>([])

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations,
                            replacement: .blueGreen(grace: .milliseconds(10))) { _ in
                let service = GatedStartService()
                built.withLock { $0.append(service) }
                return service
            },
        ])
        try await graph.bootFactories()

        let runner = Task { try await graph.run() }
        try await waitFor("svc", in: graph) { $0 == .running }

        await graph.restart(at: "svc")
        try await waitFor("svc", in: graph, timeout: .seconds(10)) { state in
            if case .running = state { return true }
            return false
        }
        for _ in 0..<20_000 where built.withLock({ $0.count }) < 2 { await Task.yield() }
        let generations = built.withLock { $0 }
        try #require(generations.count >= 2, "the restart must have built a second generation")

        runner.cancel()
        _ = try? await runner.value
        try await waitFor("svc", in: graph) { $0 == .stopped }

        #expect(generations[1].observed.shutdownCalled,
                "the live generation must be shut down, not the one the adapter captured")
    }

    @Test("A restart requested while .starting is applied once running, not dropped")
    func restartDuringStartingIsDeferred() async throws {
        let key = ServiceKey<GatedStartService>(id: "svc")
        let gate = StartHold()
        let built = Mutex<[GatedStartService]>([])

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations,
                            replacement: .blueGreen(grace: .milliseconds(10))) { _ in
                let service = built.withLock { list -> GatedStartService in
                    // Only the first generation blocks; the replacement
                    // starts immediately so the test can observe the swap.
                    let next = GatedStartService(gate: list.isEmpty ? gate : nil)
                    list.append(next)
                    return next
                }
                return service
            },
        ])
        try await graph.bootFactories()

        let runner = Task { try await graph.run() }
        while built.withLock({ $0.first })?.observed.startEntered != true { await Task.yield() }
        #expect(graph.state(of: "svc") == .starting)

        // The operator fixes the configuration while the entry is still
        // coming up. Under the old guard this was logged and discarded.
        await graph.restart(at: "svc")

        // Let the original start finish; the deferred restart should then fire.
        gate.release()
        try await waitFor("svc", in: graph, timeout: .seconds(10)) { state in
            if case .running = state { return true }
            return false
        }

        for _ in 0..<20_000 where built.withLock({ $0.count }) < 2 { await Task.yield() }
        #expect(built.withLock { $0.count } >= 2,
                "the deferred restart must build a replacement generation")

        runner.cancel()
        _ = try? await runner.value
    }

    @Test("A deferred restart is dropped if the entry never comes up")
    func deferredRestartDroppedOnFailure() async throws {
        struct StartFails: Error {}
        final class FailingService: ManagedService, @unchecked Sendable {
            let gate: StartHold
            init(gate: StartHold) { self.gate = gate }
            func start() async throws {
                try await gate.wait()
                throw StartFails()
            }
            func shutdown() async {}
        }

        let key = ServiceKey<FailingService>(id: "svc")
        let gate = StartHold()
        let factoryCalls = Mutex(0)

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                factoryCalls.withLock { $0 += 1 }
                return FailingService(gate: gate)
            },
        ])
        try await graph.bootFactories()

        let runner = Task { try await graph.run() }
        try await waitFor("svc", in: graph) { $0 == .starting }

        await graph.restart(at: "svc")
        gate.release()

        try await waitFor("svc", in: graph, timeout: .seconds(10)) { state in
            if case .failed = state { return true }
            return false
        }

        // Give a wrongly-queued restart every chance to fire.
        for _ in 0..<20_000 { await Task.yield() }
        #expect(factoryCalls.withLock { $0 } == 1,
                "a restart must not resurrect an entry that never started; recover(at:) owns .failed")

        runner.cancel()
        _ = try? await runner.value
    }
}
