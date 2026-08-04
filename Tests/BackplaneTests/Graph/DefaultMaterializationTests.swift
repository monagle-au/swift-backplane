//
//  DefaultMaterializationTests.swift
//  swift-backplane
//
//  Tests for environment-model registration: keys whose Value conforms
//  to BackplaneService materialise default descriptors on demand via
//  ServiceGraph.materializedDescriptors(explicit:roots:).
//

import Configuration
import Foundation
import Logging
import Synchronization
import Testing
@testable import Backplane

// MARK: - Self-describing test services

/// Leaf service: no dependencies, all defaults.
final class MatLeafService: BackplaneService, @unchecked Sendable {
    let instanceID = UUID()
    let marker: String

    init(marker: String) { self.marker = marker }

    static func make(context: BackplaneContext) async throws -> MatLeafService {
        MatLeafService(marker: context.config?.string(forKey: "marker") ?? "default")
    }

    func start() async throws {}
    func shutdown() async {}
}

/// Mid-tier service: statically depends on the leaf.
final class MatMidService: BackplaneService, @unchecked Sendable {
    let leaf: MatLeafService

    init(leaf: MatLeafService) { self.leaf = leaf }

    static func make(context: BackplaneContext) async throws -> MatMidService {
        MatMidService(leaf: try await context.requireService(\.matLeaf, timeout: .seconds(5)))
    }

    static var dependencies: ServiceList { [\.matLeaf] }
    static var subgroup: SubgroupTag { .integrations }

    func start() async throws {}
    func shutdown() async {}
}

/// Root service: statically depends on the mid tier.
final class MatRootService: BackplaneService, @unchecked Sendable {
    let mid: MatMidService

    init(mid: MatMidService) { self.mid = mid }

    static func make(context: BackplaneContext) async throws -> MatRootService {
        MatRootService(mid: try await context.requireService(\.matMid, timeout: .seconds(5)))
    }

    static var dependencies: ServiceList { [\.matMid] }

    func start() async throws {}
    func shutdown() async {}
}

/// A ManagedService that is NOT a BackplaneService — cannot self-materialise.
final class MatPlainService: ManagedService, @unchecked Sendable {
    func start() async throws {}
    func shutdown() async {}
}

/// Two services whose static dependencies form a cycle.
final class MatCycleAService: BackplaneService, @unchecked Sendable {
    static func make(context: BackplaneContext) async throws -> MatCycleAService {
        MatCycleAService()
    }
    static var dependencies: ServiceList { [\.matCycleB] }
    func start() async throws {}
    func shutdown() async {}
}

final class MatCycleBService: BackplaneService, @unchecked Sendable {
    static func make(context: BackplaneContext) async throws -> MatCycleBService {
        MatCycleBService()
    }
    static var dependencies: ServiceList { [\.matCycleA] }
    func start() async throws {}
    func shutdown() async {}
}

extension Services {
    var matLeaf: ServiceKey<MatLeafService> { "mat-leaf" }
    var matMid: ServiceKey<MatMidService> { "mat-mid" }
    var matRoot: ServiceKey<MatRootService> { "mat-root" }
    var matPlain: ServiceKey<MatPlainService> { "mat-plain" }
    var matCycleA: ServiceKey<MatCycleAService> { "mat-cycle-a" }
    var matCycleB: ServiceKey<MatCycleBService> { "mat-cycle-b" }
}

// MARK: - Suite

@Suite("ServiceGraph — default materialisation")
struct DefaultMaterializationTests {

    // MARK: Test 1 — a required conforming key needs no services() entry

    @Test("A required BackplaneService key materialises with no explicit descriptor")
    func defaultFromRoot() async throws {
        let descriptors = try ServiceGraph.materializedDescriptors(
            explicit: [],
            roots: [\.matLeaf]
        )
        #expect(descriptors.count == 1)
        #expect(descriptors.first?.id == "mat-leaf")

        // And it boots end to end.
        let graph = try ServiceGraph(descriptors: descriptors)
        try await graph.boot()
        #expect(graph.resolve(Services().matLeaf) != nil)
    }

    // MARK: Test 2 — transitive static dependencies materialise

    @Test("Static dependencies materialise transitively from a single root")
    func transitiveStaticDependencies() async throws {
        let descriptors = try ServiceGraph.materializedDescriptors(
            explicit: [],
            roots: [\.matRoot]
        )
        #expect(Set(descriptors.map(\.id)) == ["mat-root", "mat-mid", "mat-leaf"])

        // Statics carried through: subgroup came from the type.
        let mid = descriptors.first { $0.id == "mat-mid" }
        #expect(mid?.subgroup == .integrations)

        // The whole chain boots and cross-resolves.
        let graph = try ServiceGraph(descriptors: descriptors)
        try await graph.boot(roots: [AnyServiceKey(id: "mat-root")])
        let root = graph.resolve(Services().matRoot)
        #expect(root != nil)
        #expect(root?.mid.leaf != nil)
    }

    // MARK: Test 3 — explicit descriptor wins over the default

    @Test("An explicit descriptor for a conforming key beats the default; its keypath deps still materialise")
    func explicitOverrideWins() async throws {
        // Explicit registration for mat-mid with a custom factory that
        // marks the leaf it resolves — deps declared as keypaths so the
        // leaf's default still materialises.
        let explicitUsed = Mutex<Bool>(false)
        let explicit = EntryDescriptor(
            \.matMid,
            dependencies: [\.matLeaf]
        ) { context in
            explicitUsed.withLock { $0 = true }
            return MatMidService(leaf: try await context.requireService(\.matLeaf, timeout: .seconds(5)))
        }

        let descriptors = try ServiceGraph.materializedDescriptors(
            explicit: [explicit],
            roots: [\.matMid]
        )
        #expect(Set(descriptors.map(\.id)) == ["mat-mid", "mat-leaf"])

        let graph = try ServiceGraph(descriptors: descriptors)
        try await graph.boot()
        #expect(graph.resolve(Services().matMid) != nil)
        #expect(explicitUsed.withLock { $0 }, "the explicit factory must be used, not the default")
    }

    // MARK: Test 4 — closure-free override inherits and overrides statics

    @Test("Closure-free EntryDescriptor inherits statics; explicit parameters override them")
    func closureFreeOverride() throws {
        let inherited = EntryDescriptor(\.matMid)
        #expect(inherited.subgroup == .integrations, "nil subgroup must fall back to the type's static")
        #expect(inherited.dependencies.map(\.id) == ["mat-leaf"])

        let overridden = EntryDescriptor(\.matMid, subgroup: .core, dependencies: [])
        #expect(overridden.subgroup == .core)
        #expect(overridden.dependencies.isEmpty, "supplied dependencies replace the static list")
    }

    // MARK: Test 5 — non-conforming unregistered key is a typed error

    @Test("A required key with no descriptor and no conformance throws unresolvableService")
    func unresolvableServiceThrows() {
        #expect {
            _ = try ServiceGraph.materializedDescriptors(
                explicit: [],
                roots: [\.matPlain]
            )
        } throws: { error in
            guard case .unresolvableService(let id, _) = error as? ServiceGraphError else {
                return false
            }
            return id == "mat-plain"
        }
    }

    // MARK: Test 6 — static-dependency cycle surfaces from graph init

    @Test("A static-dependency cycle materialises finitely and throws cyclicDependency at init")
    func staticCycleDetected() throws {
        // Materialisation must terminate (visited set) …
        let descriptors = try ServiceGraph.materializedDescriptors(
            explicit: [],
            roots: [\.matCycleA]
        )
        #expect(Set(descriptors.map(\.id)) == ["mat-cycle-a", "mat-cycle-b"])

        // … and init's DFS names the cycle.
        #expect {
            _ = try ServiceGraph(descriptors: descriptors)
        } throws: { error in
            guard case .cyclicDependency = error as? ServiceGraphError else { return false }
            return true
        }
    }

    // MARK: Test 7 — bare AnyServiceKey dependencies don't materialise

    @Test("Dependencies declared as bare AnyServiceKey ids do not pull in defaults")
    func bareKeyDependenciesDontMaterialise() throws {
        // Explicit entry declaring its dep by erased id only — 1.x style.
        let key = ServiceKey<MatPlainService>(id: "plain-root")
        let explicit = EntryDescriptor(
            key,
            dependencies: [AnyServiceKey(id: "mat-leaf")]
        ) { _ in MatPlainService() }

        // The walk sees no keypath deps, so mat-leaf is NOT materialised —
        // graph init then reports the unknown dependency.
        let descriptors = try ServiceGraph.materializedDescriptors(
            explicit: [explicit],
            roots: []
        )
        #expect(descriptors.map(\.id) == ["plain-root"])
    }

    // MARK: Test 8 — default entry reads its own config scope

    @Test("A materialised default's make(context:) sees entry-scoped config")
    func defaultFactorySeesScopedConfig() async throws {
        let config = ConfigReader(provider: InMemoryProvider(values: [
            "mat-leaf.marker": .init(.string("scoped!"), isSecret: false),
        ]))

        let descriptors = try ServiceGraph.materializedDescriptors(
            explicit: [],
            roots: [\.matLeaf]
        )
        let graph = try ServiceGraph(descriptors: descriptors, config: config)
        try await graph.boot()

        #expect(graph.resolve(Services().matLeaf)?.marker == "scoped!")
    }
}
