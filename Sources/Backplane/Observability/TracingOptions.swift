//
//  TracingOptions.swift
//  swift-backplane
//

import ArgumentParser
import Configuration

/// Reusable `ParsableArguments` for command-line tracing configuration.
///
/// Vendor-neutral: it carries values only. The app's
/// ``BackplaneCommand/bootstrap(config:environment:)`` consumes them to
/// construct an actual `Instrument` (e.g. via the `BackplaneOTel` target
/// when the `OTel` package trait is enabled, or via a hand-rolled tracer)
/// and assigns it to ``BootstrapPlan/instrument``.
///
/// ```swift
/// struct Serve: PersistentCommand {
///     typealias App = MyApp
///     @OptionGroup var tracing: TracingOptions
///     var requiredServices: [any ServiceKey.Type] { [] }
///
///     func bootstrap(config: ConfigReader, environment: Environment) -> BootstrapPlan {
///         var plan = BootstrapPlan()
///         if tracing.enabled {
///             // App-side: build a tracer using tracing.endpoint, tracing.serviceName, etc.
///             let tracer = MyTracer(endpoint: tracing.endpoint, serviceName: tracing.serviceName ?? App.identifier)
///             plan.instrument = tracer
///         }
///         return plan
///     }
/// }
/// ```
public struct TracingOptions: ParsableArguments, Sendable {
    /// Master enable/disable for tracing. When `false`, the bootstrap leaves
    /// the global instrumentation system on its `NoOpInstrument` default
    /// and `withSpan` calls become near-zero-cost passthroughs.
    @Flag(
        name: .customLong("trace"),
        inversion: .prefixedNo,
        help: "Enable distributed tracing. Defaults to off."
    )
    public var enabled: Bool = false

    /// OpenTelemetry collector endpoint (e.g. `localhost:4317` for OTLP/gRPC,
    /// or `http://collector:4318` for OTLP/HTTP). The app decides which
    /// protocol to speak; this is just the address.
    @Option(
        name: .customLong("otel-endpoint"),
        help: "OpenTelemetry collector endpoint (e.g. localhost:4317)."
    )
    public var endpoint: String?

    /// Service-name override sent on every span. When `nil`, apps should
    /// fall back to ``BackplaneApplication/identifier``.
    @Option(
        name: .customLong("otel-service-name"),
        help: "Service name attribute for every emitted span. Defaults to the application identifier."
    )
    public var serviceName: String?

    /// Sampling rate in `[0.0, 1.0]`. `nil` defers to the tracer's default
    /// (typically full sampling in dev, head-based at the collector in prod).
    @Option(
        name: .customLong("trace-sample"),
        help: "Span sampling rate as a fraction in [0.0, 1.0]."
    )
    public var sampleRate: Double?

    public init() {}

    /// Returns a copy of these options with any unset CLI fields filled
    /// from the supplied ``ConfigReader`` scope. CLI-supplied values
    /// always win; config fills the gap when CLI was silent.
    ///
    /// Looks up these keys in the supplied scope (typical full keys
    /// after `config.scoped(to: "tracing")`):
    ///
    /// | Field         | Config key      |
    /// |---------------|-----------------|
    /// | `enabled`     | `enabled`       |
    /// | `endpoint`    | `endpoint`      |
    /// | `serviceName` | `serviceName`   |
    /// | `sampleRate`  | `sampleRate`    |
    ///
    /// The CLI default for ``enabled`` is `false` and there's no way to
    /// distinguish "left at default" from "explicitly --no-trace". Config
    /// can therefore *enable* tracing when CLI is silent or false but
    /// can't be overridden by `--no-trace` once enabled there. To
    /// disable, omit the env var or set the config key to `false`.
    public func merging(from config: ConfigReader) -> TracingOptions {
        var copy = self
        if !copy.enabled, let configEnabled = config.bool(forKey: "enabled") {
            copy.enabled = configEnabled
        }
        if copy.endpoint == nil {
            copy.endpoint = config.string(forKey: "endpoint")
        }
        if copy.serviceName == nil {
            copy.serviceName = config.string(forKey: "serviceName")
        }
        if copy.sampleRate == nil {
            copy.sampleRate = config.double(forKey: "sampleRate")
        }
        return copy
    }
}
