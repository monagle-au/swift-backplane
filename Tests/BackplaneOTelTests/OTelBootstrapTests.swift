//
//  OTelBootstrapTests.swift
//  swift-backplane
//

#if BACKPLANE_OTEL

import Configuration
import Backplane
@testable import BackplaneOTel
import Logging
import Synchronization
import Testing

/// Build an in-memory `ConfigReader` from a flat `[String: String]`
/// map of dotted-path keys.
private func makeConfig(_ values: [String: String]) async -> ConfigReader {
    var converted: [AbsoluteConfigKey: ConfigValue] = [:]
    for (k, v) in values {
        let key = AbsoluteConfigKey(k.split(separator: ".").map(String.init))
        let content: ConfigContent
        if let i = Int(v) {
            content = .int(i)
        } else if let b = Bool(v) {
            content = .bool(b)
        } else if let d = Double(v) {
            content = .double(d)
        } else {
            content = .string(v)
        }
        converted[key] = ConfigValue(content, isSecret: false)
    }
    return ConfigReader(provider: InMemoryProvider(values: converted))
}

@Suite("BackplaneOTel.makeBootstrap")
struct OTelBootstrapTests {

    @Test("All-disabled configuration returns an empty plan with no side effects")
    func allDisabledIsEmptyPlan() throws {
        let tracing = try OTelTracingOptions.parse([])
        let metrics = try OTelMetricsOptions.parse([])

        let plan = try BackplaneOTel.makeBootstrap(
            serviceName: "test-svc",
            tracing: tracing,
            metrics: metrics,
            logsEnabled: false
        )

        #expect(plan.isEmpty == true)
        #expect(plan.lifecycleServices.isEmpty)
    }

    @Test("OTelTracingOptions defaults to disabled")
    func tracingDefaultsDisabled() throws {
        let tracing = try OTelTracingOptions.parse([])
        #expect(tracing.enabled == false)
        #expect(tracing.endpoint == nil)
        #expect(tracing.sampleRate == nil)
    }

    @Test("OTelMetricsOptions defaults to disabled")
    func metricsDefaultsDisabled() throws {
        let metrics = try OTelMetricsOptions.parse([])
        #expect(metrics.enabled == false)
        #expect(metrics.endpoint == nil)
    }

    // MARK: - merging(from:)

    @Test("OTelTracingOptions: merging fills fields from config when CLI is silent")
    func tracingMergingFromConfig() async throws {
        let opts = try OTelTracingOptions.parse([])
        let config = await makeConfig([
            "tracing.enabled": "true",
            "tracing.endpoint": "otel:4317",
            "tracing.sampleRate": "0.25",
        ])
        let merged = opts.merging(from: config.scoped(to: "tracing"))
        #expect(merged.enabled == true)
        #expect(merged.endpoint == "otel:4317")
        #expect(merged.sampleRate == 0.25)
    }

    @Test("OTelMetricsOptions: merging fills fields from config when CLI is silent")
    func metricsMergingFromConfig() async throws {
        let opts = try OTelMetricsOptions.parse([])
        let config = await makeConfig([
            "metrics.enabled": "true",
            "metrics.endpoint": "otel:4318",
        ])
        let merged = opts.merging(from: config.scoped(to: "metrics"))
        #expect(merged.enabled == true)
        #expect(merged.endpoint == "otel:4318")
    }

    @Test("OTelTracingOptions: CLI endpoint wins over config endpoint")
    func tracingCLIEndpointWins() async throws {
        let opts = try OTelTracingOptions.parse([
            "--trace", "--otel-endpoint", "cli:4317",
        ])
        let config = await makeConfig(["tracing.endpoint": "config:4317"])
        let merged = opts.merging(from: config.scoped(to: "tracing"))
        #expect(merged.endpoint == "cli:4317")
    }
}

@Suite("BackplaneOTel.makeBootstrap installs nothing", .serialized)
struct OTelBootstrapPlanTests {

    final class Calls: Sendable {
        private let entries = Mutex<[String]>([])
        func record(_ entry: String) { entries.withLock { $0.append(entry) } }
        var snapshot: [String] { entries.withLock { $0 } }
    }

    final class FactoryBox: Sendable {
        private let factory = Mutex<LogHandlerFactory?>(nil)
        func set(_ newValue: @escaping LogHandlerFactory) { factory.withLock { $0 = newValue } }
        func make(_ label: String) -> (any LogHandler)? { factory.withLock { $0 }?(label) }
    }

    static func allOn(environment: [String: String] = [:]) throws -> BootstrapPlan {
        try BackplaneOTel.makeBootstrap(
            serviceName: "test-svc",
            tracing: try OTelTracingOptions.parse(["--trace"]),
            metrics: try OTelMetricsOptions.parse(["--metrics"]),
            logsEnabled: true,
            configure: noExport,
            environment: environment
        )
    }

    @Test("The plan carries the tracer, metrics factory and log factory, and no global is touched")
    func planCarriesBackends() throws {
        let plan = try Self.allOn()
        #expect(plan.instrument != nil)
        #expect(plan.metricsFactory != nil)
        #expect(plan.logHandlerFactory != nil)
        #expect(plan.loggerMetadataProvider != nil)
        #expect(plan.lifecycleServices.map(\.label) == ["otel"])
        #expect(BootstrapCoordinator.shared.hasBootstrappedLogging == false)
        #expect(BootstrapCoordinator.shared.hasBootstrappedMetrics == false)
        #expect(BootstrapCoordinator.shared.hasBootstrappedTracing == false)
    }

    @Test("After bootstrapLogging, an OTel-logs plan installs tracing and metrics and skips logging")
    func priorLoggingInstallsOnce() throws {
        let calls = Calls()
        let coordinator = BootstrapCoordinator(
            installInstrument: { _ in calls.record("instrument") },
            installMetrics: { _ in calls.record("metrics") },
            installLogging: { _, _, _ in calls.record("logging") }
        )
        var first = BootstrapPlan()
        first.logHandlerFactory = { _ in RecordingHandler(LogSink()) }
        first.levelTable = LogLevelTable()
        coordinator.apply(first)
        var second = try Self.allOn()
        second.levelTable = LogLevelTable()
        coordinator.apply(second)
        #expect(calls.snapshot == ["logging", "instrument", "metrics"])
    }

    @Test("OTEL_SDK_DISABLED=true returns an empty plan")
    func sdkDisabled() throws {
        #expect(try Self.allOn(environment: ["OTEL_SDK_DISABLED": "TRUE"]).isEmpty)
        #expect(BackplaneOTel.isSDKDisabled(["OTEL_SDK_DISABLED": " true "]))
        #expect(!BackplaneOTel.isSDKDisabled(["OTEL_SDK_DISABLED": "false"]))
        #expect(!BackplaneOTel.isSDKDisabled([:]))
    }

    @Test("The plan's log factory stamps the logger label (an OTelRecordLogHandler)")
    func planFactoryStampsLabel() throws {
        let plan = try Self.allOn()
        let factory = try #require(plan.logHandlerFactory)
        #expect(factory("acumen.engine") is OTelRecordLogHandler)
    }

    @Test("The coordinator wraps the OTLP factory in the level table, with local logs multiplexed")
    func coordinatorWrapsInTable() throws {
        let box = FactoryBox()
        let coordinator = BootstrapCoordinator(
            installInstrument: { _ in },
            installMetrics: { _ in },
            installLogging: { factory, _, _ in box.set(factory) }
        )
        var plan = try BackplaneOTel.makeBootstrap(
            serviceName: "test-svc",
            tracing: try OTelTracingOptions.parse([]),
            metrics: try OTelMetricsOptions.parse([]),
            logsEnabled: true,
            configure: noExport,
            localLogs: { _ in RecordingHandler(LogSink()) }
        )
        plan.levelTable = LogLevelTable()
        coordinator.apply(plan)
        let handler = try #require(box.make("acumen.engine") as? LevelTableLogHandler)
        #expect(handler.wrapped is MultiplexLogHandler)
    }

    @Test("With logs off, logging stays the caller's and local logs are ignored")
    func logsOffLeavesLogging() throws {
        let plan = try BackplaneOTel.makeBootstrap(
            serviceName: "test-svc",
            tracing: try OTelTracingOptions.parse(["--trace"]),
            metrics: try OTelMetricsOptions.parse([]),
            logsEnabled: false,
            configure: noExport,
            localLogs: { _ in RecordingHandler(LogSink()) }
        )
        #expect(plan.instrument != nil)
        #expect(plan.logHandlerFactory == nil)
        #expect(plan.loggerMetadataProvider == nil)
        #expect(plan.hasLoggingConfiguration == false)
    }

    @Test("A trailing closure still binds to configure")
    func trailingClosureIsConfigure() throws {
        let plan = try BackplaneOTel.makeBootstrap(
            serviceName: "test-svc",
            tracing: try OTelTracingOptions.parse([]),
            metrics: try OTelMetricsOptions.parse([]),
            logsEnabled: true
        ) { config in
            noExport(&config)
        }
        #expect(plan.logHandlerFactory != nil)
    }

    @Test("An all-on plan applied on a coordinator installs the level table over the OTLP leg")
    func allOnInstallsTableOverOTLP() throws {
        let box = FactoryBox()
        let coordinator = BootstrapCoordinator(
            installInstrument: { _ in },
            installMetrics: { _ in },
            installLogging: { factory, _, _ in box.set(factory) }
        )
        var plan = try Self.allOn()
        plan.levelTable = LogLevelTable()
        coordinator.apply(plan)
        let handler = try #require(box.make("acumen.engine") as? LevelTableLogHandler)
        #expect(handler.wrapped is OTelRecordLogHandler)
    }

    @Test("A metadata provider set on the installed handler stops at the OTLP leg")
    func installedProviderStopsAtOTLP() throws {
        let box = FactoryBox()
        let coordinator = BootstrapCoordinator(
            installInstrument: { _ in },
            installMetrics: { _ in },
            installLogging: { factory, _, _ in box.set(factory) }
        )
        let console = LogSink()
        var plan = try BackplaneOTel.makeBootstrap(
            serviceName: "test-svc",
            tracing: try OTelTracingOptions.parse(["--trace"]),
            metrics: try OTelMetricsOptions.parse([]),
            logsEnabled: true,
            configure: noExport,
            localLogs: { _ in RecordingHandler(console) },
            environment: [:]
        )
        plan.levelTable = LogLevelTable()
        coordinator.apply(plan)
        let provider = try #require(plan.loggerMetadataProvider)

        // With local logs: the console leg takes the provider.
        var withConsole = try #require(box.make("acumen.engine"))
        withConsole.metadataProvider = provider
        #expect(console.providerAssignmentCount == 1)

        // Without: the table wraps the OTLP leg directly, which keeps none.
        let otlpBox = FactoryBox()
        let otlpCoordinator = BootstrapCoordinator(
            installInstrument: { _ in },
            installMetrics: { _ in },
            installLogging: { factory, _, _ in otlpBox.set(factory) }
        )
        var otlpPlan = try Self.allOn()
        otlpPlan.levelTable = LogLevelTable()
        otlpCoordinator.apply(otlpPlan)
        var installed = try #require(otlpBox.make("acumen.engine") as? LevelTableLogHandler)
        installed.metadataProvider = provider
        let leg = try #require(installed.wrapped as? OTelRecordLogHandler)
        #expect(leg.metadataProvider == nil)
        #expect(installed.metadataProvider == nil)
    }
}

#endif
