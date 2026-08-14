//
//  PostgresDescriptorTests.swift
//  swift-backplane
//
//  Tests for the 2.0 BackplanePostgres surface: the public key, default
//  materialisation from the BackplaneService conformance, and the
//  missingConfigReader error path. Does not exercise the live
//  PostgresClient — that requires a running Postgres and is out of
//  scope for CI.
//

#if BACKPLANE_POSTGRES

import Configuration
import Backplane
import BackplanePostgres
import Logging
import Testing

@Suite("BackplanePostgres — key and default materialisation")
struct PostgresDescriptorTests {

    @Test("postgres key carries the expected id")
    func keyShape() {
        #expect(Services().postgres.id == "postgres")
    }

    @Test("Requiring \\.postgres materialises a default — no services() entry needed")
    func defaultMaterialises() throws {
        let descriptors = try ServiceGraph.materializedDescriptors(
            explicit: [],
            roots: [\.postgres]
        )
        #expect(descriptors.count == 1)
    }

    @Test("The materialised default's make(context:) throws when the graph has no config")
    func defaultThrowsWithoutConfig() async throws {
        let descriptors = try ServiceGraph.materializedDescriptors(
            explicit: [],
            roots: [\.postgres]
        )

        // Graph constructed *without* a ConfigReader — make(context:)
        // requires one, so boot should record a failure.
        let graph = try ServiceGraph(
            descriptors: descriptors,
            logger: Logger(label: "PostgresDescriptorTests")
        )

        await #expect(throws: (any Error).self) {
            try await graph.boot(roots: [AnyServiceKey(Services().postgres)])
        }

        let state = graph.state(of: Services().postgres.id)
        if case .failed(let fault) = state {
            #expect(fault.errorType.contains("ServiceGraphError"),
                    "fault should reflect ServiceGraphError.missingConfigReader; got \(fault.errorType)")
        } else {
            Issue.record("Expected .failed; got \(state)")
        }
    }

    @Test("Explicit descriptor overrides compile for subgroup and dependencies")
    func closureFreeOverrideCompiles() {
        // The closure-free override form — no factory needed because
        // BackplanePostgresService conforms to BackplaneService.
        _ = EntryDescriptor(\.postgres, subgroup: .integrations)
    }

    @Test("A second key with a different id materialises its own entry (multi-instance)")
    func multiInstanceMaterialises() throws {
        let analytics = ServiceKey<BackplanePostgresService>(id: "analytics")

        // Both keys resolve BackplanePostgresService; each entry reads
        // its own config scope (postgres.* vs analytics.*).
        let descriptors = try ServiceGraph.materializedDescriptors(
            explicit: [EntryDescriptor(analytics)],
            roots: [\.postgres]
        )
        #expect(descriptors.count == 2)
    }
}

#endif
