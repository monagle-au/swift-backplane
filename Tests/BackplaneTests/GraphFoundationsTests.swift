//
//  GraphFoundationsTests.swift
//  swift-backplane
//

import Foundation
import Testing
@testable import Backplane

@Suite("Graph foundations")
struct GraphFoundationsTests {

    // MARK: - ServiceState

    @Test("ServiceState equality covers payload-bearing cases")
    func stateEquality() {
        let fault = ServiceFault(
            description: "x",
            errorType: "T",
            firstObservedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(ServiceState.running == ServiceState.running)
        #expect(ServiceState.degraded(fault: fault) == ServiceState.degraded(fault: fault))
        #expect(ServiceState.running != ServiceState.replacing)
    }

    @Test("ServiceState is Hashable across all cases")
    func stateHashable() {
        let fault = ServiceFault(
            description: "x",
            errorType: "T",
            firstObservedAt: Date(timeIntervalSince1970: 0)
        )
        let states: Set<ServiceState> = [
            .unconfigured, .configuring, .starting, .running,
            .degraded(fault: fault), .replacing, .stopped,
            .failed(fault: fault),
        ]
        #expect(states.count == 8)
    }

    // MARK: - ServiceFault

    @Test("ServiceFault(from:) populates description and errorType")
    func faultFromError() {
        struct WidgetError: Error {}
        let fault = ServiceFault(from: WidgetError())
        #expect(fault.description.contains("WidgetError"))
        #expect(fault.errorType.contains("WidgetError"))
        #expect(fault.consecutiveCount == 1)
    }

    // MARK: - ServiceKey

    @Test("ServiceKey identity is the string id")
    func entryKeyIdentity() {
        let a = ServiceKey<String>(id: "x")
        let b = ServiceKey<String>(id: "x")
        let c = ServiceKey<String>(id: "y")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("AnyServiceKey erases the typed key to its id")
    func anyServiceKeyErasure() {
        let typed = ServiceKey<Int>(id: "counter")
        let erased = AnyServiceKey(typed)
        #expect(erased.id == "counter")
        #expect(erased == AnyServiceKey(id: "counter"))
    }
}
