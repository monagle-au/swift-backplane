//
//  OTelTracingOptions.swift
//  swift-backplane
//

#if BACKPLANE_OTEL

import ArgumentParser
import Configuration

/// Opinionated `ParsableArguments` for OTel tracing configuration.
///
/// More OTel-specific than the vendor-neutral ``TracingOptions`` in core
/// Backplane — these flags map directly onto fields of
/// `OTel.Configuration.TracesConfiguration` and are consumed by
/// ``BackplaneOTel/makeBootstrap(serviceName:tracing:metrics:logs:)``.
///
/// Compose into a ``BackplaneCommand``:
///
/// ```swift
/// struct Serve: PersistentCommand {
///     typealias App = MyApp
///     @OptionGroup var tracing: OTelTracingOptions
///     var requiredServices: [any ServiceKey.Type] { [] }
///
///     func bootstrap(config: ConfigReader, environment: Environment) throws -> BootstrapPlan {
///         try BackplaneOTel.makeBootstrap(
///             serviceName: App.identifier,
///             tracing: tracing
///         )
///     }
/// }
/// ```
public struct OTelTracingOptions: ParsableArguments, Sendable {
    /// Enable OTel tracing. When `false`, the OTel bootstrap configures
    /// the traces subsystem as disabled and the global `withSpan` becomes
    /// a near-zero-cost passthrough.
    @Flag(
        name: .customLong("trace"),
        inversion: .prefixedNo,
        help: "Enable OTel tracing. Defaults to off."
    )
    public var enabled: Bool = false

    /// OTel collector endpoint (e.g. `localhost:4317` for OTLP/gRPC,
    /// `http://collector:4318` for OTLP/HTTP+Protobuf).
    @Option(
        name: .customLong("otel-endpoint"),
        help: "OTel collector endpoint for traces (e.g. localhost:4317)."
    )
    public var endpoint: String?

    /// Sampling rate, `[0.0, 1.0]`. `nil` keeps OTel's default (parent-based,
    /// `traceIDRatio` 1.0 at root).
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
    /// | Field        | Config key   |
    /// |--------------|--------------|
    /// | `enabled`    | `enabled`    |
    /// | `endpoint`   | `endpoint`   |
    /// | `sampleRate` | `sampleRate` |
    ///
    /// swift-otel itself also reads OpenTelemetry-spec environment
    /// variables (`OTEL_EXPORTER_OTLP_ENDPOINT`,
    /// `OTEL_TRACES_SAMPLER_ARG`, …) when
    /// ``BackplaneOTel/makeBootstrap(serviceName:tracing:metrics:logsEnabled:configure:)``
    /// applies environment overrides, so OTel-standard env vars
    /// continue to work alongside this Backplane-style config.
    public func merging(from config: ConfigReader) -> OTelTracingOptions {
        var copy = self
        if !copy.enabled, let configEnabled = config.bool(forKey: "enabled") {
            copy.enabled = configEnabled
        }
        if copy.endpoint == nil {
            copy.endpoint = config.string(forKey: "endpoint")
        }
        if copy.sampleRate == nil {
            copy.sampleRate = config.double(forKey: "sampleRate")
        }
        return copy
    }
}

#endif
