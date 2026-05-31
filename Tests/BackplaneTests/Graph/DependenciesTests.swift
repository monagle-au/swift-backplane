//
//  DependenciesTests.swift
//  swift-backplane
//
//  Tests for declared-dependency-based pruning and cycle detection
//  in the ServiceGraph spike.
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

@Suite("ServiceGraph — declared dependencies and pruning")
struct DependenciesTests {

    // MARK: Test 1 — transitive closure follows declared dependencies

    /// `boot(roots: [\.A])` boots A, plus everything A transitively depends on.
    @Test("transitive closure: boot(roots:) boots all reachable entries")
    func testTransitiveClosureBootsAllReachable() async throws {
        let keyA = ServiceKey<IdentityService>(id: "a")
        let keyB = ServiceKey<IdentityService>(id: "b")
        let keyC = ServiceKey<IdentityService>(id: "c")

        // A → B → C
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(keyA, dependencies: [AnyServiceKey(keyB)]) { _ in IdentityService() },
            EntryDescriptor(keyB, dependencies: [AnyServiceKey(keyC)]) { _ in IdentityService() },
            EntryDescriptor(keyC) { _ in IdentityService() },
        ])

        try await graph.boot(roots: [AnyServiceKey(keyA)])

        #expect(graph.state(of: keyA.id) == .running, "A should boot (root)")
        #expect(graph.state(of: keyB.id) == .running, "B should boot (A → B)")
        #expect(graph.state(of: keyC.id) == .running, "C should boot (B → C)")
    }

    // MARK: Test 2 — pruning excludes unreachable entries

    /// The cloud-app scenario: redisClean run boots only redis + redisClean.
    /// postgres, grpcServer, and migrate stay untouched.
    @Test("pruning: boot(roots: [redisClean]) leaves postgres, grpcServer, migrate at .unconfigured")
    func testPruningExcludesUnreachableServices() async throws {
        let postgres = ServiceKey<IdentityService>(id: "postgres")
        let redis = ServiceKey<IdentityService>(id: "redis")
        let grpcServer = ServiceKey<IdentityService>(id: "grpcServer")
        let redisClean = ServiceKey<IdentityService>(id: "redisClean")
        let migrate = ServiceKey<IdentityService>(id: "migrate")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(postgres) { _ in IdentityService() },
            EntryDescriptor(redis) { _ in IdentityService() },
            EntryDescriptor(grpcServer, dependencies: [
                AnyServiceKey(postgres),
                AnyServiceKey(redis),
            ]) { _ in IdentityService() },
            EntryDescriptor(redisClean, dependencies: [
                AnyServiceKey(redis),
            ]) { _ in IdentityService() },
            EntryDescriptor(migrate, dependencies: [
                AnyServiceKey(postgres),
            ]) { _ in IdentityService() },
        ])

        // The redisClean command's root.
        try await graph.boot(roots: [AnyServiceKey(redisClean)])

        #expect(graph.state(of: redis.id) == .running, "redis is in the closure")
        #expect(graph.state(of: redisClean.id) == .running, "redisClean is the root")

        #expect(graph.state(of: postgres.id) == .unconfigured,
                "postgres is not in the closure; must stay .unconfigured")
        #expect(graph.state(of: grpcServer.id) == .unconfigured,
                "grpcServer is not in the closure; must stay .unconfigured")
        #expect(graph.state(of: migrate.id) == .unconfigured,
                "migrate is not in the closure; must stay .unconfigured")
    }

    // MARK: Test 3 — default boot() with no roots boots everything

    /// `boot()` (no roots) preserves the original spike behaviour: every
    /// registered entry boots concurrently.
    @Test("boot() without roots: every registered entry reaches .running")
    func testBootWithoutRootsBootsAll() async throws {
        let keyA = ServiceKey<IdentityService>(id: "a")
        let keyB = ServiceKey<IdentityService>(id: "b")

        // A and B are unrelated — no declared dependencies.
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(keyA) { _ in IdentityService() },
            EntryDescriptor(keyB) { _ in IdentityService() },
        ])

        try await graph.boot()

        #expect(graph.state(of: keyA.id) == .running, "A booted under default boot()")
        #expect(graph.state(of: keyB.id) == .running, "B booted under default boot()")
    }

    // MARK: Test 4 — cycle detection at construction

    /// A cyclic dependency graph causes `ServiceGraph.init` to throw —
    /// never reaches boot.
    @Test("cycle detection: graph init throws .cyclicDependency on A ↔ B")
    func testCycleDetectionAtConstruction() async throws {
        let keyA = ServiceKey<IdentityService>(id: "a")
        let keyB = ServiceKey<IdentityService>(id: "b")

        do {
            _ = try ServiceGraph(descriptors: [
                EntryDescriptor(keyA, dependencies: [AnyServiceKey(keyB)]) { _ in IdentityService() },
                EntryDescriptor(keyB, dependencies: [AnyServiceKey(keyA)]) { _ in IdentityService() },
            ])
            Issue.record("Expected init to throw .cyclicDependency")
        } catch let error as ServiceGraphError {
            guard case .cyclicDependency(let path) = error else {
                Issue.record("Expected .cyclicDependency; got \(error)")
                return
            }
            #expect(path.contains("a"), "cycle path should mention 'a'; got \(path)")
            #expect(path.contains("b"), "cycle path should mention 'b'; got \(path)")
        }
    }

    // MARK: Test 5 — unknown-dependency detection at construction

    /// A descriptor declaring a dependency on an unregistered id causes
    /// `ServiceGraph.init` to throw.
    @Test("unknown-dep detection: graph init throws .unknownDependency for missing id")
    func testUnknownDependencyAtConstruction() async throws {
        let keyA = ServiceKey<IdentityService>(id: "a")
        let unknown = AnyServiceKey(id: "does-not-exist")

        do {
            _ = try ServiceGraph(descriptors: [
                EntryDescriptor(keyA, dependencies: [unknown]) { _ in IdentityService() },
            ])
            Issue.record("Expected init to throw .unknownDependency")
        } catch let error as ServiceGraphError {
            guard case .unknownDependency(let id, let referencedBy) = error else {
                Issue.record("Expected .unknownDependency; got \(error)")
                return
            }
            #expect(id == "does-not-exist")
            #expect(referencedBy == "a")
        }
    }

    // MARK: Test 6b — unknown root id throws at boot

    /// `boot(roots: [...])` validates the root list eagerly. A root id
    /// that doesn't correspond to any registered descriptor surfaces as
    /// `.unknownRoot` *before* any factory runs — so a stringified-id
    /// typo doesn't silently produce a smaller-than-expected boot set.
    @Test("unknown-root detection: boot(roots:) throws .unknownRoot for a typo'd id")
    func testUnknownRootAtBoot() async throws {
        let keyA = ServiceKey<IdentityService>(id: "a")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(keyA) { _ in IdentityService() },
        ])

        do {
            try await graph.boot(roots: [AnyServiceKey(id: "redisClean-typo")])
            Issue.record("Expected boot(roots:) to throw .unknownRoot")
        } catch let error as ServiceGraphError {
            guard case .unknownRoot(let id) = error else {
                Issue.record("Expected .unknownRoot; got \(error)")
                return
            }
            #expect(id == "redisClean-typo")
        }

        // The valid root in the same descriptor set was never booted —
        // boot bailed before any work happened.
        #expect(graph.state(of: keyA.id) == .unconfigured,
                "unknown-root throw must abort boot before any factory runs")
    }

    // MARK: Test 7 — declared deps coexist with runtime requireService

    /// A service can both declare a dependency (for pruning) and resolve
    /// it inside its factory via `requireService`. The two mechanisms
    /// coexist without conflict — pruning is build-time topology;
    /// `requireService` is the runtime synchronisation point.
    @Test("declared deps coexist with runtime requireService")
    func testRequireServiceStillWorksWithDeclaredDeps() async throws {
        let keyA = ServiceKey<IdentityService>(id: "a")
        let keyB = ServiceKey<ResolvingService<IdentityService>>(id: "b")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(keyA) { _ in IdentityService() },
            EntryDescriptor(keyB, dependencies: [AnyServiceKey(keyA)]) { ctx in
                let a: IdentityService = try await ctx.requireService(keyA)
                return ResolvingService(
                    resolved: a,
                    factoryStartedAt: Date(),
                    resolvedReturnedAt: Date()
                )
            },
        ])

        try await graph.boot(roots: [AnyServiceKey(keyB)])

        let aLive = graph.resolve(keyA)
        let bLive = graph.resolve(keyB)

        #expect(aLive != nil, "A must boot — pulled in by B's declared dep")
        #expect(bLive != nil, "B must boot — it is the root")
        #expect(bLive!.resolved.instanceID == aLive!.instanceID,
                "B's factory must have resolved the live A")
    }
}
