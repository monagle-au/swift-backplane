//
//  OTelBootstrapTests.swift
//  swift-backplane
//

#if BACKPLANE_OTEL

import Configuration
import Backplane
@testable import BackplaneOTel
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

#endif
