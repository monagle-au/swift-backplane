//
//  DescriptorStrategyTests.swift
//  swift-backplane
//
//  Tests that the replacement strategy is declarative: the descriptor's
//  replacement: wins, falling back to a BackplaneService type's static.
//

import Foundation
import Testing
@testable import Backplane

/// A self-describing service that declares coldRestart as its static
/// strategy.
final class StrategyDeclaringService: BackplaneService, @unchecked Sendable {
    static func make(context: BackplaneContext) async throws -> StrategyDeclaringService {
        StrategyDeclaringService()
    }
    static var replacementStrategy: ReplacementStrategy { .coldRestart }
    func start() async throws {}
    func shutdown() async {}
}

extension Services {
    var strategyDeclaring: ServiceKey<StrategyDeclaringService> { "strategy-declaring" }
}

@Suite("EntryDescriptor — declarative replacement strategy")
struct DescriptorStrategyTests {

    @Test("Closure-free descriptor inherits the type's static strategy")
    func closureFreeInheritsStatic() {
        let descriptor = EntryDescriptor(\.strategyDeclaring)
        guard case .coldRestart = descriptor.replacement else {
            Issue.record("expected the type's static .coldRestart; got \(descriptor.replacement)")
            return
        }
    }

    @Test("Descriptor replacement: override beats the type's static")
    func descriptorOverrideBeatsStatic() {
        let descriptor = EntryDescriptor(
            \.strategyDeclaring,
            replacement: .blueGreen(grace: .milliseconds(10))
        )
        guard case .blueGreen(let grace) = descriptor.replacement else {
            Issue.record("expected the override to win; got \(descriptor.replacement)")
            return
        }
        #expect(grace == .milliseconds(10))
    }

    @Test("Closure forms default to .standard")
    func closureFormsDefaultToStandard() {
        let key = ServiceKey<StrategyDeclaringService>(id: "closure-form")
        let descriptor = EntryDescriptor(key) { _ in StrategyDeclaringService() }
        guard case .blueGreen(let grace) = descriptor.replacement else {
            Issue.record("closure forms must default to .standard; got \(descriptor.replacement)")
            return
        }
        #expect(grace == .seconds(30))
    }
}
