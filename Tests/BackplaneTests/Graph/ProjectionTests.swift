//
//  ProjectionTests.swift
//  swift-backplane
//
//  Tests for projection-decoupled service keys: the resolved value
//  type (the key's `Value`) is decoupled from the lifecycle-managed
//  `ManagedService` via a projection captured at registration.
//
//  - Form 1 (identity): Value == ManagedService.
//  - Form 2 (passive):  Value behind a framework-supplied PassiveService.
//  - Form 3 (projected): a concrete ManagedService projected onto a
//    (typically protocol) Value.
//

import Foundation
import Synchronization
import Testing
@testable import Backplane

// MARK: - Test doubles

/// A passive value with no lifecycle of its own. Registered via `passive:`
/// behind a protocol-typed key.
private protocol DemoStore: Sendable {
    func ping() -> String
}

private struct ConcreteStore: DemoStore {
    let token: String
    func ping() -> String { token }
}

/// A `ManagedService` that records whether `start()`/`shutdown()` ran,
/// and is resolved through a protocol key in Form 3.
private protocol Recorder: Sendable {
    var id: UUID { get }
    var didStart: Bool { get }
    var didShutdown: Bool { get }
}

private final class RecordingManagedService: ManagedService, Recorder, @unchecked Sendable {
    let id = UUID()
    private let _started = Mutex(false)
    private let _shutdown = Mutex(false)

    var didStart: Bool { _started.withLock { $0 } }
    var didShutdown: Bool { _shutdown.withLock { $0 } }

    nonisolated var replacementStrategy: ReplacementStrategy {
        .blueGreen(grace: .milliseconds(50))
    }

    func start() async throws { _started.withLock { $0 = true } }
    func shutdown() async { _shutdown.withLock { $0 = true } }
}

/// A plain identity-bearing `ManagedService` for the Form 1 regression.
private final class RegularService: ManagedService, @unchecked Sendable {
    let instanceID = UUID()

    nonisolated var replacementStrategy: ReplacementStrategy {
        .blueGreen(grace: .milliseconds(50))
    }

    func start() async throws { }
    func shutdown() async { }
}

/// A passive counter actor — the kind of value that used to be keyed as
/// `ServiceKey<PassiveService<Counter>>` and accessed via `.inner`.
private actor Counter {
    private(set) var value: Int
    init(value: Int) { self.value = value }
    func increment() { value += 1 }
    func read() -> Int { value }
}

// MARK: - Keypath coverage

extension Services {
    fileprivate var demoStoreKP: ServiceKey<any DemoStore> { ServiceKey(id: "kp.demo-store") }
    fileprivate var recorderKP: ServiceKey<any Recorder> { ServiceKey(id: "kp.recorder") }
    fileprivate var regularKP: ServiceKey<RegularService> { ServiceKey(id: "kp.regular") }
}

// MARK: - Suite

@Suite("ServiceGraph — projection-decoupled keys")
struct ProjectionTests {

    // MARK: Test 0 — ExpressibleByStringLiteral

    /// A string literal is equivalent to `ServiceKey(id:)`.
    @Test("ServiceKey is ExpressibleByStringLiteral on its id")
    func testStringLiteralKey() {
        let literal: ServiceKey<Counter> = "counter"
        #expect(literal.id == "counter")
        #expect(literal == ServiceKey<Counter>(id: "counter"))
    }

    // MARK: Test 1 — Form 2 passive, protocol-typed key

    /// A `ServiceKey<any DemoStore>` registered with a concrete
    /// `ConcreteStore` via `passive:` resolves to a working
    /// `any DemoStore` — and the `PassiveService` wrapper never surfaces.
    @Test("passive: keys a protocol against a concrete passive value")
    func testPassiveProtocolKey() async throws {
        let key = ServiceKey<any DemoStore>(id: "demo-store")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, passive: { _ in ConcreteStore(token: "pong") }),
        ])
        try await graph.boot()

        let resolved: (any DemoStore)? = graph.resolve(key)
        #expect(resolved != nil)
        #expect(resolved?.ping() == "pong")

        // The resolved value is the concrete behind the protocol — not a
        // PassiveService wrapper.
        #expect(resolved as? ConcreteStore != nil,
                "resolution must yield the unwrapped concrete value, not the PassiveService wrapper")
    }

    // MARK: Test 2 — Form 3 projected lifecycle service

    /// A concrete `RecordingManagedService` registered under
    /// `ServiceKey<any Recorder>` via `factory:as:` resolves as the
    /// protocol, while `start()`/`shutdown()` run on the concrete.
    @Test("factory:as: projects a lifecycle service onto a protocol key")
    func testProjectedLifecycleKey() async throws {
        let key = ServiceKey<any Recorder>(id: "recorder")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(
                key,
                subgroup: .integrations,
                factory: { _ in RecordingManagedService() },
                as: { $0 }
            ),
        ])
        try await graph.boot()

        // Resolution yields the protocol type; start() ran on the concrete.
        let resolved: (any Recorder)? = graph.resolve(key)
        #expect(resolved != nil)
        #expect(resolved?.didStart == true,
                "start() must have run on the projected concrete service")
        #expect(resolved?.didShutdown == false)

        let firstGen = resolved!

        // Drive a restart so the first generation drains and its
        // shutdown() runs — observed through the protocol reference.
        await graph.restart(at: key.id)
        try await waitFor(key.id, in: graph) { $0 == .running }

        let deadline = ContinuousClock.now + .seconds(2)
        while firstGen.didShutdown == false {
            if ContinuousClock.now > deadline {
                Issue.record("shutdown() did not run on the projected concrete within timeout")
                break
            }
            try await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }
        #expect(firstGen.didShutdown == true,
                "shutdown() must have run on the projected concrete service")
    }

    // MARK: Test 3 — Form 1 identity regression

    /// An identity key still resolves to its concrete `ManagedService`
    /// type — guards that `project = { $0 }` is behaviourally unchanged.
    @Test("identity keys resolve to the concrete ManagedService unchanged")
    func testIdentityRegression() async throws {
        let key = ServiceKey<RegularService>(id: "regular")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key) { _ in RegularService() },
        ])
        try await graph.boot()

        let resolved: RegularService? = graph.resolve(key)
        #expect(resolved != nil)

        let again = graph.resolve(key)
        #expect(resolved?.instanceID == again?.instanceID,
                "identity resolution must return the same live instance")
    }

    // MARK: Test 4 — `.inner` removal + wrong-type resolution

    /// The former `ServiceKey<PassiveService<Counter>>` + `.inner`
    /// pattern, rewritten to `passive:`, resolves the bare `Counter`
    /// directly. A wrong-type resolve still returns nil / throws
    /// typeMismatch.
    @Test("passive: resolves the bare value; wrong-type resolve fails as before")
    func testPassiveValueAndWrongType() async throws {
        let key = ServiceKey<Counter>(id: "counter")

        let graph = try ServiceGraph(descriptors: [
            EntryDescriptor(key, passive: { _ in Counter(value: 41) }),
        ])
        try await graph.boot()

        // Direct value resolution — no `.inner`.
        let counter: Counter? = graph.resolve(key)
        #expect(counter != nil)
        await counter?.increment()
        #expect(await counter?.read() == 42)

        // Synchronous wrong-type resolve against the same id returns nil.
        let wrongSync = graph.resolve(ServiceKey<RegularService>(id: "counter"))
        #expect(wrongSync == nil)

        // Async wrong-type resolve throws typeMismatch.
        await #expect(throws: ServiceGraphError.self) {
            let _: RegularService = try await graph.requireService(
                ServiceKey<RegularService>(id: "counter"),
                timeout: .milliseconds(200)
            )
        }
    }

    // MARK: Test 5 — overload disambiguation (compile-level)

    /// Constructing one descriptor of each form — including a Form 3
    /// where `Value == Service` — proves the three initialisers (and
    /// their keypath twins) don't collide.
    @Test("the three registration forms disambiguate cleanly")
    func testOverloadDisambiguation() throws {
        // Form 1 — identity, bare trailing closure.
        let f1 = EntryDescriptor(ServiceKey<RegularService>(id: "f1")) { _ in
            RegularService()
        }

        // Form 2 — passive, explicit `passive:` label.
        let f2 = EntryDescriptor(ServiceKey<any DemoStore>(id: "f2"), passive: { _ in
            ConcreteStore(token: "x")
        })

        // Form 3 — projected, `factory:as:` (protocol Value).
        let f3 = EntryDescriptor(
            ServiceKey<any Recorder>(id: "f3"),
            factory: { _ in RecordingManagedService() },
            as: { $0 }
        )

        // Form 3 with Value == Service — must not collide with Form 1.
        let f3eq = EntryDescriptor(
            ServiceKey<RegularService>(id: "f3-eq"),
            factory: { _ in RegularService() },
            as: { $0 }
        )

        // Keypath twins of each form compile too.
        let f2kp = EntryDescriptor(\.demoStoreKP, passive: { _ in ConcreteStore(token: "y") })
        let f3kp = EntryDescriptor(\.recorderKP, factory: { _ in RecordingManagedService() }, as: { $0 })
        let f1kp = EntryDescriptor(\.regularKP) { _ in RegularService() }

        #expect([f1.id, f2.id, f3.id, f3eq.id] == ["f1", "f2", "f3", "f3-eq"])
        #expect([f1kp.id, f2kp.id, f3kp.id] == ["kp.regular", "kp.demo-store", "kp.recorder"])
    }
}

// MARK: - Helpers

private func waitFor(
    _ id: String,
    in graph: ServiceGraph,
    timeout: Duration = .seconds(5),
    predicate: (ServiceState) -> Bool
) async throws {
    let start = ContinuousClock.now
    for await state in graph.stateStream(of: id) {
        if predicate(state) { return }
        if ContinuousClock.now - start > timeout {
            throw ProjectionTestTimeout(last: state)
        }
    }
}

private struct ProjectionTestTimeout: Error { let last: ServiceState }
