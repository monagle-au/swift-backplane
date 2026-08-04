//
//  SubgroupsTests.swift
//  swift-backplane
//
//  Tests for subgroup-based failure policies and restartability in the
//  ServiceGraph spike.
//

import Foundation
import Synchronization
import Testing
@testable import Backplane

// MARK: - Test doubles

/// A service whose `start()` throws unconditionally. Used to model boot
/// failures in failFast / degraded subgroup tests.
private final class StartFailService: ManagedService, @unchecked Sendable {
    struct StartError: Error {}

    func start() async throws { throw StartError() }
    func shutdown() async { }
}

/// A service whose `start()` sleeps for `delay` before returning. Used
/// to ensure a sibling is in-flight when a failFast peer fails, so the
/// cancellation cascade is observable.
private final class SlowOKService: ManagedService, @unchecked Sendable {
    let instanceID = UUID()
    let delay: Duration

    init(delay: Duration) { self.delay = delay }

    func start() async throws {
        try await Task.sleep(for: delay, clock: .continuous)
    }
    func shutdown() async { }
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

@Suite("ServiceGraph — subgroups and failure policies")
struct SubgroupsTests {

    // MARK: Test 1 — default subgroup is .core

    @Test("Descriptors without a subgroup parameter land in .core")
    func testDefaultSubgroupIsCore() async throws {
        let key = ServiceKey<IdentityService>(id: "default")

        let descriptor = EntryDescriptor(key) { _ in IdentityService() }

        #expect(descriptor.subgroup == .core,
                "default subgroup must be .core; got \(descriptor.subgroup)")
    }

    // MARK: Test 2 — explicit subgroup assignment

    @Test("Explicit subgroup: parameter routes the entry correctly")
    func testExplicitSubgroupAssignment() async throws {
        let keyIntegrations = ServiceKey<IdentityService>(id: "in-integrations")
        let keyWorkers = ServiceKey<IdentityService>(id: "in-workers")

        let dIntegrations = EntryDescriptor(keyIntegrations, subgroup: .integrations) { _ in
            IdentityService()
        }
        let dWorkers = EntryDescriptor(keyWorkers, subgroup: "workers") { _ in
            IdentityService()
        }

        #expect(dIntegrations.subgroup == .integrations)
        #expect(dWorkers.subgroup == SubgroupTag("workers"))
    }

    // MARK: Test 3 — failFast cascades within a subgroup

    /// A failing entry in a `.core` (failFast) subgroup cancels its
    /// in-flight siblings. `boot(roots:)` throws `.subgroupBootFailed`
    /// naming the failing tag and the entries that ended in `.failed`.
    @Test("failFast: a failing entry cancels siblings in the same subgroup; boot throws")
    func testFailFastCascadesWithinSubgroup() async throws {
        let keyA = ServiceKey<StartFailService>(id: "a")
        let keyB = ServiceKey<SlowOKService>(id: "b")

        let graph = try ServiceGraph(descriptors: [
            // Both in default .core (failFast).
            EntryDescriptor(keyA) { _ in StartFailService() },
            EntryDescriptor(keyB) { _ in
                // Slow start ensures B is in-flight when A fails.
                SlowOKService(delay: .milliseconds(500))
            },
        ])

        do {
            try await graph.boot()
            Issue.record("Expected boot to throw .subgroupBootFailed")
        } catch let error as ServiceGraphError {
            guard case .subgroupBootFailed(let tag, let faulted) = error else {
                Issue.record("Expected .subgroupBootFailed; got \(error)")
                return
            }
            #expect(tag == .core)
            #expect(faulted.contains("a"), "faulted list should include 'a'; got \(faulted)")
        }

        // A failed outright.
        if case .failed = graph.state(of: keyA.id) {
            // expected
        } else {
            Issue.record("expected A.state == .failed; got \(graph.state(of: keyA.id))")
        }

        // B was cancelled mid-boot and ended in .failed too.
        if case .failed = graph.state(of: keyB.id) {
            // expected
        } else {
            Issue.record("expected B.state == .failed (cancelled); got \(graph.state(of: keyB.id))")
        }
    }

    // MARK: Test 4 — failFast does not cross subgroup boundary

    /// A failing entry in `.core` cancels its core siblings but does
    /// not cancel `.integrations` entries. Boot still throws because
    /// core failed.
    @Test("failFast in .core does not cancel .integrations entries")
    func testFailFastDoesNotCrossSubgroupBoundary() async throws {
        let keyA = ServiceKey<StartFailService>(id: "a")
        let keyB = ServiceKey<SlowOKService>(id: "b")
        let keyC = ServiceKey<IdentityService>(id: "c")
        let keyD = ServiceKey<IdentityService>(id: "d")

        let graph = try ServiceGraph(descriptors: [
            // .core (failFast)
            EntryDescriptor(keyA) { _ in StartFailService() },
            EntryDescriptor(keyB) { _ in SlowOKService(delay: .milliseconds(500)) },
            // .integrations (degraded)
            EntryDescriptor(keyC, subgroup: .integrations) { _ in IdentityService() },
            EntryDescriptor(keyD, subgroup: .integrations) { _ in IdentityService() },
        ])

        do {
            try await graph.boot()
            Issue.record("Expected boot to throw because core failed")
        } catch let error as ServiceGraphError {
            guard case .subgroupBootFailed(let tag, _) = error else {
                Issue.record("Expected .subgroupBootFailed; got \(error)")
                return
            }
            #expect(tag == .core)
        }

        // Core siblings are .failed.
        if case .failed = graph.state(of: keyA.id) { } else {
            Issue.record("expected A.state == .failed")
        }
        if case .failed = graph.state(of: keyB.id) { } else {
            Issue.record("expected B.state == .failed (cancelled)")
        }

        // Integrations entries booted unaffected.
        #expect(graph.state(of: keyC.id) == .running,
                "C in .integrations should reach .running; got \(graph.state(of: keyC.id))")
        #expect(graph.state(of: keyD.id) == .running,
                "D in .integrations should reach .running; got \(graph.state(of: keyD.id))")
    }

    // MARK: Test 5 — degraded subgroup isolates failures

    /// In a `.degraded` subgroup, an entry failure does not affect its
    /// siblings. The failing entry is `.failed`; sibling continues to
    /// `.running`. `boot(roots:)` returns normally.
    @Test("degraded subgroup: failures stay isolated; boot returns normally")
    func testDegradedSubgroupIsolatesFailures() async throws {
        let keyA = ServiceKey<StartFailService>(id: "a")
        let keyB = ServiceKey<IdentityService>(id: "b")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(keyA, subgroup: .integrations) { _ in StartFailService() },
            EntryDescriptor(keyB, subgroup: .integrations) { _ in IdentityService() },
        ])

        // No throw — degraded absorbs the failure.
        try await graph.boot()

        if case .failed = graph.state(of: keyA.id) { } else {
            Issue.record("expected A.state == .failed; got \(graph.state(of: keyA.id))")
        }
        #expect(graph.state(of: keyB.id) == .running,
                "B should boot independently of A's failure; got \(graph.state(of: keyB.id))")
    }

    // MARK: Test 6 — non-restartable subgroup refuses restart

    /// `restart(at:)` for an entry in `.core` (not restartable) is a
    /// no-op. The entry's state and live instance are unchanged.
    @Test("non-restartable subgroup: restart(at:) is a no-op")
    func testNonRestartableSubgroupRefusesRestart() async throws {
        let key = ServiceKey<IdentityService>(id: "core-entry")

        let graph = try ServiceGraph(descriptors: [
            // Default subgroup is .core — not restartable.
            EntryDescriptor(key) { _ in IdentityService() },
        ])

        try await graph.boot()
        let originalID = graph.resolve(key)!.instanceID
        #expect(graph.state(of: key.id) == .running)

        // Restart should be silently dropped — log only, no state change.
        await graph.restart(at: key.id)

        // Give any (hypothetical) restart work a moment to land. There
        // should be no transition; this delay is just defensive.
        try await Task.sleep(for: .milliseconds(50), clock: .continuous)

        #expect(graph.state(of: key.id) == .running,
                "non-restartable entry must stay .running; got \(graph.state(of: key.id))")
        #expect(graph.resolve(key)!.instanceID == originalID,
                "non-restartable entry must still resolve to the original instance")
    }

    // MARK: Test 7 — restartable subgroup allows restart

    /// `restart(at:)` for an entry in `.integrations` (restartable)
    /// produces a new generation as in the blue-green tests.
    @Test("restartable subgroup: restart(at:) produces a new generation")
    func testRestartableSubgroupAllowsRestart() async throws {
        let key = ServiceKey<IdentityService>(id: "integrations-entry")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations, replacement: .blueGreen(grace: .milliseconds(50))) { _ in IdentityService() },
        ])

        try await graph.boot()
        let gen1 = graph.resolve(key)!.instanceID

        await graph.restart(at: key.id)
        try await waitFor(key.id, in: graph) { $0 == .running }

        let gen2 = graph.resolve(key)!.instanceID
        #expect(gen1 != gen2, "restartable entry should produce a new generation on restart")
    }

    // MARK: Test 8 — pruning crosses subgroup boundaries

    /// `boot(roots: [A])` boots A and its transitive dependency B even
    /// when they're in different subgroups. The dependency closure is
    /// subgroup-agnostic; subgroup policies apply within each partition
    /// after pruning.
    @Test("pruning closure crosses subgroup boundaries")
    func testPruningCrossesSubgroupBoundaries() async throws {
        let keyA = ServiceKey<IdentityService>(id: "a")
        let keyB = ServiceKey<IdentityService>(id: "b")

        let graph = try ServiceGraph(descriptors: [
            // A in .core depends on B in .integrations.
            EntryDescriptor(keyA, subgroup: .core, dependencies: [AnyServiceKey(keyB)]) { _ in
                IdentityService()
            },
            EntryDescriptor(keyB, subgroup: .integrations) { _ in
                IdentityService()
            },
        ])

        try await graph.boot(roots: [AnyServiceKey(keyA)])

        #expect(graph.state(of: keyA.id) == .running, "A should boot — it is the root")
        #expect(graph.state(of: keyB.id) == .running, "B should boot — pulled into closure by A's dep")
    }
}
