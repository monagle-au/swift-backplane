//
//  ConfigurationFlowTests.swift
//  swift-backplane
//
//  Tests that BackplaneContext.config carries through from
//  ServiceGraph.init to a factory closure, scoped to the entry id,
//  with rootConfig as the unscoped escape hatch.
//

import Configuration
import Foundation
import Logging
import Synchronization
import Testing
@testable import Backplane

private final class ConfigCapturingService: ManagedService, @unchecked Sendable {
    let capturedValue: String?
    let capturedRoot: String?

    init(capturedValue: String?, capturedRoot: String? = nil) {
        self.capturedValue = capturedValue
        self.capturedRoot = capturedRoot
    }

    func start() async throws {}
    func shutdown() async {}
}

@Suite("BackplaneContext.config — flow into factories")
struct ConfigurationFlowTests {

    @Test("context.config is scoped to the entry id; rootConfig is unscoped")
    func factoryReadsScopedConfig() async throws {
        let config = ConfigReader(provider: InMemoryProvider(values: [
            "myService.host": .init(.string("example.com"), isSecret: false),
        ]))

        let key = ServiceKey<ConfigCapturingService>(id: "myService")

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key) { context in
                    // Entry id "myService" — the reader is pre-scoped.
                    let host = context.config?.string(forKey: "host")
                    let rootHost = context.rootConfig?.string(forKey: "myService.host")
                    return ConfigCapturingService(
                        capturedValue: host,
                        capturedRoot: rootHost
                    )
                },
            ],
            logger: Logger(label: "ConfigurationFlowTests"),
            config: config
        )

        try await graph.boot(roots: [AnyServiceKey(key)])

        let svc = graph.resolve(key)
        #expect(svc?.capturedValue == "example.com",
                "context.config must be pre-scoped to the entry id")
        #expect(svc?.capturedRoot == "example.com",
                "rootConfig must expose the full, unscoped key space")
    }

    @Test("Two keys, same service type, different ids read different scopes")
    func multiInstanceScoping() async throws {
        let config = ConfigReader(provider: InMemoryProvider(values: [
            "primary.host": .init(.string("primary.db"), isSecret: false),
            "analytics.host": .init(.string("analytics.db"), isSecret: false),
        ]))

        let primaryKey = ServiceKey<ConfigCapturingService>(id: "primary")
        let analyticsKey = ServiceKey<ConfigCapturingService>(id: "analytics")

        // One factory shape, two registrations — each context reads its
        // own scope, which is what makes multi-instance registration work.
        @Sendable func factory(_ context: BackplaneContext) -> ConfigCapturingService {
            ConfigCapturingService(capturedValue: context.config?.string(forKey: "host"))
        }

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(primaryKey) { factory($0) },
                EntryDescriptor(analyticsKey) { factory($0) },
            ],
            logger: Logger(label: "ConfigurationFlowTests"),
            config: config
        )

        try await graph.boot()

        #expect(graph.resolve(primaryKey)?.capturedValue == "primary.db")
        #expect(graph.resolve(analyticsKey)?.capturedValue == "analytics.db")
    }

    @Test("Factory sees nil config and nil rootConfig when the graph has none")
    func factorySeesNilWhenGraphHasNoConfig() async throws {
        let key = ServiceKey<ConfigCapturingService>(id: "myService")

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(key) { context in
                    #expect(context.config == nil,
                            "context.config should be nil when ServiceGraph.init didn't receive one")
                    #expect(context.rootConfig == nil,
                            "rootConfig should be nil exactly when config is nil")
                    return ConfigCapturingService(capturedValue: nil)
                },
            ],
            logger: Logger(label: "ConfigurationFlowTests")
        )

        try await graph.boot(roots: [AnyServiceKey(key)])
        let svc = graph.resolve(key)
        #expect(svc?.capturedValue == nil)
    }
}
