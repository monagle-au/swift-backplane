//
//  ConcurrentReaderHarness.swift
//  swift-backplane
//
//  Test driver that spawns N concurrent tasks calling
//  `ServiceGraph.resolve(_:)` in a tight loop, recording every
//  observation (including nil). Used by the restart-and-availability
//  stress tests to assert that consumers never see nil during a
//  blue-green swap and that the swap is actually observable from
//  the consumer side.
//

import Foundation
import Synchronization
@testable import Backplane

/// A test driver that holds the graph + key under test and spawns
/// concurrent readers. Each reader logs an ``Observation`` per
/// resolve call (timestamp + reader id + instance fingerprint, or
/// `nil` if `resolve` returned nil). The harness is single-use:
/// `start(...)` → wait/perform mutations → `stop()` → inspect.
final class ConcurrentReaderHarness<T: ManagedService>: @unchecked Sendable {

    /// One reader's observation.
    struct Observation: Sendable, Equatable {
        let timestamp: ContinuousClock.Instant
        let readerID: Int
        /// The fingerprint of the resolved instance, or `nil` if the
        /// resolve returned nil.
        let instanceFingerprint: String?
    }

    private struct State {
        var observations: [Observation] = []
        var tasks: [Task<Void, Never>] = []
    }

    private let graph: ServiceGraph
    private let key: ServiceKey<T>
    private let fingerprint: @Sendable (T) -> String
    private let state = Mutex(State())

    /// - Parameters:
    ///   - graph: the graph under test
    ///   - key: the key reader tasks will resolve
    ///   - fingerprint: closure extracting a stable string from the
    ///     resolved instance — typically `{ $0.instanceID.uuidString }`
    ///     for services with a UUID.
    init(
        graph: ServiceGraph,
        key: ServiceKey<T>,
        fingerprint: @escaping @Sendable (T) -> String
    ) {
        self.graph = graph
        self.key = key
        self.fingerprint = fingerprint
    }

    /// Spawn `readers` reader tasks. Each performs `iterations` calls
    /// to `graph.resolve(key)` with a brief sleep between iterations
    /// to ensure readers are actually scheduled across other tasks'
    /// timelines (a bare `Task.yield()` can return immediately when
    /// no other task is ready, so 5000 iterations can complete in
    /// microseconds — defeating any test that wants readers to span
    /// a time window). Returns immediately.
    func start(readers: Int, iterations: Int) {
        for readerID in 0..<readers {
            let task = Task<Void, Never> { [graph, key, fingerprint] in
                for _ in 0..<iterations {
                    let instance = graph.resolve(key)
                    let obs = Observation(
                        timestamp: ContinuousClock.now,
                        readerID: readerID,
                        instanceFingerprint: instance.map(fingerprint)
                    )
                    self.state.withLock { (s: inout State) in
                        s.observations.append(obs)
                    }
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .microseconds(100), clock: .continuous)
                }
            }
            state.withLock { (s: inout State) in s.tasks.append(task) }
        }
    }

    /// Spawn `readers` reader tasks that loop until `stop()` is
    /// called or the surrounding task is cancelled. Each iteration
    /// resolves, records an observation, and sleeps briefly. Use
    /// this mode when the test needs readers to span a controlled
    /// timeline — e.g. across a deterministic gate release.
    func startUntilStop(readers: Int) {
        for readerID in 0..<readers {
            let task = Task<Void, Never> { [graph, key, fingerprint] in
                while !Task.isCancelled {
                    let instance = graph.resolve(key)
                    let obs = Observation(
                        timestamp: ContinuousClock.now,
                        readerID: readerID,
                        instanceFingerprint: instance.map(fingerprint)
                    )
                    self.state.withLock { (s: inout State) in
                        s.observations.append(obs)
                    }
                    try? await Task.sleep(for: .microseconds(100), clock: .continuous)
                }
            }
            state.withLock { (s: inout State) in s.tasks.append(task) }
        }
    }

    /// Stop all readers and wait for them to complete. Idempotent.
    func stop() async {
        let tasks = state.withLock { (s: inout State) -> [Task<Void, Never>] in
            let captured = s.tasks
            s.tasks = []
            return captured
        }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    // MARK: - Inspection

    var observations: [Observation] {
        state.withLock { $0.observations }
    }

    var observationCount: Int {
        state.withLock { $0.observations.count }
    }

    var nilCount: Int {
        state.withLock { s in s.observations.filter { $0.instanceFingerprint == nil }.count }
    }

    var distinctFingerprints: Set<String> {
        state.withLock { s in
            Set(s.observations.compactMap { $0.instanceFingerprint })
        }
    }
}
