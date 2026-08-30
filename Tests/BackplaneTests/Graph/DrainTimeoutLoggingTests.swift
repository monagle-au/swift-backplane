//
//  DrainTimeoutLoggingTests.swift
//  swift-backplane
//
//  The drain path bounds shutdown() with a timeout task. That task must
//  distinguish "the budget elapsed" from "I was cancelled because shutdown()
//  finished in time" — otherwise every *successful* drain logs a timeout that
//  did not happen, and the warning stops meaning anything.
//

import Foundation
import Logging
import Synchronization
import Testing
@testable import Backplane

// MARK: - Capturing log handler

/// Collects every message at or above `.warning` so a test can assert on
/// what the graph said, not merely on what it did.
/// `Mutex` is non-copyable, so the handler — which log(3) copies freely —
/// holds a reference to one rather than the value itself.
private final class MessageLog: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ message: String) { storage.withLock { $0.append(message) } }
    var all: [String] { storage.withLock { $0 } }
}

private struct CapturingLogHandler: LogHandler {
    let captured: MessageLog

    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= .warning else { return }
        captured.append("\(message)")
    }
}

private func capturingLogger() -> (logger: Logger, messages: MessageLog) {
    let messages = MessageLog()
    let logger = Logger(label: "drain-test") { _ in
        CapturingLogHandler(captured: messages)
    }
    return (logger, messages)
}

private let timeoutWarning = "Shutdown timed out"

// MARK: - Suite

@Suite("ServiceGraph — drain timeout logging")
struct DrainTimeoutLoggingTests {

    /// The regression. A generation whose `shutdown()` returns promptly is
    /// well inside its budget, so draining it must say nothing.
    @Test("A shutdown that completes in time logs no timeout warning")
    func promptShutdownIsSilent() async throws {
        let key = ServiceKey<TrackableService>(id: "svc")
        let (logger, messages) = capturingLogger()

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(
                    key,
                    subgroup: .integrations,
                    replacement: .blueGreen(grace: .milliseconds(50))
                ) { _ in TrackableService() }
            ],
            logger: logger,
            shutdownTimeout: .seconds(30)
        )

        try await graph.boot()
        await graph.restart(at: key.id)
        try await Task.sleep(for: .milliseconds(400), clock: .continuous)

        let warnings = messages.all
        #expect(
            !warnings.contains { $0.contains(timeoutWarning) },
            "a drain that completed well inside its budget logged: \(warnings)"
        )
    }

    /// The other direction, so the fix cannot be "never warn". A wedged
    /// `shutdown()` must still be reported — that warning is the only signal
    /// a leaked generation gives.
    @Test("A shutdown that overruns its budget still warns")
    func wedgedShutdownStillWarns() async throws {
        let key = ServiceKey<StuckShutdownService>(id: "svc")
        let (logger, messages) = capturingLogger()

        let graph = try ServiceGraph(
            descriptors: [
                EntryDescriptor(
                    key,
                    subgroup: .integrations,
                    replacement: .blueGreen(grace: .milliseconds(50))
                ) { _ in StuckShutdownService() }
            ],
            logger: logger,
            shutdownTimeout: .milliseconds(100)
        )

        try await graph.boot()
        await graph.restart(at: key.id)
        try await Task.sleep(for: .milliseconds(600), clock: .continuous)

        let warnings = messages.all
        #expect(
            warnings.contains { $0.contains(timeoutWarning) },
            "a shutdown() wedged past its budget must warn; captured: \(warnings)"
        )
    }
}
