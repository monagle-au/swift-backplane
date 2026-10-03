//
//  StateStreamOrderingTests.swift
//  swift-backplane
//
//  Regression tests for issue #10: `ServiceEntry` state streams must
//  deliver states in the order they were applied, and a subscriber's
//  last element must match `currentState` once transitions settle.
//

import Foundation
import Testing
@testable import Backplane

@Suite("State stream ordering")
struct StateStreamOrderingTests {

    private static let iterations = 500
    private static let burst = 32
    private static let subscribers = 8

    private static func makeEntry() -> ServiceEntry {
        ServiceEntry(descriptor: EntryDescriptor(
            id: "ordering",
            factory: { _ in PassiveService(0) },
            replacement: .standard,
            subgroup: .core,
            dependencies: [],
            dependencyKeyPaths: [],
            project: { $0 }
        ))
    }

    /// A distinct, ordered state: `.degraded` whose description carries `n`.
    private static func step(_ n: Int) -> ServiceState {
        .degraded(fault: ServiceFault(
            description: String(n),
            errorType: "Step",
            firstObservedAt: Date(timeIntervalSince1970: 0)
        ))
    }

    /// The step number of a state; `.unconfigured` (the initial replay) is -1.
    private static func stepNumber(_ state: ServiceState) -> Int? {
        switch state {
        case .unconfigured: return -1
        case .degraded(let fault): return Int(fault.description)
        default: return nil
        }
    }

    /// Collect elements up to and including the `.stopped` sentinel.
    private static func collect(_ stream: AsyncStream<ServiceState>) async -> [ServiceState] {
        var received: [ServiceState] = []
        for await state in stream {
            received.append(state)
            if state == .stopped { break }
        }
        return received
    }

    @Test("Replay never arrives after a concurrent transition")
    func replayOrderedWithConcurrentTransitions() async {
        for _ in 0..<Self.iterations {
            let entry = Self.makeEntry()

            // Subscribe concurrently with a strictly-increasing burst.
            let streams = await withTaskGroup(of: AsyncStream<ServiceState>?.self) { group in
                group.addTask {
                    for n in 0..<Self.burst { entry.transition(to: Self.step(n)) }
                    return nil
                }
                for _ in 0..<Self.subscribers {
                    group.addTask { entry.stateStream() }
                }
                var streams: [AsyncStream<ServiceState>] = []
                for await stream in group { if let stream { streams.append(stream) } }
                return streams
            }

            // Every yield above has returned; the sentinel is ordered after them.
            entry.transition(to: .stopped)
            for stream in streams {
                let received = await Self.collect(stream)
                #expect(received.last == .stopped)
                let steps = received.dropLast().compactMap(Self.stepNumber)
                #expect(steps.count == received.count - 1)
                #expect(steps == steps.sorted() && Set(steps).count == steps.count,
                        "out-of-order delivery: \(steps)")
            }
        }
    }

    @Test("Concurrent transitions: subscriber's last element matches currentState")
    func concurrentTransitionsSettleOnCurrentState() async {
        for _ in 0..<Self.iterations {
            let entry = Self.makeEntry()
            let stream = entry.stateStream()

            await withTaskGroup(of: Void.self) { group in
                for n in 0..<Self.burst {
                    group.addTask { entry.transition(to: Self.step(n)) }
                }
            }
            let settled = entry.currentState

            entry.transition(to: .stopped)
            let received = await Self.collect(stream)

            #expect(received.dropLast().last == settled)
        }
    }

    @Test("Concurrent health reports: subscriber's last element matches currentState")
    func concurrentHealthReportsSettleOnCurrentState() async {
        for _ in 0..<Self.iterations {
            let entry = Self.makeEntry()
            entry.transition(to: .running)
            let stream = entry.stateStream()

            await withTaskGroup(of: Void.self) { group in
                for n in 0..<Self.burst {
                    group.addTask {
                        if n.isMultiple(of: 2) {
                            entry.markDegraded(fault: ServiceFault(
                                description: String(n),
                                errorType: "Step",
                                firstObservedAt: Date(timeIntervalSince1970: 0)
                            ))
                        } else {
                            entry.markHealthy()
                        }
                    }
                }
            }
            let settled = entry.currentState

            entry.transition(to: .stopped)
            let received = await Self.collect(stream)

            #expect(received.dropLast().last == settled)
        }
    }

    /// `yield` resumes a consumer (taking its task status lock), while
    /// `Task.cancel()` holds that lock as `onTermination` takes the
    /// entry lock. Yielding under the entry lock deadlocks here — and
    /// wedges the cooperative pool, so `.timeLimit` cannot fire: a
    /// regression shows up as a hung test run, not a failure.
    @Test("Cancelling subscribers during a burst does not deadlock", .timeLimit(.minutes(1)))
    func cancellationDuringBurst() async {
        for _ in 0..<Self.iterations {
            let entry = Self.makeEntry()
            let consumers = (0..<Self.subscribers).map { _ in
                let stream = entry.stateStream()
                return Task { for await _ in stream {} }
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for n in 0..<Self.burst { entry.transition(to: Self.step(n)) }
                }
                for consumer in consumers {
                    group.addTask { consumer.cancel() }
                }
            }
            for consumer in consumers { await consumer.value }
            entry.transition(to: .stopped)
        }
    }
}
