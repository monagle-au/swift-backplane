//
//  ApplicationRunnerIntegrationTests.swift
//  swift-backplane
//
//  End-to-end tests for ApplicationRunner: the layer between
//  BackplaneCommand.run() and the ServiceGraph. Exercises the actual
//  wiring (graph boot + outer ServiceGroup + bootstrap lifecycle
//  services + command execute closure).
//

import Configuration
import Foundation
import Logging
import ServiceLifecycle
import Synchronization
import Testing
@testable import Backplane

// MARK: - Recording service

/// Shared per-test observer. The `Mutex` lives behind a class wrapper
/// so it can be passed to services and lifecycle recorders without
/// per-parameter ownership ceremony.
final class IntegrationRecordingObserver: @unchecked Sendable {
    struct State {
        var startedIDs: [String] = []
        var shutdownIDs: [String] = []
        var executeRan = false
    }

    private let mutex = Mutex(State())

    func withLock<R: Sendable>(
        _ body: (inout sending State) -> sending R
    ) -> R {
        mutex.withLock(body)
    }
}

/// A `ManagedService` that records every `start()` / `shutdown()`
/// invocation against a shared observer. Used to verify ordering and
/// presence of lifecycle calls without race-prone clock-time
/// comparisons.
final class IntegrationRecordingService: ManagedService, @unchecked Sendable {
    let id: String
    let observer: IntegrationRecordingObserver

    nonisolated var replacementStrategy: ReplacementStrategy {
        .blueGreen(grace: .milliseconds(50))
    }

    init(id: String, observer: IntegrationRecordingObserver) {
        self.id = id
        self.observer = observer
    }

    func start() async throws {
        observer.withLock { $0.startedIDs.append(id) }
    }

    func shutdown() async {
        observer.withLock { $0.shutdownIDs.append(id) }
    }
}

// MARK: - Helpers

private func makeLogger() -> Logger {
    Logger(label: "ApplicationRunnerIntegrationTests")
}

private func makeRunner(
    descriptors: [EntryDescriptor],
    config: ConfigReader? = nil
) throws -> (ApplicationRunner, ServiceGraph) {
    let logger = makeLogger()
    let graph = try ServiceGraph(
        descriptors: descriptors,
        logger: logger,
        config: config
    )
    let runner = ApplicationRunner(
        identifier: "test-app",
        graph: graph,
        config: config ?? ConfigReader(provider: InMemoryProvider(values: [:])),
        environment: .development,
        logger: logger
    )
    return (runner, graph)
}

// MARK: - Suite

@Suite("ApplicationRunner — integration")
struct ApplicationRunnerIntegrationTests {

    // MARK: Test 1 — TaskCommand mode runs execute and shuts down

    @Test("Task mode: services start, execute runs, services shut down in reverse")
    func taskModeFullFlow() async throws {
        let observer = IntegrationRecordingObserver()

        let key1 = ServiceKey<IntegrationRecordingService>(id: "svc1")
        let key2 = ServiceKey<IntegrationRecordingService>(id: "svc2")

        let (runner, _) = try makeRunner(descriptors: [
            EntryDescriptor(key1) { _ in
                IntegrationRecordingService(id: "svc1", observer: observer)
            },
            EntryDescriptor(key2) { _ in
                IntegrationRecordingService(id: "svc2", observer: observer)
            },
        ])

        try await runner.run(
            requiredServices: [],
            mode: .task,
            lifecycleServices: [],
            execute: { context in
                observer.withLock { $0.executeRan = true }
                let svc = try await context.requireService(key1)
                #expect(svc.id == "svc1")
            }
        )

        let snapshot = observer.withLock { $0 }
        #expect(snapshot.executeRan, "execute closure should have been invoked")
        #expect(Set(snapshot.startedIDs) == Set(["svc1", "svc2"]),
                "both services should start — got \(snapshot.startedIDs)")
        #expect(Set(snapshot.shutdownIDs) == Set(["svc1", "svc2"]),
                "both services should shut down — got \(snapshot.shutdownIDs)")
    }

    // MARK: Test 2 — PersistentCommand mode shuts down on outer cancellation

    @Test("Persistent mode: services run until the surrounding task is cancelled")
    func persistentModeCancellation() async throws {
        let observer = IntegrationRecordingObserver()

        let key = ServiceKey<IntegrationRecordingService>(id: "svc")

        let (runner, _) = try makeRunner(descriptors: [
            EntryDescriptor(key) { _ in
                IntegrationRecordingService(id: "svc", observer: observer)
            },
        ])

        let runTask = Task {
            try? await runner.run(
                requiredServices: [],
                mode: .persistent,
                lifecycleServices: [],
                execute: nil
            )
        }

        // Wait for the service to actually start before cancelling.
        let deadline = ContinuousClock.now + .seconds(2)
        while observer.withLock({ $0.startedIDs.isEmpty }) {
            if ContinuousClock.now > deadline {
                Issue.record("svc did not start within timeout")
                runTask.cancel()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        runTask.cancel()
        await runTask.value

        let snapshot = observer.withLock { $0 }
        #expect(snapshot.startedIDs == ["svc"])
        #expect(snapshot.shutdownIDs == ["svc"],
                "shutdown should run on cancellation, not be skipped — got \(snapshot.shutdownIDs)")
    }

    // MARK: Test 3 — requiredServices prunes the boot set

    @Test("Empty requiredServices boots every entry; named ones boot only the transitive closure")
    func requiredServicesPruning() async throws {
        let observer = IntegrationRecordingObserver()

        let keyA = ServiceKey<IntegrationRecordingService>(id: "a")
        let keyB = ServiceKey<IntegrationRecordingService>(id: "b")
        let keyC = ServiceKey<IntegrationRecordingService>(id: "c")

        // A depends on B. C is unrelated.
        let descriptors: [EntryDescriptor] = [
            EntryDescriptor(
                keyA,
                dependencies: [AnyServiceKey(keyB)]
            ) { _ in IntegrationRecordingService(id: "a", observer: observer) },
            EntryDescriptor(keyB) { _ in IntegrationRecordingService(id: "b", observer: observer) },
            EntryDescriptor(keyC) { _ in IntegrationRecordingService(id: "c", observer: observer) },
        ]

        // Boot with requiredServices=[A]: expect a and b, NOT c.
        let (runnerSubset, _) = try makeRunner(descriptors: descriptors)
        try await runnerSubset.run(
            requiredServices: [AnyServiceKey(keyA)],
            mode: .task,
            execute: { _ in }
        )

        let subsetSnapshot = observer.withLock { $0 }
        #expect(Set(subsetSnapshot.startedIDs) == Set(["a", "b"]),
                "requiredServices=[A] should boot {a, b} (transitive closure) — got \(subsetSnapshot.startedIDs)")
        #expect(!subsetSnapshot.startedIDs.contains("c"),
                "unrelated entry c should not boot")
    }

    @Test("Empty requiredServices boots all registered entries")
    func emptyRequiredServicesBootsAll() async throws {
        let observer = IntegrationRecordingObserver()

        let keys = ["a", "b", "c"].map { ServiceKey<IntegrationRecordingService>(id: $0) }
        let descriptors = keys.map { key in
            EntryDescriptor(key) { _ in IntegrationRecordingService(id: key.id, observer: observer) }
        }

        let (runner, _) = try makeRunner(descriptors: descriptors)
        try await runner.run(
            requiredServices: [],
            mode: .task,
            execute: { _ in }
        )

        let snapshot = observer.withLock { $0 }
        #expect(Set(snapshot.startedIDs) == Set(["a", "b", "c"]))
    }

    // MARK: Test 4 — Bootstrap lifecycle services start ahead of the graph

    @Test("Bootstrap lifecycle services start before graph entries")
    func bootstrapServicesStartFirst() async throws {
        let observer = IntegrationRecordingObserver()

        let key = ServiceKey<IntegrationRecordingService>(id: "graph-entry")

        // A lifecycle service that records its start ordering through
        // the same observer.
        struct LifecycleRecorder: Service, Sendable {
            let observer: IntegrationRecordingObserver
            func run() async throws {
                observer.withLock { $0.startedIDs.append("lifecycle") }
                try await Task.sleep(for: .seconds(Int32.max))
            }
        }

        let (runner, _) = try makeRunner(descriptors: [
            EntryDescriptor(key) { _ in
                IntegrationRecordingService(id: "graph-entry", observer: observer)
            },
        ])

        let lifecycle = LifecycleService(
            label: "lifecycle",
            mode: .persistent,
            service: LifecycleRecorder(observer: observer)
        )

        let runTask = Task {
            try? await runner.run(
                requiredServices: [],
                mode: .persistent,
                lifecycleServices: [lifecycle],
                execute: nil
            )
        }

        // Wait until both have started.
        let deadline = ContinuousClock.now + .seconds(2)
        while observer.withLock({ $0.startedIDs.count < 2 }) {
            if ContinuousClock.now > deadline { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        runTask.cancel()
        await runTask.value

        let snapshot = observer.withLock { $0 }
        #expect(snapshot.startedIDs.count >= 2)
        // ServiceGroup starts services in declaration order; lifecycle
        // services are appended first, so "lifecycle" should appear
        // before "graph-entry" in the start sequence.
        if let lifecycleIdx = snapshot.startedIDs.firstIndex(of: "lifecycle"),
           let entryIdx = snapshot.startedIDs.firstIndex(of: "graph-entry") {
            #expect(lifecycleIdx < entryIdx,
                    "lifecycle services should start before graph entries — got \(snapshot.startedIDs)")
        } else {
            Issue.record("Expected both lifecycle and graph-entry to have started; got \(snapshot.startedIDs)")
        }
    }
}
