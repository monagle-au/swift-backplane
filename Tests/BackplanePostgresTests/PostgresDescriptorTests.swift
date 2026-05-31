//
//  PostgresDescriptorTests.swift
//  swift-backplane
//
//  Tests for the 2.0 BackplanePostgres surface: the public key,
//  the descriptor helper, and the missingConfigReader error path.
//  Does not exercise the live PostgresClient — that requires a
//  running Postgres and is out of scope for CI.
//

#if BACKPLANE_POSTGRES

import Configuration
import Backplane
import BackplanePostgres
import Logging
import Testing

@Suite("BackplanePostgres — descriptor surface")
struct PostgresDescriptorTests {

    @Test("postgresKey carries the expected id")
    func keyShape() {
        #expect(Services().postgresKey.id == "postgres")
    }

    @Test("postgresEntryDescriptor() produces a descriptor whose factory throws when the graph has no config")
    func descriptorThrowsWithoutConfig() async throws {
        // Graph constructed *without* a ConfigReader. The descriptor's
        // factory should throw on boot.
        let graph = try ServiceGraph(
            descriptors: [postgresEntryDescriptor()],
            logger: Logger(label: "PostgresDescriptorTests")
        )

        await #expect(throws: (any Error).self) {
            try await graph.boot(roots: [AnyServiceKey(Services().postgresKey)])
        }

        // Drill into the entry's state to confirm the failure is
        // recorded as a faulted .failed transition.
        let state = graph.state(of: Services().postgresKey.id)
        if case .failed(let fault) = state {
            #expect(fault.errorType.contains("ServiceGraphError"),
                    "fault should reflect ServiceGraphError.missingConfigReader; got \(fault.errorType)")
        } else {
            Issue.record("Expected .failed; got \(state)")
        }
    }

    @Test("postgresEntryDescriptor() accepts custom subgroup + dependencies")
    func descriptorAcceptsCustomization() throws {
        // We don't have @testable access here so we can't introspect
        // the descriptor's internal `subgroup` / `dependencies`
        // fields directly. What we can do: confirm the call shape
        // compiles and produces a usable descriptor. Behavioural
        // verification of subgroup partitioning + dependency ordering
        // lives in Backplane's own graph tests.
        _ = postgresEntryDescriptor(
            subgroup: .integrations,
            dependencies: [\.postgresKey]
        )
    }
}

#endif
