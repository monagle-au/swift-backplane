//
//  LevelTableLogHandlerTests.swift
//  swift-backplane
//

import Foundation
import Logging
import Testing
@testable import Backplane

private func makeLogger(_ label: String, table: LogLevelTable, sink: Sink) -> Logger {
    Logger(label: label) { label in
        LevelTableLogHandler(label: label, wrapping: SinkLogHandler(sink: sink), table: table)
    }
}

@Suite("LevelTableLogHandler")
struct LevelTableLogHandlerTests {

    @Test("the wrapped handler sees exactly the permitted messages")
    func exactlyPermittedMessages() {
        let sink = Sink()
        let table = LogLevelTable(baseLevel: .info, rules: [
            rule("matter:mrp=trace"),
            rule("matter:session=warning"),
            rule("acumen=debug"),
        ])
        let matter = makeLogger("matter.controller", table: table, sink: sink)
        let acumen = makeLogger("acumen.engine", table: table, sink: sink)
        let other = makeLogger("other", table: table, sink: sink)

        #expect(matter.logLevel == .trace)
        #expect(acumen.logLevel == .debug)
        #expect(other.logLevel == .info)

        matter.trace("mrp-frame", metadata: ["matter.subsystem": "mrp"])        // rule mrp=trace
        matter.trace("exchange-frame", metadata: ["matter.subsystem": "exchange"]) // fast path admits, base info rejects
        matter.debug("plain-debug")                                              // base info rejects
        matter.info("plain-info")                                                // base info
        matter.info("session-info", metadata: ["subsystem": "session"])          // session=warning rejects
        matter.warning("session-down", metadata: ["subsystem": "session"])       // session=warning
        acumen.debug("engine-debug")                                             // acumen=debug
        acumen.trace("engine-trace")                                             // rejected by getter
        other.debug("other-debug")                                               // rejected by getter
        other.notice("other-notice")

        #expect(sink.all == [
            "trace mrp-frame",
            "info plain-info",
            "warning session-down",
            "debug engine-debug",
            "notice other-notice",
        ])
    }

    @Test("subsystem set as logger metadata is honoured; message metadata wins over it")
    func loggerMetadataSubsystem() {
        let sink = Sink()
        let table = LogLevelTable(baseLevel: .info, rules: [rule("matter:mrp=trace")])
        var mrp = makeLogger("matter.controller", table: table, sink: sink)
        mrp[metadataKey: "matter.subsystem"] = "mrp"
        var exchange = makeLogger("matter.controller", table: table, sink: sink)
        exchange[metadataKey: "matter.subsystem"] = "exchange"

        mrp.trace("from-mrp")
        exchange.trace("from-exchange")
        exchange.trace("overridden", metadata: ["matter.subsystem": "mrp"])

        #expect(sink.all == ["trace from-mrp", "trace overridden"])
        #expect(exchange[metadataKey: "matter.subsystem"] == "exchange")
    }

    @Test("logLevel set on an instance is a floor: quieter than the table, never louder")
    func instanceFloor() {
        let sink = Sink()
        let table = LogLevelTable(baseLevel: .info, rules: [rule("acumen=debug")])
        var quiet = makeLogger("acumen.engine", table: table, sink: sink)
        quiet.logLevel = .warning
        var loud = makeLogger("other", table: table, sink: sink)
        loud.logLevel = .trace
        let untouched = makeLogger("acumen.engine", table: table, sink: sink)

        #expect(quiet.logLevel == .warning)
        #expect(loud.logLevel == .info)
        #expect(untouched.logLevel == .debug)

        quiet.info("quiet-info")
        quiet.warning("quiet-warning")
        loud.trace("loud-trace")
        loud.info("loud-info")
        untouched.debug("untouched-debug")

        #expect(sink.all == ["warning quiet-warning", "info loud-info", "debug untouched-debug"])
    }

    @Test("an instance floor also applies after the subsystem check")
    func floorWithSubsystem() {
        let sink = Sink()
        let table = LogLevelTable(baseLevel: .info, rules: [rule("matter:mrp=trace")])
        var handler = LevelTableLogHandler(label: "matter.controller", wrapping: SinkLogHandler(sink: sink), table: table)
        handler.logLevel = .debug
        // Drive log(event:) directly: Logger would filter on the getter first.
        for (level, message) in [(Logger.Level.trace, "trace-mrp"), (.debug, "debug-mrp")] {
            handler.log(event: LogEvent(
                level: level, message: "\(message)", metadata: ["subsystem": "mrp"],
                source: "test", file: #fileID, function: #function, line: #line
            ))
        }
        #expect(sink.all == ["debug debug-mrp"])
    }

    @Test("an existing logger follows set / remove / reset without being rebuilt")
    func runtimeChange() {
        let sink = Sink()
        let table = LogLevelTable(baseLevel: .info)
        let logger = makeLogger("matter.controller", table: table, sink: sink)

        logger.debug("one")
        table.set(rule("matter=debug"))
        #expect(logger.logLevel == .debug)
        logger.debug("two")
        table.remove(labelPrefix: "matter")
        #expect(logger.logLevel == .info)
        logger.debug("three")
        table.set(rule("matter:*=trace"))
        logger.trace("four")
        table.reset()
        logger.trace("five")

        #expect(sink.all == ["debug two", "trace four"])
    }

    @Test("after expiresAt the inner handler receives nothing the rule admitted")
    func expiryThroughHandler() {
        let sink = Sink()
        let clock = TestClock()
        let table = LogLevelTable(baseLevel: .info, now: { clock.now })
        table.set(LogLevelRule(labelPrefix: "matter", level: .trace, expiresAt: clock.now.addingTimeInterval(60)))
        let logger = makeLogger("matter.controller", table: table, sink: sink)

        logger.trace("before")
        clock.advance(61)
        // Before any log call: only the getter's own prune can have dropped the rule.
        #expect(logger.logLevel == .info)
        logger.trace("after")
        logger.debug("after-debug")
        logger.info("after-info")

        #expect(sink.all == ["trace before", "info after-info"])
        #expect(table.rules().isEmpty)
    }

    @Test("log(event:) prunes an expired rule itself, without the getter being read first")
    func expiryThroughLogEvent() {
        let sink = Sink()
        let clock = TestClock()
        let table = LogLevelTable(baseLevel: .info, now: { clock.now })
        table.set(LogLevelRule(labelPrefix: "matter", level: .trace, expiresAt: clock.now.addingTimeInterval(60)))
        let handler = LevelTableLogHandler(label: "matter.controller", wrapping: SinkLogHandler(sink: sink), table: table)
        // Prime the cache while the rule is live, then expire it.
        #expect(handler.logLevel == .trace)
        clock.advance(61)
        for (level, message) in [(Logger.Level.trace, "after-trace"), (.info, "after-info")] {
            handler.log(event: LogEvent(
                level: level, message: "\(message)", metadata: nil,
                source: "test", file: #fileID, function: #function, line: #line
            ))
        }
        #expect(sink.all == ["info after-info"])
    }

    @Test("the inner handler is opened to trace, so a Multiplex child does not re-filter")
    func multiplexInner() {
        let sink = Sink()
        let table = LogLevelTable(baseLevel: .info, rules: [rule("acumen=debug")])
        let logger = Logger(label: "acumen.engine") { label in
            LevelTableLogHandler(
                label: label,
                wrapping: MultiplexLogHandler([SinkLogHandler(sink: sink, logLevel: .info)]),
                table: table
            )
        }
        logger.debug("through-multiplex")
        #expect(sink.all == ["debug through-multiplex"])
    }

    @Test("an inner handler implementing the flat log method receives the event")
    func structuredInner() {
        let lines = Sink()
        let table = LogLevelTable(baseLevel: .info)
        let logger = Logger(label: "acumen") { label in
            LevelTableLogHandler(
                label: label,
                wrapping: StructuredLogHandler(label: label, sink: { lines.append($0) }),
                table: table
            )
        }
        logger.info("hello")
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.contains(#""message":"hello""#) == true)
    }

    @Test("metadata and metadataProvider forward to the inner handler")
    func metadataForwarding() {
        let table = LogLevelTable()
        var handler = LevelTableLogHandler(label: "x", wrapping: SinkLogHandler(sink: Sink()), table: table)
        handler[metadataKey: "a"] = "1"
        handler.metadata["b"] = "2"
        handler.metadataProvider = Logger.MetadataProvider { ["c": "3"] }
        #expect(handler.wrapped.metadata == ["a": "1", "b": "2"])
        #expect(handler.wrapped.metadataProvider?.get() == ["c": "3"])
        #expect(handler.wrapped.logLevel == .trace)
    }

    @Test("the logLevel getter recomputes only when the table generation changes")
    func getterIsCached() {
        let table = LogLevelTable(baseLevel: .info)
        let logger = makeLogger("acumen.engine", table: table, sink: Sink())
        let before = table.entryComputationCount
        for _ in 0..<1_000 { _ = logger.logLevel }
        #expect(table.entryComputationCount - before == 1)
        table.set(rule("acumen=debug"))
        for _ in 0..<1_000 { _ = logger.logLevel }
        #expect(table.entryComputationCount - before == 2)
        #expect(logger.logLevel == .debug)
    }

    @Test("factory(wrapping:) wraps every handler it builds")
    func factoryWraps() throws {
        let table = LogLevelTable(baseLevel: .notice)
        let factory = LevelTableLogHandler.factory(wrapping: { _ in SwiftLogNoOpLogHandler() }, table: table)
        let handler = try #require(factory("anything") as? LevelTableLogHandler)
        #expect(handler.label == "anything")
        #expect(handler.table === table)
        #expect(handler.logLevel == .notice)
    }

    @Test("BackplaneLogging.levelTable is a single process-wide table")
    func sharedTable() {
        let first = BackplaneLogging.levelTable
        let second = BackplaneLogging.levelTable
        #expect(first === second)
        let handler = LevelTableLogHandler(label: "x", wrapping: SwiftLogNoOpLogHandler())
        #expect(handler.table === BackplaneLogging.levelTable)
    }

    @Test("isConsulted is false on a fresh table and true once a handler is built over it")
    func isConsulted() {
        let table = LogLevelTable()
        #expect(table.isConsulted == false)
        _ = LevelTableLogHandler(label: "x", wrapping: SwiftLogNoOpLogHandler(), table: table)
        #expect(table.isConsulted)
    }

    @Test("logging while rules change concurrently admits only permitted levels")
    func concurrentLogAndSet() async {
        let sink = Sink()
        let table = LogLevelTable(baseLevel: .info)
        // Live before any logger starts, so debug lines reach the sink and
        // the allSatisfy check below is not passed by an empty sink.
        table.set(rule("matter=debug"))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<200 {
                    if i % 20 == 0 { await Task.yield() }
                    if i % 2 == 0 { table.set(rule("matter=debug")) } else { table.remove(labelPrefix: "matter") }
                }
                table.set(rule("matter=debug"))
            }
            for _ in 0..<4 {
                group.addTask {
                    let logger = makeLogger("matter.controller", table: table, sink: sink)
                    for n in 0..<200 {
                        if n % 20 == 0 { await Task.yield() }
                        logger.trace("never")
                        logger.debug("maybe")
                    }
                }
            }
        }
        #expect(!sink.all.isEmpty)
        #expect(sink.all.allSatisfy { $0 == "debug maybe" })
        let logger = makeLogger("matter.controller", table: table, sink: sink)
        #expect(logger.logLevel == .debug)
    }
}
