//
//  BootstrapCoordinatorTests.swift
//  swift-backplane
//

@testable import Backplane
import Logging
import Metrics
import Instrumentation
import Synchronization
import Testing
import Tracing

@Suite("BootstrapCoordinator", .serialized)
struct BootstrapCoordinatorTests {

    // MARK: - Test doubles

    /// Records each call to the install hooks in order, so tests can assert
    /// both *what* was bootstrapped and the *order* in which it happened.
    private final class CallLog: Sendable {
        private let calls: Mutex<[String]> = Mutex([])

        func record(_ entry: String) {
            calls.withLock { $0.append(entry) }
        }

        var snapshot: [String] {
            calls.withLock { $0 }
        }
    }

    /// Build a coordinator whose install hooks record into the given log
    /// instead of mutating the process-wide subsystems. Tests get a fresh
    /// state machine each time.
    private func makeCoordinator(log: CallLog) -> BootstrapCoordinator {
        BootstrapCoordinator(
            installInstrument: { _ in log.record("instrument") },
            installMetrics: { _ in log.record("metrics") },
            installLogging: { _, level, provider in
                log.record("logging:\(level.rawValue):\(provider == nil ? "no-provider" : "with-provider")")
            }
        )
    }

    /// Captures the factory the coordinator hands to the logging hook.
    private final class FactoryBox: Sendable {
        private let factory = Mutex<LogHandlerFactory?>(nil)
        func set(_ newValue: @escaping LogHandlerFactory) { factory.withLock { $0 = newValue } }
        func make(_ label: String) -> (any LogHandler)? { factory.withLock { $0 }?(label) }
    }

    private func makeCapturingCoordinator(_ box: FactoryBox) -> BootstrapCoordinator {
        BootstrapCoordinator(
            installInstrument: { _ in },
            installMetrics: { _ in },
            installLogging: { factory, _, _ in box.set(factory) }
        )
    }

    // MARK: - Empty plan

    @Test("Empty plan is a no-op")
    func emptyPlanIsNoOp() {
        let log = CallLog()
        let coordinator = makeCoordinator(log: log)
        coordinator.apply(BootstrapPlan())
        #expect(log.snapshot.isEmpty)
        #expect(coordinator.hasBootstrappedLogging == false)
        #expect(coordinator.hasBootstrappedMetrics == false)
        #expect(coordinator.hasBootstrappedTracing == false)

        // A subsequent non-empty plan still works.
        var plan = BootstrapPlan()
        plan.logLevel = .debug
        plan.levelTable = LogLevelTable()
        coordinator.apply(plan)
        #expect(coordinator.hasBootstrappedLogging == true)
    }

    // MARK: - Ordering: tracing → metrics → logging

    @Test("Subsystems install in the documented order: tracing → metrics → logging")
    func installOrderIsTracingMetricsLogging() {
        let log = CallLog()
        let coordinator = makeCoordinator(log: log)

        var plan = BootstrapPlan()
        plan.instrument = NoOpTracer()
        plan.metricsFactory = NOOPMetricsHandler.instance
        plan.logHandlerFactory = { label in StreamLogHandler.standardOutput(label: label) }
        plan.logLevel = .info
        plan.levelTable = LogLevelTable()

        coordinator.apply(plan)

        let entries = log.snapshot
        #expect(entries.count == 3)
        #expect(entries[0] == "instrument")
        #expect(entries[1] == "metrics")
        #expect(entries[2].hasPrefix("logging:"))
    }

    // MARK: - Per-subsystem opt-in

    @Test("A plan with only an instrument bootstraps tracing only")
    func onlyTracing() {
        let log = CallLog()
        let coordinator = makeCoordinator(log: log)
        var plan = BootstrapPlan()
        plan.instrument = NoOpTracer()
        coordinator.apply(plan)

        #expect(log.snapshot == ["instrument"])
        #expect(coordinator.hasBootstrappedTracing == true)
        #expect(coordinator.hasBootstrappedMetrics == false)
        #expect(coordinator.hasBootstrappedLogging == false)
    }

    @Test("A plan with only a logLevel bootstraps logging only")
    func onlyLogLevelBootstrapsLogging() {
        let log = CallLog()
        let coordinator = makeCoordinator(log: log)
        var plan = BootstrapPlan()
        plan.logLevel = .debug
        plan.levelTable = LogLevelTable()
        coordinator.apply(plan)

        #expect(log.snapshot.count == 1)
        #expect(log.snapshot[0].hasPrefix("logging:debug:"))
    }

    @Test("A plan with only a metadataProvider bootstraps logging with the provider")
    func metadataProviderTriggersLoggingWithProvider() {
        let log = CallLog()
        let coordinator = makeCoordinator(log: log)
        var plan = BootstrapPlan()
        plan.loggerMetadataProvider = Logger.MetadataProvider { [:] }
        plan.levelTable = LogLevelTable()
        coordinator.apply(plan)

        #expect(log.snapshot.count == 1)
        #expect(log.snapshot[0].hasSuffix(":with-provider"))
    }

    // MARK: - Idempotency / one-shot semantics

    @Test("Per-subsystem idempotency: re-applying the same field does not re-install")
    func perSubsystemIdempotency() {
        let log = CallLog()
        let coordinator = makeCoordinator(log: log)

        var first = BootstrapPlan()
        first.logLevel = .info
        first.levelTable = LogLevelTable()
        coordinator.apply(first)
        #expect(log.snapshot.count == 1)

        // Second apply with logging again — idempotent, no second install.
        var second = BootstrapPlan()
        second.logLevel = .debug
        second.levelTable = LogLevelTable()
        coordinator.apply(second)
        #expect(log.snapshot.count == 1)
    }

    @Test("Subsequent applies fill slots that the first plan left empty")
    func subsequentApplyFillsEmptySlots() {
        let log = CallLog()
        let coordinator = makeCoordinator(log: log)

        // First plan: logging only.
        var first = BootstrapPlan()
        first.logLevel = .info
        first.levelTable = LogLevelTable()
        coordinator.apply(first)
        #expect(log.snapshot.count == 1)
        #expect(log.snapshot[0].hasPrefix("logging:"))

        // Second plan: tracing — fills the empty slot.
        var second = BootstrapPlan()
        second.instrument = NoOpTracer()
        coordinator.apply(second)
        #expect(log.snapshot.count == 2)
        #expect(log.snapshot[1] == "instrument")
        #expect(coordinator.hasBootstrappedTracing == true)
        #expect(coordinator.hasBootstrappedLogging == true)
    }

    // MARK: - Static escape-hatch markers

    @Test("markLoggingBootstrapped causes a later plan's logging fields to skip install")
    func markLoggingBootstrappedSkipsInstall() {
        let log = CallLog()
        let coordinator = makeCoordinator(log: log)

        coordinator.markLoggingBootstrapped()

        var plan = BootstrapPlan()
        plan.logLevel = .debug
        plan.levelTable = LogLevelTable()
        plan.instrument = NoOpTracer()
        coordinator.apply(plan)

        // Logging was already marked installed — only the tracer fires.
        #expect(log.snapshot == ["instrument"])
        #expect(coordinator.hasBootstrappedLogging == true)
    }

    @Test("markTracingBootstrapped causes a later plan's instrument to skip install")
    func markTracingBootstrappedSkipsInstall() {
        let log = CallLog()
        let coordinator = makeCoordinator(log: log)

        coordinator.markTracingBootstrapped()

        var plan = BootstrapPlan()
        plan.instrument = NoOpTracer()
        plan.logLevel = .info
        plan.levelTable = LogLevelTable()
        coordinator.apply(plan)

        // Tracing already marked — only logging fires.
        #expect(log.snapshot.count == 1)
        #expect(log.snapshot[0].hasPrefix("logging:"))
    }

    // MARK: - Log level resolution

    @Test("explicit logLevel is forwarded verbatim")
    func explicitLogLevel() {
        let log = CallLog()
        let coordinator = makeCoordinator(log: log)
        var plan = BootstrapPlan()
        plan.logLevel = .warning
        plan.levelTable = LogLevelTable()
        coordinator.apply(plan)

        #expect(log.snapshot[0] == "logging:warning:no-provider")
    }

    // MARK: - Level table

    @Test("the logging hook receives a factory wrapped in LevelTableLogHandler over the plan's table")
    func loggingFactoryIsWrapped() throws {
        let box = FactoryBox()
        let coordinator = makeCapturingCoordinator(box)
        let table = LogLevelTable()
        var plan = BootstrapPlan()
        plan.logLevel = .notice
        plan.logRules = [LogLevelRule(labelPrefix: "acumen.agent", level: .trace)]
        plan.levelTable = table
        plan.logHandlerFactory = { label in StreamLogHandler.standardOutput(label: label) }
        coordinator.apply(plan)

        let handler = try #require(box.make("acumen.agent.matter-agent") as? LevelTableLogHandler)
        #expect(handler.table === table)
        #expect(handler.wrapped is StreamLogHandler)
        #expect(table.baseLevel == .notice)
        #expect(table.rules() == plan.logRules)
        #expect(table.snapshot().configuredRules == plan.logRules)
        #expect(handler.logLevel == .trace)
        #expect(box.make("other")?.logLevel == .notice)
    }

    @Test("the resolved level is the table's base level, not a per-handler floor")
    func resolvedLevelIsNotAFloor() throws {
        let box = FactoryBox()
        let coordinator = makeCapturingCoordinator(box)
        let table = LogLevelTable()
        var plan = BootstrapPlan()
        plan.logLevel = .info
        plan.levelTable = table
        coordinator.apply(plan)

        let handler = try #require(box.make("matter.controller"))
        #expect(handler.logLevel == .info)
        table.set(LogLevelRule(labelPrefix: "matter", level: .trace))
        #expect(handler.logLevel == .trace)
    }

    @Test("a plan with only logRules bootstraps logging")
    func logRulesAloneBootstrapLogging() {
        let log = CallLog()
        let coordinator = makeCoordinator(log: log)
        let table = LogLevelTable()
        var plan = BootstrapPlan()
        plan.logRules = [LogLevelRule(labelPrefix: "cloud", level: .debug)]
        plan.levelTable = table
        #expect(plan.isEmpty == false)
        #expect(plan.hasLoggingConfiguration == true)
        coordinator.apply(plan)

        #expect(log.snapshot.count == 1)
        #expect(log.snapshot[0].hasPrefix("logging:"))
        #expect(table.rules() == plan.logRules)
    }

    @Test("rejected log rules are warned about once through the installed handler")
    func rejectedRulesWarned() {
        let coordinator = makeCoordinator(log: CallLog())
        let sink = Sink()
        var plan = BootstrapPlan()
        plan.logLevel = .info
        plan.levelTable = LogLevelTable()
        plan.logHandlerFactory = { _ in SinkLogHandler(sink: sink) }
        plan.rejectedLogRules = ["acumen=debg"]
        coordinator.apply(plan)

        #expect(sink.all == ["warning Ignoring malformed logging rule 'acumen=debg'"])
    }

    @Test("rejectedLogRules alone does not configure logging")
    func rejectedRulesAloneAreEmpty() {
        var plan = BootstrapPlan()
        plan.rejectedLogRules = ["x"]
        #expect(plan.isEmpty)
        #expect(plan.hasLoggingConfiguration == false)
    }

    @Test("a plan with only a levelTable is still empty")
    func levelTableAloneIsEmpty() {
        var plan = BootstrapPlan()
        plan.levelTable = LogLevelTable()
        #expect(plan.isEmpty)
        #expect(plan.hasLoggingConfiguration == false)
    }

    @Test("a multiplexed factory is wrapped outermost, so a runtime rule reaches the logger")
    func multiplexFactoryWrappedOutermost() throws {
        let box = FactoryBox()
        let coordinator = makeCapturingCoordinator(box)
        let table = LogLevelTable()
        let first = Sink()
        let second = Sink()
        var plan = BootstrapPlan()
        plan.logLevel = .notice
        plan.levelTable = table
        plan.logHandlerFactory = { _ in
            MultiplexLogHandler([
                SinkLogHandler(sink: first),
                SinkLogHandler(sink: second),
            ])
        }
        coordinator.apply(plan)

        let logger = Logger(label: "matter.controller") { label in
            box.make(label) ?? SwiftLogNoOpLogHandler()
        }
        #expect(logger.logLevel == .notice)
        logger.debug("before")

        table.set(LogLevelRule(labelPrefix: "matter", level: .trace))
        #expect(logger.logLevel == .trace)
        logger.debug("after")

        #expect(first.all == ["debug after"])
        #expect(second.all == ["debug after"])
    }

    /// Renders "<message> <provider metadata>" so a test can see what the
    /// handler's metadata provider supplied.
    private struct ProviderSinkLogHandler: LogHandler {
        let sink: Sink
        var metadata: Logger.Metadata = [:]
        var metadataProvider: Logger.MetadataProvider?
        var logLevel: Logger.Level = .info

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            let provided = metadataProvider?.get() ?? [:]
            let rendered = provided.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            sink.append((["\(event.message)"] + rendered).joined(separator: " "))
        }
    }

    @Test("the default logging hook forwards the plan's metadata provider to the inner handler")
    func defaultHookForwardsMetadataProvider() throws {
        let sink = Sink()
        let captured = Mutex<(factory: LogHandlerFactory, provider: Logger.MetadataProvider?)?>(nil)
        let coordinator = BootstrapCoordinator(
            installInstrument: { _ in },
            installMetrics: { _ in },
            installLogging: { factory, _, provider in captured.withLock { $0 = (factory, provider) } }
        )
        var plan = BootstrapPlan()
        plan.levelTable = LogLevelTable()
        plan.loggerMetadataProvider = Logger.MetadataProvider { ["request": "r1"] }
        plan.logHandlerFactory = { _ in ProviderSinkLogHandler(sink: sink) }
        coordinator.apply(plan)

        let (factory, provider) = try #require(captured.withLock { $0 })
        // The adapter the default hook hands to `LoggingSystem.bootstrap`.
        let handler = BootstrapCoordinator.handler(from: factory, label: "matter.controller", metadataProvider: provider)
        let table = try #require(handler as? LevelTableLogHandler)
        #expect(table.wrapped.metadataProvider != nil)

        let logger = Logger(label: "matter.controller") { _ in handler }
        logger.info("hello")
        #expect(sink.all == ["hello request=r1"])
    }

    // MARK: - Process table

    /// The only test in the target that writes to
    /// ``BackplaneLogging/levelTable``; every other plan here that
    /// bootstraps logging injects its own table. The suite is `.serialized`,
    /// so the snapshot and restore bracket this test against its siblings
    /// (other suites still run in parallel, but only read the shared
    /// table's identity).
    @Test("without plan.levelTable the process table is used")
    func defaultsToProcessTable() throws {
        let shared = BackplaneLogging.levelTable
        let saved = shared.snapshot()
        // `install` restores the base level and configured rules only;
        // runtime rules set on the shared table are not restored.
        defer { shared.install(baseLevel: saved.baseLevel, configuredRules: saved.configuredRules) }

        let box = FactoryBox()
        let coordinator = makeCapturingCoordinator(box)
        var plan = BootstrapPlan()
        plan.logHandlerFactory = { _ in SwiftLogNoOpLogHandler() }
        coordinator.apply(plan)
        let handler = try #require(box.make("x") as? LevelTableLogHandler)
        #expect(handler.table === BackplaneLogging.levelTable)
    }
}
