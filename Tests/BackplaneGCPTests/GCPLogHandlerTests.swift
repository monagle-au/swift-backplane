//
//  GCPLogHandlerTests.swift
//  swift-backplane
//

#if BACKPLANE_GCP

import Foundation
import Backplane
import Logging
import ServiceContextModule
import Synchronization
import Testing
@testable import BackplaneGCP

/// Captures log lines into an in-memory buffer for assertions.
private final class CapturedSink: Sendable {
    private let lines = Mutex<[String]>([])

    func sink(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var snapshot: [String] {
        lines.withLock { $0 }
    }
}

@Suite("GCPLogHandler")
struct GCPLogHandlerTests {

    private func makeHandler(
        sink: CapturedSink,
        level: Logger.Level = .trace
    ) -> (GCPLogHandler, Logger) {
        var handler = GCPLogHandler(label: "test", sink: sink.sink)
        handler.logLevel = level
        return (handler, Logger(label: "test", factory: { _ in handler }))
    }

    private func parse(_ line: String) throws -> [String: Any] {
        let trimmed = line.hasSuffix("\n") ? String(line.dropLast()) : line
        let data = Data(trimmed.utf8)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GCPLogTestError.notADictionary
        }
        return json
    }

    // MARK: - Severity mapping

    @Test("level maps to GCP severity strings")
    func severityMapping() {
        #expect(GCPLogHandler.gcpSeverity(for: .trace) == "DEBUG")
        #expect(GCPLogHandler.gcpSeverity(for: .debug) == "DEBUG")
        #expect(GCPLogHandler.gcpSeverity(for: .info) == "INFO")
        #expect(GCPLogHandler.gcpSeverity(for: .notice) == "NOTICE")
        #expect(GCPLogHandler.gcpSeverity(for: .warning) == "WARNING")
        #expect(GCPLogHandler.gcpSeverity(for: .error) == "ERROR")
        #expect(GCPLogHandler.gcpSeverity(for: .critical) == "CRITICAL")
    }

    // MARK: - Output shape

    @Test("emits one JSON line ending with newline")
    func emitsOneJSONLineWithNewline() throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)
        logger.info("Hello")
        #expect(sink.snapshot.count == 1)
        let line = sink.snapshot[0]
        #expect(line.hasSuffix("\n"))
        // No embedded newlines other than the trailer.
        #expect(line.dropLast().contains("\n") == false)
        let json = try parse(line)
        #expect(json["message"] as? String == "Hello")
    }

    @Test("severity, time, logger, message land at top level")
    func topLevelFields() throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)
        logger.warning("Something happened")
        let json = try parse(sink.snapshot[0])
        #expect(json["severity"] as? String == "WARNING")
        #expect(json["logger"] as? String == "test")
        #expect(json["message"] as? String == "Something happened")
        let time = try #require(json["time"] as? String)
        // RFC3339 with millisecond precision and Z suffix.
        // Example: "2026-05-05T07:05:15.123Z"
        #expect(time.hasSuffix("Z"))
        #expect(time.contains("T"))
        #expect(time.contains("."))
    }

    @Test("source location uses Cloud Logging field name")
    func sourceLocationField() throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)
        logger.info("loc")
        let json = try parse(sink.snapshot[0])
        let loc = try #require(json["logging.googleapis.com/sourceLocation"] as? [String: Any])
        let file = try #require(loc["file"] as? String)
        let line = try #require(loc["line"] as? String)
        let function = try #require(loc["function"] as? String)
        #expect(file.contains("GCPLogHandlerTests"))
        #expect(Int(line) != nil)  // line is stringified to keep GCP shape
        #expect(function.contains("sourceLocationField"))
    }

    // MARK: - Metadata flattening

    @Test("explicit metadata becomes top-level keys")
    func explicitMetadataFlattens() throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)
        logger.info("x", metadata: [
            "account_id": "abc-123",
            "instance_count": "5",
        ])
        let json = try parse(sink.snapshot[0])
        #expect(json["account_id"] as? String == "abc-123")
        #expect(json["instance_count"] as? String == "5")
    }

    @Test("handler-attached metadata merges with explicit; explicit wins on collision")
    func metadataPrecedence() throws {
        let sink = CapturedSink()
        var handler = GCPLogHandler(label: "test", sink: sink.sink)
        handler.logLevel = .trace
        handler[metadataKey: "env"] = "prod"
        handler[metadataKey: "shared"] = "from-handler"
        let logger = Logger(label: "test", factory: { _ in handler })
        logger.info("x", metadata: ["shared": "from-call"])
        let json = try parse(sink.snapshot[0])
        #expect(json["env"] as? String == "prod")
        #expect(json["shared"] as? String == "from-call")
    }

    @Test("metadata provider contributes keys")
    func metadataProvider() throws {
        let sink = CapturedSink()
        let provider = Logger.MetadataProvider {
            ["from_provider": "yes"]
        }
        var handler = GCPLogHandler(label: "test", metadataProvider: provider, sink: sink.sink)
        handler.logLevel = .trace
        let logger = Logger(label: "test", factory: { _ in handler })
        logger.info("x")
        let json = try parse(sink.snapshot[0])
        #expect(json["from_provider"] as? String == "yes")
    }

    @Test("metadata cannot clobber reserved structural keys")
    func reservedKeysProtected() throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)
        logger.error("real message", metadata: [
            "severity": "INFO",       // attempted clobber
            "message": "fake",         // attempted clobber
            "logger": "spoofed",       // attempted clobber
            "okay_key": "kept",
        ])
        let json = try parse(sink.snapshot[0])
        #expect(json["severity"] as? String == "ERROR")
        #expect(json["message"] as? String == "real message")
        #expect(json["logger"] as? String == "test")
        #expect(json["okay_key"] as? String == "kept")
    }

    // MARK: - Level filtering

    @Test("messages below logLevel are dropped")
    func levelFiltering() {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink, level: .warning)
        logger.debug("nope")
        logger.info("nope")
        logger.warning("yep")
        logger.error("yep")
        #expect(sink.snapshot.count == 2)
    }

    // MARK: - Trace correlation

    @Test("emits Cloud Logging trace fields when ServiceContext carries trace + project ID set")
    func tracingFieldsEmitted() async throws {
        let sink = CapturedSink()
        var handler = GCPLogHandler(
            label: "test",
            gcpProjectID: "my-proj",
            sink: sink.sink
        )
        handler.logLevel = .trace
        let logger = Logger(label: "test", factory: { _ in handler })

        var ctx = ServiceContext.topLevel
        ctx.loggingTraceContext = LoggingTraceContext(
            traceID: "0af7651916cd43dd8448eb211c80319c",
            spanID: "b7ad6b7169203331",
            sampled: true
        )
        await ServiceContext.withValue(ctx) {
            logger.info("traced")
        }

        let json = try parse(sink.snapshot[0])
        #expect(json["logging.googleapis.com/trace"] as? String == "projects/my-proj/traces/0af7651916cd43dd8448eb211c80319c")
        #expect(json["logging.googleapis.com/spanId"] as? String == "b7ad6b7169203331")
        #expect(json["logging.googleapis.com/trace_sampled"] as? String == "true")
    }

    @Test("no trace fields when ServiceContext has no LoggingTraceContext")
    func tracingFieldsAbsent() throws {
        let sink = CapturedSink()
        let handler = GCPLogHandler(label: "test", gcpProjectID: "my-proj", sink: sink.sink)
        let logger = Logger(label: "test", factory: { _ in handler })
        logger.info("untraced")

        let json = try parse(sink.snapshot[0])
        #expect(json["logging.googleapis.com/trace"] == nil)
        #expect(json["logging.googleapis.com/spanId"] == nil)
        #expect(json["logging.googleapis.com/trace_sampled"] == nil)
    }

    @Test("no trace fields when project ID is unset")
    func tracingFieldsRequireProjectID() async throws {
        let sink = CapturedSink()
        let handler = GCPLogHandler(label: "test", gcpProjectID: nil, sink: sink.sink)
        let logger = Logger(label: "test", factory: { _ in handler })

        var ctx = ServiceContext.topLevel
        ctx.loggingTraceContext = LoggingTraceContext(
            traceID: "0af7651916cd43dd8448eb211c80319c",
            spanID: "b7ad6b7169203331"
        )
        await ServiceContext.withValue(ctx) {
            logger.info("traced-but-no-project")
        }

        let json = try parse(sink.snapshot[0])
        #expect(json["logging.googleapis.com/trace"] == nil)
    }

    @Test("empty project ID treated as nil")
    func emptyProjectIDDisablesTraceFields() async throws {
        let sink = CapturedSink()
        let handler = GCPLogHandler(label: "test", gcpProjectID: "", sink: sink.sink)
        #expect(handler.gcpProjectID == nil)
        let logger = Logger(label: "test", factory: { _ in handler })

        var ctx = ServiceContext.topLevel
        ctx.loggingTraceContext = LoggingTraceContext(traceID: "a", spanID: "b")
        await ServiceContext.withValue(ctx) {
            logger.info("x")
        }

        let json = try parse(sink.snapshot[0])
        #expect(json["logging.googleapis.com/trace"] == nil)
    }

    @Test("trace_sampled emits 'false' when sampled is false")
    func sampledFalseEncoded() async throws {
        let sink = CapturedSink()
        let handler = GCPLogHandler(label: "test", gcpProjectID: "p", sink: sink.sink)
        let logger = Logger(label: "test", factory: { _ in handler })

        var ctx = ServiceContext.topLevel
        ctx.loggingTraceContext = LoggingTraceContext(
            traceID: "a", spanID: "b", sampled: false
        )
        await ServiceContext.withValue(ctx) {
            logger.info("x")
        }

        let json = try parse(sink.snapshot[0])
        #expect(json["logging.googleapis.com/trace_sampled"] as? String == "false")
    }

    @Test("explicit metadata wins over auto-emitted trace fields")
    func explicitTraceMetadataWins() async throws {
        let sink = CapturedSink()
        let handler = GCPLogHandler(label: "test", gcpProjectID: "p", sink: sink.sink)
        let logger = Logger(label: "test", factory: { _ in handler })

        var ctx = ServiceContext.topLevel
        ctx.loggingTraceContext = LoggingTraceContext(traceID: "auto", spanID: "auto-span")
        await ServiceContext.withValue(ctx) {
            logger.info("x", metadata: [
                "logging.googleapis.com/spanId": "manual-override",
            ])
        }

        let json = try parse(sink.snapshot[0])
        #expect(json["logging.googleapis.com/spanId"] as? String == "manual-override")
        // Trace key still auto-filled because no explicit override:
        #expect(json["logging.googleapis.com/trace"] as? String == "projects/p/traces/auto")
    }

    // MARK: - Concurrent writes

    @Test("concurrent log calls produce well-formed lines")
    func concurrentWrites() async throws {
        let sink = CapturedSink()
        let (_, logger) = makeHandler(sink: sink)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    logger.info("concurrent-\(i)")
                }
            }
        }
        #expect(sink.snapshot.count == 200)
        // Every line must parse — proves the sink ordering didn't tear lines.
        for line in sink.snapshot {
            _ = try parse(line)
        }
    }
}

private enum GCPLogTestError: Error { case notADictionary }

#endif
