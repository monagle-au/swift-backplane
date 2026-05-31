//
//  TracingOptionsTests.swift
//  swift-backplane
//

import ArgumentParser
import Configuration
@testable import Backplane
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

@Suite("TracingOptions")
struct TracingOptionsTests {

    @Test("Defaults: tracing disabled, all fields nil")
    func defaults() throws {
        let opts = try TracingOptions.parse([])
        #expect(opts.enabled == false)
        #expect(opts.endpoint == nil)
        #expect(opts.serviceName == nil)
        #expect(opts.sampleRate == nil)
    }

    @Test("--trace flag enables tracing")
    func traceFlag() throws {
        let opts = try TracingOptions.parse(["--trace"])
        #expect(opts.enabled == true)
    }

    @Test("--no-trace flag disables tracing explicitly")
    func noTraceFlag() throws {
        let opts = try TracingOptions.parse(["--no-trace"])
        #expect(opts.enabled == false)
    }

    @Test("--otel-endpoint and --otel-service-name parse")
    func otelEndpointAndServiceName() throws {
        let opts = try TracingOptions.parse([
            "--trace",
            "--otel-endpoint", "localhost:4317",
            "--otel-service-name", "checkout-svc",
        ])
        #expect(opts.endpoint == "localhost:4317")
        #expect(opts.serviceName == "checkout-svc")
    }

    @Test("--trace-sample parses as Double")
    func sampleRateParses() throws {
        let opts = try TracingOptions.parse(["--trace", "--trace-sample", "0.25"])
        #expect(opts.sampleRate == 0.25)
    }

    // MARK: - merging(from:)

    @Test("merging enables tracing from config when CLI was silent")
    func mergingEnablesFromConfig() async throws {
        let opts = try TracingOptions.parse([])
        let config = await makeConfig([
            "tracing.enabled": "true",
            "tracing.endpoint": "collector:4317",
            "tracing.serviceName": "svc",
            "tracing.sampleRate": "0.5",
        ])
        let merged = opts.merging(from: config.scoped(to: "tracing"))
        #expect(merged.enabled == true)
        #expect(merged.endpoint == "collector:4317")
        #expect(merged.serviceName == "svc")
        #expect(merged.sampleRate == 0.5)
    }

    @Test("merging: CLI endpoint wins over config endpoint")
    func mergingEndpointPrecedence() async throws {
        let opts = try TracingOptions.parse([
            "--trace", "--otel-endpoint", "cli:4317",
        ])
        let config = await makeConfig(["tracing.endpoint": "config:4317"])
        let merged = opts.merging(from: config.scoped(to: "tracing"))
        #expect(merged.endpoint == "cli:4317")
    }

    @Test("merging: CLI --trace stays enabled even if config says false")
    func mergingCLIEnabledStaysOn() async throws {
        let opts = try TracingOptions.parse(["--trace"])
        let config = await makeConfig(["tracing.enabled": "false"])
        let merged = opts.merging(from: config.scoped(to: "tracing"))
        #expect(merged.enabled == true)
    }
}

@Suite("MetricsOptions")
struct MetricsOptionsTests {

    @Test("Defaults: metrics disabled, all fields nil")
    func defaults() throws {
        let opts = try MetricsOptions.parse([])
        #expect(opts.enabled == false)
        #expect(opts.endpoint == nil)
        #expect(opts.intervalSeconds == nil)
    }

    @Test("--metrics flag enables metrics")
    func metricsFlag() throws {
        let opts = try MetricsOptions.parse(["--metrics"])
        #expect(opts.enabled == true)
    }

    @Test("--metrics-endpoint and --metrics-interval parse")
    func endpointAndInterval() throws {
        let opts = try MetricsOptions.parse([
            "--metrics",
            "--metrics-endpoint", "localhost:4318",
            "--metrics-interval", "30",
        ])
        #expect(opts.endpoint == "localhost:4318")
        #expect(opts.intervalSeconds == 30)
    }

    @Test("merging fills metrics fields from config when CLI is silent")
    func mergingFromConfig() async throws {
        let opts = try MetricsOptions.parse([])
        let config = await makeConfig([
            "metrics.enabled": "true",
            "metrics.endpoint": "collector:4318",
            "metrics.intervalSeconds": "60",
        ])
        let merged = opts.merging(from: config.scoped(to: "metrics"))
        #expect(merged.enabled == true)
        #expect(merged.endpoint == "collector:4318")
        #expect(merged.intervalSeconds == 60)
    }
}
