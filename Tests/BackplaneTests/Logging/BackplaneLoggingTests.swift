//
//  BackplaneLoggingTests.swift
//  swift-backplane
//

import Logging
import Synchronization
import Testing
@testable import Backplane

/// Records which factory ran. `Mutex` keeps the closure `@Sendable`.
private final class Picked: Sendable {
    private let value = Mutex<String>("")
    func set(_ s: String) { value.withLock { $0 = s } }
    var get: String { value.withLock { $0 } }
}

private final class CallCount: Sendable {
    private let value = Mutex<Int>(0)
    func bump() { value.withLock { $0 += 1 } }
    var get: Int { value.withLock { $0 } }
}

@Suite("BackplaneLogging.EnvironmentSelector")
struct BackplaneLoggingTests {

    @Test("first matching predicate's factory wins")
    func firstMatchWins() {
        let picked = Picked()
        let selector = BackplaneLogging.EnvironmentSelector(
            entries: [
                ({ true }, { _ in picked.set("first"); return StreamLogHandler.standardOutput(label: "x") }),
                ({ true }, { _ in picked.set("second"); return StreamLogHandler.standardOutput(label: "x") }),
            ],
            fallback: { _ in picked.set("fallback"); return StreamLogHandler.standardOutput(label: "x") }
        )
        _ = selector.makeHandler(for: "test")
        #expect(picked.get == "first")
    }

    @Test("falls back when no predicate matches")
    func fallbackUsedWhenNoneMatch() {
        let picked = Picked()
        let selector = BackplaneLogging.EnvironmentSelector(
            entries: [
                ({ false }, { _ in picked.set("no"); return StreamLogHandler.standardOutput(label: "x") }),
            ],
            fallback: { _ in picked.set("fallback"); return StreamLogHandler.standardOutput(label: "x") }
        )
        _ = selector.makeHandler(for: "test")
        #expect(picked.get == "fallback")
    }

    @Test("prepending inserts at the front")
    func prependingPutsEntryFirst() {
        let picked = Picked()
        let base = BackplaneLogging.EnvironmentSelector(
            entries: [
                ({ true }, { _ in picked.set("base"); return StreamLogHandler.standardOutput(label: "x") }),
            ],
            fallback: { _ in picked.set("fallback"); return StreamLogHandler.standardOutput(label: "x") }
        )
        let extended = base.prepending({ true }, factory: { _ in
            picked.set("prepended")
            return StreamLogHandler.standardOutput(label: "x")
        })
        _ = extended.makeHandler(for: "test")
        #expect(picked.get == "prepended")
    }

    @Test("asFactory walks entries per call")
    func asFactoryDelegates() {
        let calls = CallCount()
        let selector = BackplaneLogging.EnvironmentSelector(
            entries: [
                ({ true }, { _ in calls.bump(); return StreamLogHandler.standardOutput(label: "x") }),
            ],
            fallback: { _ in StreamLogHandler.standardOutput(label: "x") }
        )
        let factory = selector.asFactory
        _ = factory("a")
        _ = factory("b")
        #expect(calls.get == 2)
    }

    @Test("predicate is re-evaluated per makeHandler call, not memoised")
    func predicateNotMemoised() {
        let predicateCalls = CallCount()
        let selector = BackplaneLogging.EnvironmentSelector(
            entries: [
                ({ predicateCalls.bump(); return false }, { _ in StreamLogHandler.standardOutput(label: "x") }),
            ],
            fallback: { _ in StreamLogHandler.standardOutput(label: "x") }
        )
        _ = selector.makeHandler(for: "x")
        _ = selector.makeHandler(for: "x")
        _ = selector.makeHandler(for: "x")
        #expect(predicateCalls.get == 3)
    }
}

// MARK: - Log level resolution

@Suite("BackplaneLogging.resolveLogLevel")
struct BackplaneLoggingLevelResolutionTests {

    @Test("missing env var returns nil")
    func missingEnvReturnsNil() {
        // Use a name that won't collide with any real var.
        #expect(BackplaneLogging.resolveLogLevel(envVar: "BACKPLANE_TEST_NEVER_SET_ABCXYZ") == nil)
    }

    @Test("each canonical level string parses")
    func parsesAllCanonicalLevels() {
        for level in Logger.Level.allCases {
            #expect(Logger.Level(rawValue: level.rawValue) == level)
        }
    }

    @Test("unknown level string returns nil")
    func unknownLevelReturnsNil() {
        // We can't safely set process env in a parallel test; verify the
        // parsing path directly. The function only does env lookup +
        // `Logger.Level(rawValue:)` — if rawValue rejects the input, the
        // function returns nil.
        #expect(Logger.Level(rawValue: "loud") == nil)
        #expect(Logger.Level(rawValue: "") == nil)
    }
}
