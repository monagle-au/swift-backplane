//
//  HealthAndReloadTests.swift
//  swift-backplane
//
//  Tests for the two opt-in protocols added in slice 6:
//  - `ServiceHealthReporter` — self-reported degradation from a service.
//  - `HotReloadable` — in-place reconfiguration without replacement.
//

import Configuration
import Foundation
import Synchronization
import Testing
@testable import Backplane

// MARK: - Test doubles

/// A service that captures its `BackplaneContext` so the test can drive
/// `health.markDegraded` / `markHealthy` from outside the service body.
private final class HealthAwareService: ManagedService, @unchecked Sendable {
    let instanceID = UUID()
    let context: BackplaneContext

    init(context: BackplaneContext) { self.context = context }

    func start() async throws { }
    func shutdown() async { }
}

/// A `HotReloadable` service with observable `reloadCallCount` and the
/// last config value it was handed.
private final class ReloadableService: ManagedService, HotReloadable, @unchecked Sendable {
    let instanceID = UUID()
    private(set) var reloadCallCount = 0
    private(set) var lastReloadMode: String?
    var shouldThrowOnReload = false

    func start() async throws { }
    func shutdown() async { }

    func reload(config: ConfigReader) async throws {
        reloadCallCount += 1
        lastReloadMode = config.string(forKey: "mode")
        if shouldThrowOnReload {
            throw ReloadFailure()
        }
    }

    struct ReloadFailure: Error {}
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

@Suite("ServiceGraph — ServiceHealthReporter + HotReloadable")
struct HealthAndReloadTests {

    // MARK: Test 1 — markDegraded transitions .running → .degraded

    @Test("markDegraded(_:) transitions a .running entry to .degraded(fault:); observable on the stream")
    func testMarkDegradedTransitionsToDegraded() async throws {
        let key = ServiceKey<HealthAwareService>(id: "ha")
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { ctx in
                HealthAwareService(context: ctx)
            },
        ])
        try await graph.boot()
        #expect(graph.state(of: key.id) == .running)

        let svc = graph.resolve(key)!
        let fault = ServiceFault(
            description: "upstream lost",
            errorType: "TestFault",
            firstObservedAt: Date()
        )
        svc.context.health.markDegraded(fault: fault)

        // State should transition.
        guard case .degraded(let observed) = graph.state(of: key.id) else {
            Issue.record("Expected .degraded; got \(graph.state(of: key.id))")
            return
        }
        #expect(observed.description == "upstream lost")
        #expect(observed.errorType == "TestFault")

        // Routing is unchanged — resolve still returns the live instance.
        #expect(graph.resolve(key)?.instanceID == svc.instanceID)
    }

    // MARK: Test 2 — markHealthy returns .degraded → .running

    @Test("markHealthy() transitions a .degraded entry back to .running")
    func testMarkHealthyReturnsToRunning() async throws {
        let key = ServiceKey<HealthAwareService>(id: "ha")
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { ctx in
                HealthAwareService(context: ctx)
            },
        ])
        try await graph.boot()

        let svc = graph.resolve(key)!
        svc.context.health.markDegraded(fault: ServiceFault(
            description: "x", errorType: "T", firstObservedAt: Date()
        ))

        guard case .degraded = graph.state(of: key.id) else {
            Issue.record("expected .degraded")
            return
        }

        svc.context.health.markHealthy()
        #expect(graph.state(of: key.id) == .running,
                "markHealthy() should transition back to .running")
    }

    // MARK: Test 3 — markHealthy from non-.degraded is a no-op

    @Test("markHealthy() is a no-op for any state other than .degraded")
    func testMarkHealthyNoOpOutsideDegraded() async throws {
        let key = ServiceKey<HealthAwareService>(id: "ha")
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { ctx in
                HealthAwareService(context: ctx)
            },
        ])
        try await graph.boot()

        let svc = graph.resolve(key)!
        let before = graph.state(of: key.id)
        #expect(before == .running)

        // Call markHealthy from .running — must not change state.
        svc.context.health.markHealthy()
        #expect(graph.state(of: key.id) == .running,
                "markHealthy from .running must be a no-op; got \(graph.state(of: key.id))")
    }

    // MARK: Test 4 — HotReloadable: reload() is called instead of restart

    @Test("reload(at:) on a HotReloadable service calls reload(), no new generation")
    func testReloadCallsHotReloadable() async throws {
        let key = ServiceKey<ReloadableService>(id: "reloadable")
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in
                ReloadableService()
            },
        ])
        try await graph.boot()

        let before = graph.resolve(key)!
        let beforeID = before.instanceID
        #expect(before.reloadCallCount == 0)

        await graph.reload(at: key.id)

        let after = graph.resolve(key)!
        #expect(after.instanceID == beforeID,
                "reload must not produce a new generation; instanceID should match")
        #expect(after.reloadCallCount == 1,
                "reload() should have been called once; got \(after.reloadCallCount)")
        #expect(after.lastReloadMode == nil,
                "a config-less graph must pass an empty reader — keys read as absent")
        #expect(graph.state(of: key.id) == .running)
    }

    // MARK: Test 4b — reload(config:) receives the entry-scoped reader

    @Test("reload(config:) receives the reader scoped to the entry id")
    func testReloadReceivesEntryScopedConfig() async throws {
        let config = ConfigReader(provider: InMemoryProvider(values: [
            "reloadable.mode": .init(.string("fast"), isSecret: false),
        ]))

        let key = ServiceKey<ReloadableService>(id: "reloadable")
        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key, subgroup: .integrations) { _ in
                    ReloadableService()
                },
            ],
            config: config
        )
        try await graph.boot()

        await graph.reload(at: key.id)

        let svc = graph.resolve(key)!
        #expect(svc.lastReloadMode == "fast",
                "reload(config:) must see reloadable.mode as mode — same scope the factory saw")
    }

    // MARK: Test 5 — non-HotReloadable falls back to restart

    @Test("reload(at:) on a non-HotReloadable service falls back to restart() — new generation produced")
    func testReloadFallsBackToRestart() async throws {
        // HealthAwareService is not HotReloadable. Use .integrations so
        // restart is allowed.
        let key = ServiceKey<HealthAwareService>(id: "non-reloadable")
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { ctx in
                HealthAwareService(context: ctx)
            },
        ])
        try await graph.boot()
        let gen1 = graph.resolve(key)!.instanceID

        await graph.reload(at: key.id)

        // Wait for restart to settle.
        try await waitFor(key.id, in: graph) { state in
            // Watch for .running with a different instance.
            if state == .running, let live = graph.resolve(key), live.instanceID != gen1 {
                return true
            }
            return false
        }

        let gen2 = graph.resolve(key)!.instanceID
        #expect(gen1 != gen2,
                "non-HotReloadable reload should fall back to restart and produce a new generation")
    }

    // MARK: Test 5b — fallback escalates through the descriptor strategy

    /// The reload fallback goes through restart(at:), which honours the
    /// descriptor's declared strategy — including coldRestart.
    @Test("reload(at:) fallback on a coldRestart entry replaces old-before-new")
    func testReloadFallbackHonoursColdRestart() async throws {
        let events = Mutex<[String]>([])

        final class LoggingService: ManagedService, @unchecked Sendable {
            let instanceID = UUID()
            let onShutdown: @Sendable () -> Void
            init(onShutdown: @escaping @Sendable () -> Void) { self.onShutdown = onShutdown }
            func start() async throws {}
            func shutdown() async { onShutdown() }
        }

        let key = ServiceKey<LoggingService>(id: "cold")
        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations, replacement: .coldRestart) { _ in
                events.withLock { $0.append("factory") }
                return LoggingService(onShutdown: {
                    events.withLock { $0.append("shutdown") }
                })
            },
        ])
        try await graph.boot()
        let gen1 = graph.resolve(key)!.instanceID

        await graph.reload(at: key.id)
        try await waitFor(key.id, in: graph) { state in
            state == .running && graph.resolve(key)?.instanceID != gen1
        }

        let log = events.withLock { $0 }
        #expect(log == ["factory", "shutdown", "factory"],
                "fallback must run the descriptor's coldRestart: old shutdown before new factory; got \(log)")
    }

    // MARK: Test 6 — reload() throwing transitions entry to .degraded

    @Test("reload(at:) — if reload() throws, the entry transitions to .degraded; old instance keeps serving")
    func testReloadThrowTransitionsToDegraded() async throws {
        let key = ServiceKey<ReloadableService>(id: "reloadable-fail")
        let svcRef = ReloadableService()
        svcRef.shouldThrowOnReload = true

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, subgroup: .integrations) { _ in svcRef },
        ])
        try await graph.boot()

        let beforeID = graph.resolve(key)!.instanceID

        await graph.reload(at: key.id)

        // State should be .degraded (reload threw).
        guard case .degraded(let fault) = graph.state(of: key.id) else {
            Issue.record("Expected .degraded after reload throw; got \(graph.state(of: key.id))")
            return
        }
        #expect(fault.errorType.contains("ReloadFailure"),
                "fault should reflect ReloadFailure; got \(fault.errorType)")

        // Old instance keeps serving — `resolve` returns it (state is
        // `.degraded` which is resolution-ready).
        #expect(graph.resolve(key)?.instanceID == beforeID,
                "the same instance must keep serving after a failed reload")
        #expect(svcRef.reloadCallCount == 1)
    }
}
