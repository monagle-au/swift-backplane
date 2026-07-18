//
//  RecoveryTests.swift
//  swift-backplane
//
//  Tests for recover(at:) — the cold re-boot edge out of `.failed`.
//  Asserts that failed-at-boot entries can be revived, that recovery
//  failures land back in `.failed` (never `.degraded` — a
//  resolution-ready state must always mean a live serving instance),
//  that the swapped-out failed generation is drained, and that the
//  restart(at:) contract is unchanged.
//

import Foundation
import Synchronization
import Testing
@testable import Backplane

// MARK: - Test doubles

/// A service whose `start()` throws until `failuresRemaining` reaches
/// zero, then succeeds. Instances share the countdown through the
/// enclosing test's `SharedCountdown` so successive factory-built
/// generations model "the NVR came back".
private final class CountdownStartService: ManagedService, @unchecked Sendable {
    struct StartError: Error {}

    let instanceID = UUID()
    private let countdown: SharedCountdown
    private let shutdownFlag = Mutex<Bool>(false)

    var shutdownWasCalled: Bool { shutdownFlag.withLock { $0 } }

    nonisolated var replacementStrategy: ReplacementStrategy {
        .blueGreen(grace: .milliseconds(50))
    }

    init(countdown: SharedCountdown) {
        self.countdown = countdown
    }

    func start() async throws {
        if countdown.consumeFailure() { throw StartError() }
    }

    func shutdown() async {
        shutdownFlag.withLock { $0 = true }
    }
}

/// Shared "fail the next N start()/factory calls" countdown.
private final class SharedCountdown: @unchecked Sendable {
    private let remaining: Mutex<Int>

    init(failures: Int) {
        self.remaining = Mutex(failures)
    }

    /// Returns true if this call should fail, consuming one failure.
    func consumeFailure() -> Bool {
        remaining.withLock { n in
            guard n > 0 else { return false }
            n -= 1
            return true
        }
    }
}

private final class SyncCounter: @unchecked Sendable {
    private let mutex = Mutex<Int>(0)
    @discardableResult
    func increment() -> Int {
        mutex.withLock { (n: inout Int) -> Int in
            n += 1
            return n
        }
    }
    var value: Int { mutex.withLock { $0 } }
}

private final class SyncList<T: Sendable>: @unchecked Sendable {
    private let mutex = Mutex<[T]>([])
    func append(_ value: T) {
        mutex.withLock { (xs: inout [T]) in xs.append(value) }
    }
    var values: [T] { mutex.withLock { $0 } }
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

private struct FactoryError: Error {}

private func isFailed(_ state: ServiceState) -> Bool {
    if case .failed = state { return true }
    return false
}

// MARK: - Suite

@Suite("ServiceGraph — recovery from .failed")
struct RecoveryTests {

    // MARK: Test 1 — start()-threw entry recovers to .running

    @Test("recover(at:) revives an entry whose start() threw at boot: fresh factory call, .failed → .starting → .running, resolve returns the new instance")
    func recoverRevivesStartFailedEntry() async throws {
        let countdown = SharedCountdown(failures: 1)
        let factoryCalls = SyncCounter()
        let key = ServiceKey<CountdownStartService>(id: "svc")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                factoryCalls.increment()
                return CountdownStartService(countdown: countdown)
            },
        ])
        // Degraded subgroup: boot returns normally, entry lands .failed.
        try await graph.boot()
        #expect(isFailed(graph.state(of: key.id)), "entry must be .failed after start() threw at boot")
        #expect(graph.resolve(key) == nil, "a .failed entry must not resolve")
        #expect(factoryCalls.value == 1)

        let states = SyncList<ServiceState>()
        let observer = Task<Void, Never> {
            for await state in graph.stateStream(of: key.id) {
                states.append(state)
                if state == .running { return }
            }
        }
        // Let the observer capture the replayed .failed before recovering.
        try await Task.sleep(for: .milliseconds(10))

        await graph.recover(at: key.id)
        try await waitFor(key.id, in: graph) { $0 == .running }
        _ = await observer.value

        #expect(factoryCalls.value == 2, "recovery must re-run the factory")
        #expect(graph.resolve(key) != nil, "a recovered entry must resolve")

        let seen = states.values
        #expect(seen.contains(where: isFailed), "observer should see the replayed .failed — got \(seen)")
        #expect(seen.contains(.starting), "observer should see .starting during recovery — got \(seen)")
        #expect(seen.contains(.running), "observer should see .running after recovery — got \(seen)")
    }

    // MARK: Test 2 — factory-threw entry (no active generation) recovers

    @Test("recover(at:) revives an entry whose factory threw at boot")
    func recoverRevivesFactoryFailedEntry() async throws {
        let factoryCalls = SyncCounter()
        let key = ServiceKey<TrackableService>(id: "svc")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                if factoryCalls.increment() == 1 { throw FactoryError() }
                return TrackableService()
            },
        ])
        try await graph.boot()
        #expect(isFailed(graph.state(of: key.id)), "entry must be .failed after the boot factory threw")

        await graph.recover(at: key.id)
        try await waitFor(key.id, in: graph) { $0 == .running }

        #expect(factoryCalls.value == 2)
        #expect(graph.resolve(key) != nil)
    }

    // MARK: Test 3 — re-failure lands .failed (never .degraded) and stays recoverable

    @Test("A failed recovery lands .failed — never .degraded — and a later recover still succeeds")
    func failedRecoveryLandsFailedAndStaysRecoverable() async throws {
        // Boot fails once, first recovery fails once more, second succeeds.
        let countdown = SharedCountdown(failures: 2)
        let key = ServiceKey<CountdownStartService>(id: "svc")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                CountdownStartService(countdown: countdown)
            },
        ])
        try await graph.boot()
        #expect(isFailed(graph.state(of: key.id)))

        // Observe the .starting → .failed round trip from a subscription
        // opened BEFORE the recovery — sequential waits would race the
        // replay-first stream.
        let observer = Task<Bool, Never> {
            var sawStarting = false
            for await state in graph.stateStream(of: key.id) {
                if state == .starting { sawStarting = true }
                else if sawStarting, isFailed(state) { return true }
            }
            return false
        }
        try await Task.sleep(for: .milliseconds(10))

        // First recovery: start() throws again.
        await graph.recover(at: key.id)

        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            observer.cancel()
        }
        let sawRoundTrip = await observer.value
        timeout.cancel()
        #expect(sawRoundTrip, "recovery must emit .starting (handle swapped) then return to .failed when start() throws")

        let afterFailedRecovery = graph.state(of: key.id)
        #expect(isFailed(afterFailedRecovery), "failed recovery must land .failed — got \(afterFailedRecovery)")
        if case .degraded = afterFailedRecovery {
            Issue.record(".degraded after a failed recovery would let the coordinator resolve a dead instance")
        }
        #expect(graph.resolve(key) == nil, "no live instance may resolve after a failed recovery")

        // Second recovery succeeds.
        await graph.recover(at: key.id)
        try await waitFor(key.id, in: graph) { $0 == .running }
        #expect(graph.resolve(key) != nil)
    }

    // MARK: Test 4 — state and subgroup gates

    @Test("recover(at:) is a no-op for live/stopped/unconfigured entries and for non-restartable subgroups")
    func recoverGates() async throws {
        // Gate 1: a .running entry must not be recovered (factory not re-run).
        let runningFactoryCalls = SyncCounter()
        let runningKey = ServiceKey<TrackableService>(id: "running-svc")
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(runningKey, subgroup: .integrations) { _ in
                runningFactoryCalls.increment()
                return TrackableService()
            },
        ])
        try await graph.boot()
        #expect(graph.state(of: runningKey.id) == .running)

        await graph.recover(at: runningKey.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(graph.state(of: runningKey.id) == .running)
        #expect(runningFactoryCalls.value == 1, "recover on a .running entry must not re-run the factory")

        // Gate 2: unknown id is a logged no-op (must not crash).
        await graph.recover(at: "no-such-entry")

        // Gate 3: a .failed entry in a non-restartable subgroup stays .failed.
        let coreCountdown = SharedCountdown(failures: 99)
        let coreFactoryCalls = SyncCounter()
        let coreKey = ServiceKey<CountdownStartService>(id: "core-svc")
        let coreGraph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(coreKey, subgroup: "solo-core") { _ in
                    coreFactoryCalls.increment()
                    return CountdownStartService(countdown: coreCountdown)
                },
            ],
            // Non-restartable, but degraded so boot() doesn't throw.
            subgroupPolicies: ["solo-core": SubgroupPolicy(failure: .degraded, restartable: false)]
        )
        try await coreGraph.boot()
        #expect(isFailed(coreGraph.state(of: coreKey.id)))

        await coreGraph.recover(at: coreKey.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(isFailed(coreGraph.state(of: coreKey.id)), "non-restartable subgroup must refuse recovery")
        #expect(coreFactoryCalls.value == 1, "recovery must not re-run the factory in a non-restartable subgroup")
    }

    // MARK: Test 5 — the failed generation is drained

    @Test("The swapped-out failed generation receives shutdown() during recovery")
    func failedGenerationIsDrained() async throws {
        let countdown = SharedCountdown(failures: 1)
        let created = SyncList<CountdownStartService>()
        let key = ServiceKey<CountdownStartService>(id: "svc")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                let s = CountdownStartService(countdown: countdown)
                created.append(s)
                return s
            },
        ])
        try await graph.boot()
        #expect(isFailed(graph.state(of: key.id)))

        await graph.recover(at: key.id)
        try await waitFor(key.id, in: graph) { $0 == .running }

        // Zero-grace drain: give the fire-and-forget drain task a moment.
        try await Task.sleep(for: .milliseconds(100))

        let instances = created.values
        #expect(instances.count == 2)
        #expect(
            instances[0].shutdownWasCalled,
            "the boot-failed generation must be shut down during recovery — its start() may have acquired resources"
        )
        #expect(!instances[1].shutdownWasCalled, "the live replacement must not be shut down")
    }

    // MARK: Test 6 — latest wins

    @Test("Rapid recover(at:) calls converge to a single .running generation")
    func recoverStormConverges() async throws {
        let countdown = SharedCountdown(failures: 1)
        let key = ServiceKey<CountdownStartService>(id: "svc")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                CountdownStartService(countdown: countdown)
            },
        ])
        try await graph.boot()
        #expect(isFailed(graph.state(of: key.id)))

        for _ in 0..<10 {
            await graph.recover(at: key.id)
        }

        try await waitFor(key.id, in: graph) { $0 == .running }
        try await Task.sleep(for: .milliseconds(100))

        #expect(graph.state(of: key.id) == .running)
        #expect(graph.resolve(key) != nil)
    }

    // MARK: Test 7 — restart(at:) contract is unchanged

    @Test("restart(at:) on a .failed entry remains a no-op")
    func restartStillRefusesFailedEntries() async throws {
        let countdown = SharedCountdown(failures: 99)
        let factoryCalls = SyncCounter()
        let key = ServiceKey<CountdownStartService>(id: "svc")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                factoryCalls.increment()
                return CountdownStartService(countdown: countdown)
            },
        ])
        try await graph.boot()
        #expect(isFailed(graph.state(of: key.id)))

        await graph.restart(at: key.id)
        try await Task.sleep(for: .milliseconds(50))

        #expect(isFailed(graph.state(of: key.id)), "restart must not act on a .failed entry")
        #expect(factoryCalls.value == 1, "restart on a .failed entry must not re-run the factory")
    }
}
