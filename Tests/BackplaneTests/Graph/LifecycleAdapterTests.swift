//
//  LifecycleAdapterTests.swift
//  swift-backplane
//
//  Tests for the LifecycleAdapter<S> and PassiveService<T> wrappers
//  that consumers use to bridge `ServiceLifecycle.Service` /
//  passive-value types into the `ManagedService` graph.
//

import Configuration
import Foundation
import Logging
import ServiceLifecycle
import Synchronization
import Testing
@testable import Backplane

// MARK: - Test doubles

/// A `ServiceLifecycle.Service` whose `run()` increments a counter and
/// then blocks until cancelled. Lets tests observe whether `run()` was
/// scheduled and whether cancellation propagated.
private final class InstrumentedService: Service, @unchecked Sendable {
    let runStartedCount: SyncCounter
    let runCancelledCount: SyncCounter

    init(runStartedCount: SyncCounter, runCancelledCount: SyncCounter) {
        self.runStartedCount = runStartedCount
        self.runCancelledCount = runCancelledCount
    }

    func run() async throws {
        _ = runStartedCount.increment()
        do {
            try await Task.sleep(for: .seconds(Int32.max), clock: .continuous)
        } catch {
            _ = runCancelledCount.increment()
            throw error
        }
    }
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

private struct OpaqueValue: Sendable, Equatable {
    let id: String
}

// MARK: - LifecycleAdapter suite

@Suite("LifecycleAdapter — Service → ManagedService bridge")
struct LifecycleAdapterTests {

    @Test("start() schedules inner.run(); shutdown() cancels and awaits")
    func runIsScheduledAndCancelled() async throws {
        let startedCount = SyncCounter()
        let cancelledCount = SyncCounter()
        let inner = InstrumentedService(
            runStartedCount: startedCount,
            runCancelledCount: cancelledCount
        )
        let adapter = LifecycleAdapter(inner)

        try await adapter.start()

        // Yield + brief wait so the spawned task actually enters run().
        try await Task.sleep(for: .milliseconds(10))
        #expect(startedCount.value == 1, "inner.run() should have started")
        #expect(cancelledCount.value == 0, "inner.run() should not yet have been cancelled")

        await adapter.shutdown()

        #expect(cancelledCount.value == 1, "shutdown() should have cancelled the inner run task")
    }

    @Test("inner property exposes the wrapped Service")
    func innerExposesWrapped() async throws {
        let inner = InstrumentedService(
            runStartedCount: SyncCounter(),
            runCancelledCount: SyncCounter()
        )
        let adapter = LifecycleAdapter(inner)
        #expect(adapter.inner === inner, "adapter.inner should reference the constructed inner instance")
    }

    @Test("shutdown() is idempotent — multiple calls don't double-cancel")
    func shutdownIdempotent() async throws {
        let startedCount = SyncCounter()
        let cancelledCount = SyncCounter()
        let inner = InstrumentedService(
            runStartedCount: startedCount,
            runCancelledCount: cancelledCount
        )
        let adapter = LifecycleAdapter(inner)

        try await adapter.start()
        try await Task.sleep(for: .milliseconds(10))

        await adapter.shutdown()
        await adapter.shutdown()
        await adapter.shutdown()

        #expect(cancelledCount.value == 1, "subsequent shutdown() calls should be no-ops")
    }

    @Test("LifecycleAdapter integrates with ServiceGraph via a typed key")
    func graphIntegration() async throws {
        let startedCount = SyncCounter()
        let inner = InstrumentedService(
            runStartedCount: startedCount,
            runCancelledCount: SyncCounter()
        )

        let key = ServiceKey<LifecycleAdapter<InstrumentedService>>(id: "adapter-test")

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key) { _ in LifecycleAdapter(inner) },
            ],
            logger: Logger(label: "LifecycleAdapterTests")
        )
        try await graph.boot(roots: [AnyServiceKey(key)])

        let resolved = graph.resolve(key)
        #expect(resolved != nil)
        #expect(resolved?.inner === inner)
        #expect(startedCount.value == 1, "single-phase boot should have run start()")
    }
}

// MARK: - PassiveService suite

@Suite("PassiveService — passive value as a ManagedService")
struct PassiveServiceTests {

    @Test("start() and shutdown() are no-ops; inner is preserved")
    func passiveLifecycle() async throws {
        let value = OpaqueValue(id: "v1")
        let service = PassiveService(value)
        #expect(service.inner == value)

        try await service.start()
        await service.shutdown()

        // No assertions on side effects — the type's job is to NOT
        // schedule anything. The point is that the graph holds the
        // value across resolutions.
        #expect(service.inner == value, "inner should still be the same value after start/shutdown")
    }

    @Test("PassiveService integrates with ServiceGraph via a typed key")
    func graphIntegration() async throws {
        let key = ServiceKey<PassiveService<OpaqueValue>>(id: "passive-test")
        let value = OpaqueValue(id: "graph-resolved")

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key) { _ in PassiveService(value) },
            ],
            logger: Logger(label: "PassiveServiceTests")
        )
        try await graph.boot(roots: [AnyServiceKey(key)])

        let resolved = graph.resolve(key)
        #expect(resolved?.inner == value)
    }
}

// MARK: - requireConfig suite

@Suite("BackplaneContext.requireConfig() — config-or-throw shortcut")
struct RequireConfigTests {

    @Test("requireConfig() returns the supplied ConfigReader when present")
    func returnsConfig() async throws {
        let captured = SyncMutableReference<ConfigReader?>()
        let key = ServiceKey<PassiveService<String>>(id: "config-present")

        // Use any non-empty config — the test asserts identity, not values.
        let config = ConfigReader(provider: InMemoryProvider(values: [:]))

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key) { context in
                    captured.set(try context.requireConfig())
                    return PassiveService("ok")
                },
            ],
            logger: Logger(label: "RequireConfigTests"),
            config: config
        )
        try await graph.boot(roots: [AnyServiceKey(key)])

        #expect(captured.get() != nil, "requireConfig() should have yielded a non-nil ConfigReader")
    }

    @Test("requireConfig() throws .missingConfigReader when the graph has no config")
    func throwsWhenMissing() async throws {
        let key = ServiceKey<PassiveService<String>>(id: "config-absent")

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key) { context in
                    _ = try context.requireConfig()
                    return PassiveService("ok")
                },
            ],
            logger: Logger(label: "RequireConfigTests")
        )

        await #expect(throws: (any Error).self) {
            try await graph.boot(roots: [AnyServiceKey(key)])
        }

        // Verify the entry's failure state carries our error.
        guard case .failed(let fault) = graph.state(of: key.id) else {
            Issue.record("expected .failed for the entry; got \(graph.state(of: key.id))")
            return
        }
        #expect(fault.errorType.contains("ServiceGraphError"),
                "fault should reflect ServiceGraphError.missingConfigReader; got \(fault.errorType)")
    }
}

// MARK: - Helpers

/// Single-slot reference holder used by the requireConfig tests to
/// snapshot a `ConfigReader?` from inside a factory closure.
private final class SyncMutableReference<T: Sendable>: @unchecked Sendable {
    private let mutex = Mutex<T?>(nil)
    func set(_ value: T) { mutex.withLock { $0 = value } }
    func get() -> T? { mutex.withLock { $0 } }
}
