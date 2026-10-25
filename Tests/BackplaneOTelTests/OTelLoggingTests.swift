//
//  OTelLoggingTests.swift
//  swift-backplane
//

#if BACKPLANE_OTEL

import Backplane
import Logging
@testable import BackplaneOTel
import Testing

@Suite("Console and OTLP behind one level table")
struct OTelLoggingTests {

    private let label = "acumen.agent.matter-agent"

    private func composed(otel: LogSink, console: LogSink?) -> LogHandlerFactory {
        BackplaneOTel.logHandlerFactory(
            otel: { _ in RecordingHandler(otel) },
            localLogs: console.map { sink -> LogHandlerFactory in { _ in RecordingHandler(sink) } }
        )
    }

    @Test("Both legs get what the table permits, and neither gets what it filters")
    func tableFiltersBothLegs() {
        let otel = LogSink(), console = LogSink()
        let table = LogLevelTable(baseLevel: .info, rules: [LogLevelRule(labelPrefix: label, level: .trace)])
        let logger = Logger(label: label, factory: LevelTableLogHandler.factory(wrapping: composed(otel: otel, console: console), table: table))

        logger.trace("a")
        table.set(LogLevelRule(labelPrefix: label, level: .info))
        logger.trace("b")
        logger.info("c")

        #expect(otel.messages == ["a", "c"])
        #expect(console.messages == ["a", "c"])
        #expect(otel.logs.allSatisfy { $0.metadata["logger"] == label })
        #expect(console.logs.allSatisfy { $0.metadata["logger"] == nil })
    }

    @Test("The table is outermost and wraps a multiplex of console and OTLP")
    func structureWithLocalLogs() throws {
        let table = LogLevelTable()
        let handler = LevelTableLogHandler.factory(wrapping: composed(otel: LogSink(), console: LogSink()), table: table)(label)
        let tableHandler = try #require(handler as? LevelTableLogHandler)
        #expect(tableHandler.wrapped is MultiplexLogHandler)
        #expect(table.isConsulted)
    }

    @Test("Without local logs the table wraps the OTLP handler alone")
    func structureWithoutLocalLogs() throws {
        let handler = LevelTableLogHandler.factory(wrapping: composed(otel: LogSink(), console: nil), table: LogLevelTable())(label)
        let tableHandler = try #require(handler as? LevelTableLogHandler)
        #expect(tableHandler.wrapped is OTelRecordLogHandler)
    }

    @Test("A metadata provider reaches the console leg only")
    func providerReachesConsoleOnly() {
        let otel = LogSink(), console = LogSink()
        var handler = LevelTableLogHandler.factory(wrapping: composed(otel: otel, console: console), table: LogLevelTable())(label)
        handler.metadataProvider = Logger.MetadataProvider { ["trace_id": "abc"] }
        #expect(console.providerAssignmentCount == 1)
        #expect(otel.providerAssignmentCount == 0)
    }
}

#endif
