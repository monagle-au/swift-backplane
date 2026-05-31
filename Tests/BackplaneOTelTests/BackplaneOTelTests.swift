//
//  BackplaneOTelTests.swift
//  swift-backplane
//

import BackplaneOTel
import Testing

@Suite("BackplaneOTel namespace")
struct BackplaneOTelNamespaceTests {
    @Test("namespace is reachable")
    func namespaceReachable() {
        // Compile-time assertion: the type exists and is referenceable.
        _ = BackplaneOTel.self
    }
}
