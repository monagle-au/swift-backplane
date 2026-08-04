//
//  ConfigurationFlowTests.swift
//  swift-backplane
//
//  Tests that BackplaneContext.config carries through from
//  ServiceGraph.init to a factory closure and that scoped() works
//  as expected from inside a factory.
//

import Configuration
import Foundation
import Logging
import Synchronization
import Testing
@testable import Backplane

private final class ConfigCapturingService: ManagedService, @unchecked Sendable {
    let capturedValue: String?
    let capturedScoped: String?

    nonisolated var replacementStrategy: ReplacementStrategy {
        .blueGreen(grace: .milliseconds(50))
    }

    init(capturedValue: String?, capturedScoped: String?) {
        self.capturedValue = capturedValue
        self.capturedScoped = capturedScoped
    }

    func start() async throws {}
    func shutdown() async {}
}

@Suite("BackplaneContext.config — flow into factories")
struct ConfigurationFlowTests {

    @Test("Factory reads the same value the graph was constructed with")
    func factoryReadsConfig() async throws {
        let config = ConfigReader(provider: InMemoryProvider(values: [
            "myService.host": .init(.string("example.com"), isSecret: false),
        ]))

        let key = ServiceKey<ConfigCapturingService>(id: "myService")

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key) { context in
                    let host = context.config?.string(forKey: "myService.host")
                    let scopedHost = context.config?.scoped(to: "myService").string(forKey: "host")
                    return ConfigCapturingService(
                        capturedValue: host,
                        capturedScoped: scopedHost
                    )
                },
            ],
            logger: Logger(label: "ConfigurationFlowTests"),
            config: config
        )

        try await graph.boot(roots: [AnyServiceKey(key)])

        let svc = graph.resolve(key)
        #expect(svc?.capturedValue == "example.com",
                "factory should have read the value via context.config")
        #expect(svc?.capturedScoped == "example.com",
                "factory should have read via context.config.scoped(to:)")
    }

    @Test("Factory sees nil config when the graph was constructed without one")
    func factorySeesNilWhenGraphHasNoConfig() async throws {
        let key = ServiceKey<ConfigCapturingService>(id: "myService")

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key) { context in
                    #expect(context.config == nil,
                            "context.config should be nil when ServiceGraph.init didn't receive one")
                    return ConfigCapturingService(
                        capturedValue: nil,
                        capturedScoped: nil
                    )
                },
            ],
            logger: Logger(label: "ConfigurationFlowTests")
        )

        try await graph.boot(roots: [AnyServiceKey(key)])
        let svc = graph.resolve(key)
        #expect(svc?.capturedValue == nil)
    }
}
