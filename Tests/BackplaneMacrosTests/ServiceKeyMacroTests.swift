//
//  ServiceKeyMacroTests.swift
//  swift-backplane
//
//  Unit tests for the #service macro's name-derivation logic. Gated on
//  the Macros trait so the bare test run never builds swift-syntax.
//
//  These exercise the pure derivation function directly under Swift
//  Testing — no XCTest, no SwiftSyntaxMacrosTestSupport. Full expansion
//  is covered behaviourally in BackplaneTests/ServiceMacroIntegrationTests.
//

#if BACKPLANE_MACROS

import Testing

@testable import BackplaneMacros

@Suite("#service — name derivation")
struct ServiceKeyMacroTests {

    @Test("lower-cases the first letter of a simple identifier")
    func simpleIdentifier() {
        #expect(ServiceKeyMacro.derivedName(from: "Foo") == "foo")
        #expect(ServiceKeyMacro.derivedName(from: "PostgresClient") == "postgresClient")
        #expect(ServiceKeyMacro.derivedName(from: "X") == "x")
    }

    @Test("strips a leading any/some constraint")
    func existentialPrefix() {
        #expect(ServiceKeyMacro.derivedName(from: "any AuditStore") == "auditStore")
        #expect(ServiceKeyMacro.derivedName(from: "some Widget") == "widget")
    }

    @Test("takes the trailing component of a dotted type")
    func dottedType() {
        #expect(ServiceKeyMacro.derivedName(from: "Module.Nested") == "nested")
        #expect(ServiceKeyMacro.derivedName(from: "A.B.Baz") == "baz")
        #expect(ServiceKeyMacro.derivedName(from: "any Foo.Bar") == "bar")
    }

    @Test("returns nil for types it can't reduce to a bare identifier")
    func underivable() {
        #expect(ServiceKeyMacro.derivedName(from: "Box<Int>") == nil)
        #expect(ServiceKeyMacro.derivedName(from: "PassiveService<PowerTopology>") == nil)
        #expect(ServiceKeyMacro.derivedName(from: "(Int, Int)") == nil)
        #expect(ServiceKeyMacro.derivedName(from: "[String]") == nil)
    }
}

#endif
