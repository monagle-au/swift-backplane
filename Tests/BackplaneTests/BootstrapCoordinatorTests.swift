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

@Suite("BootstrapCoordinator")
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
        coordinator.apply(first)
        #expect(log.snapshot.count == 1)

        // Second apply with logging again — idempotent, no second install.
        var second = BootstrapPlan()
        second.logLevel = .debug
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
        coordinator.apply(plan)

        #expect(log.snapshot[0] == "logging:warning:no-provider")
    }
}
