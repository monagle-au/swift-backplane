//
//  ServiceMacroIntegrationTests.swift
//  swift-backplane
//
//  End-to-end checks that the #service macro generates usable, typed,
//  keypath-addressable ServiceKeys on the Services namespace. Gated on
//  the Macros trait — runs only under `swift test --traits Macros`.
//
//  This is the behavioural counterpart to the derivation unit tests in
//  BackplaneMacrosTests: it exercises the full macro expansion (name +
//  id derivation, overrides, protocol-typed keys) through real use,
//  under Swift Testing — no XCTest.
//

#if BACKPLANE_MACROS

import Testing
@testable import Backplane

// Sample value types for the macro to key on. Must be at least as
// accessible as the generated `public var` — see the macro's public-var
// caveat.
public struct SampleA: Sendable { let n: Int }
public struct SampleB: Sendable { let n: Int }
public struct SampleC: Sendable { let n: Int }
public protocol SampleStore: Sendable {}

extension Services {
    #service(SampleA.self)                          // -> sampleA,  id "sampleA"
    #service(SampleB.self, id: "custom-b")          // -> sampleB,  id "custom-b"
    #service(SampleC.self, name: "renamed")         // -> renamed,  id "renamed"
    #service((any SampleStore).self, name: "store") // -> store: ServiceKey<any SampleStore>
}

@Suite("#service macro — end to end")
struct ServiceMacroIntegrationTests {

    @Test("derives the property name and id from the type")
    func derivesNameAndID() {
        #expect(Services().sampleA.id == "sampleA")

        // Keypath-addressable and erases to the identity the graph indexes on.
        let erased = AnyServiceKey(keyPath: \.sampleA)
        #expect(erased.id == "sampleA")

        // The keypath's Value type is ServiceKey<SampleA>.
        let key: ServiceKey<SampleA> = Services().sampleA
        #expect(key.id == "sampleA")
    }

    @Test("id: overrides the identifier; property name still derived")
    func overridesID() {
        #expect(Services().sampleB.id == "custom-b")
    }

    @Test("name: overrides the property name and the derived id")
    func overridesName() {
        #expect(Services().renamed.id == "renamed")
    }

    @Test("protocol-typed key resolves to ServiceKey<any P>")
    func protocolTypedKey() {
        let key: ServiceKey<any SampleStore> = Services().store
        #expect(key.id == "store")
    }
}

#endif
