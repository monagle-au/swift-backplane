import Testing
@testable import Backplane

private struct StateStreamTestService: ManagedService {
    func start() async throws {}
    func shutdown() async {}
}

@Suite("ServiceEntry state-stream ordering")
struct StateStreamOrderingTests {
    @Test("concurrent transitions give subscribers the same ordered history")
    func concurrentTransitionsStayOrdered() async {
        let key = ServiceKey<StateStreamTestService>(id: "state-stream-ordering")
        let descriptor = EntryDescriptor(key) { _ in StateStreamTestService() }
        let entry = ServiceEntry(descriptor: descriptor)

        let transitionCount = 8 * 2_000
        let streamA = entry.stateStream()
        let streamB = entry.stateStream()
        let collectorA = Task.detached { await Self.collect(streamA, count: transitionCount + 1) }
        let collectorB = Task.detached { await Self.collect(streamB, count: transitionCount + 1) }

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    let states: [ServiceState] = [.starting, .running, .stopped, .replacing]
                    for index in 0..<2_000 {
                        entry.transition(to: states[(worker + index) % states.count])
                    }
                }
            }
        }

        let expectedFinalState = entry.currentState
        let historyA = await collectorA.value
        let historyB = await collectorB.value

        #expect(historyA.count == transitionCount + 1)
        #expect(historyB.count == transitionCount + 1)
        #expect(historyA.first == .unconfigured)
        #expect(historyB.first == .unconfigured)
        let firstMismatch = zip(historyA, historyB).enumerated().first {
            $0.element.0 != $0.element.1
        }?.offset
        #expect(
            firstMismatch == nil,
            "subscribers first diverged at event \(String(describing: firstMismatch))"
        )
        #expect(historyA.last == expectedFinalState)
    }

    private static func collect(
        _ stream: AsyncStream<ServiceState>,
        count: Int
    ) async -> [ServiceState] {
        var values: [ServiceState] = []
        for await value in stream {
            values.append(value)
            if values.count == count { break }
        }
        return values
    }
}
