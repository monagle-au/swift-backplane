//
//  StructuredLogHandlerTests.swift
//  swift-backplane
//

import Foundation
import Logging
import ServiceContextModule
import Synchronization
import Testing
@testable import Backplane

private final class CapturedSink: Sendable {
    private let lines = Mutex<[String]>([])
    func sink(_ line: String) { lines.withLock { $0.append(line) } }
    var snapshot: [String] { lines.withLock { $0 } }
}

private func parse(_ line: String) throws -> [String: Any] {
    let trimmed = line.hasSuffix("\n") ? String(line.dropLast()) : line
    let data = Data(trimmed.utf8)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw StructuredLogTestError.notADictionary
    }
    return json
}

private enum StructuredLogTestError: Error { case notADictionary }

@Suite("StructuredLogHandler.plain")
struct StructuredLogHandlerPlainTests {

    private func makeHandler(sink: CapturedSink) -> (StructuredLogHandler, Logger) {
        var handler = StructuredLogHandler(label: "test", profile: .plain, sink: sink.sink)
        handler.logLevel = .trace
        return (handler, Logger(label: "test", factory: { _ in handler }))
    }

    @Test("plain profile emits generic top-level keys")
    func topLevelKeys() throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)
        logger.info("Hello")
        let json = try parse(sink.snapshot[0])
        #expect(json["severity"] as? String == "INFO")
        #expect(json["logger"] as? String == "test")
        #expect(json["message"] as? String == "Hello")
        let time = try #require(json["time"] as? String)
        #expect(time.hasSuffix("Z"))
    }

    @Test("plain profile uses 'source' (not the GCP key) for source location")
    func sourceLocationKey() throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)
        logger.info("loc")
        let json = try parse(sink.snapshot[0])
        // Plain profile uses generic "source" key.
        let loc = try #require(json["source"] as? [String: Any])
        #expect(loc["file"] != nil)
        #expect(loc["line"] != nil)
        #expect(loc["function"] != nil)
        // GCP-specific key must NOT be emitted.
        #expect(json["logging.googleapis.com/sourceLocation"] == nil)
    }

    @Test("plain profile severity uppercases swift-log levels")
    func severityUppercases() throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)
        logger.warning("w")
        logger.error("e")
        let warning = try parse(sink.snapshot[0])
        let error = try parse(sink.snapshot[1])
        #expect(warning["severity"] as? String == "WARNING")
        #expect(error["severity"] as? String == "ERROR")
    }

    @Test("plain profile emits no trace correlation fields even with LoggingTraceContext set")
    func noTraceCorrelation() async throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)

        var ctx = ServiceContext.topLevel
        ctx.loggingTraceContext = LoggingTraceContext(traceID: "a", spanID: "b")
        await ServiceContext.withValue(ctx) {
            logger.info("traced")
        }

        let json = try parse(sink.snapshot[0])
        #expect(json["logging.googleapis.com/trace"] == nil)
        #expect(json["trace_id"] == nil)
    }

    @Test("metadata flattens to top-level keys")
    func metadataFlattening() throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)
        logger.info("x", metadata: ["request_id": "abc-123"])
        let json = try parse(sink.snapshot[0])
        #expect(json["request_id"] as? String == "abc-123")
    }

    @Test("metadata cannot clobber reserved structural keys")
    func reservedKeysProtected() throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)
        logger.error("real", metadata: [
            "severity": "INFO",   // attempted clobber
            "message": "fake",
            "okay": "kept",
        ])
        let json = try parse(sink.snapshot[0])
        #expect(json["severity"] as? String == "ERROR")
        #expect(json["message"] as? String == "real")
        #expect(json["okay"] as? String == "kept")
    }
}
