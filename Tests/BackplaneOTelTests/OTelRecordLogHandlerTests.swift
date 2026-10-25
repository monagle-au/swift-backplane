//
//  OTelRecordLogHandlerTests.swift
//  swift-backplane
//

#if BACKPLANE_OTEL

import Logging
@testable import BackplaneOTel
import Testing

@Suite("OTelRecordLogHandler")
struct OTelRecordLogHandlerTests {

    @Test("An OTLP record carries its logger's label")
    func stampsLabel() {
        let sink = LogSink()
        let logger = Logger(label: "acumen.agent.matter-agent") { label in
            OTelRecordLogHandler(label: label, wrapping: RecordingHandler(sink))
        }
        logger.info("subscribed")
        #expect(sink.logs.count == 1)
        #expect(sink.logs.first?.metadata[BackplaneOTel.loggerLabelKey] == "acumen.agent.matter-agent")
        #expect(BackplaneOTel.loggerLabelKey == "logger")
    }

    @Test("An explicit logger key in the message wins")
    func explicitKeyWins() {
        let sink = LogSink()
        let logger = Logger(label: "acumen.engine") { label in
            OTelRecordLogHandler(label: label, wrapping: RecordingHandler(sink))
        }
        logger.info("x", metadata: ["logger": "other"])
        #expect(sink.logs.first?.metadata["logger"] == "other")
    }

    @Test("A handler-level logger key is kept on the OTLP leg")
    func handlerLevelKeyWins() {
        let sink = LogSink()
        var inner = RecordingHandler(sink)
        inner[metadataKey: "logger"] = "pinned"
        let logger = Logger(label: "acumen.engine") { label in
            OTelRecordLogHandler(label: label, wrapping: inner)
        }
        logger.info("x")
        #expect(sink.logs.first?.metadata["logger"] == "pinned")
    }

    @Test("A metadata provider is not handed to the OTLP handler")
    func ignoresMetadataProvider() {
        let sink = LogSink()
        var handler = OTelRecordLogHandler(label: "acumen.engine", wrapping: RecordingHandler(sink))
        handler.metadataProvider = Logger.MetadataProvider { ["trace_id": "abc"] }
        #expect(sink.providerAssignmentCount == 0)
        #expect(handler.metadataProvider == nil)
    }

    @Test("Level and metadata pass through to the wrapped handler")
    func forwardsState() {
        let sink = LogSink()
        var handler = OTelRecordLogHandler(label: "acumen.engine", wrapping: RecordingHandler(sink))
        handler.logLevel = .debug
        handler[metadataKey: "agent"] = "matter-agent"
        #expect(handler.wrapped.logLevel == .debug)
        #expect(handler.wrapped[metadataKey: "agent"] == "matter-agent")
        #expect(handler.metadata["agent"] == "matter-agent")
    }
}

#endif
