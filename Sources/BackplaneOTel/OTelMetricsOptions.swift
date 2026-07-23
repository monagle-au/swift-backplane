//
//  OTelMetricsOptions.swift
//  swift-backplane
//

#if BACKPLANE_OTEL

import ArgumentParser
import Configuration

/// Opinionated `ParsableArguments` for OTel metrics configuration.
public struct OTelMetricsOptions: ParsableArguments, Sendable {
    /// Enable OTel metrics. When `false`, the OTel bootstrap configures
    /// the metrics subsystem as disabled.
    @Flag(
        name: .customLong("metrics"),
        inversion: .prefixedNo,
        help: "Enable OTel metrics. Defaults to off."
    )
    public var enabled: Bool = false

    /// OTel collector endpoint for metrics (overrides traces endpoint when
    /// both are present).
    @Option(
        name: .customLong("otel-metrics-endpoint"),
        help: "OTel collector endpoint for metrics."
    )
    public var endpoint: String?

    public init() {}

    /// Returns a copy of these options with any unset CLI fields filled
    /// from the supplied `ConfigReader` scope. CLI-supplied values
    /// always win; config fills the gap when CLI was silent.
    ///
    /// Looks up these keys in the supplied scope (typical full keys
    /// after `config.scoped(to: "metrics")`):
    ///
    /// | Field      | Config key  |
    /// |------------|-------------|
    /// | `enabled`  | `enabled`   |
    /// | `endpoint` | `endpoint`  |
    public func merging(from config: ConfigReader) -> OTelMetricsOptions {
        var copy = self
        if !copy.enabled, let configEnabled = config.bool(forKey: "enabled") {
            copy.enabled = configEnabled
        }
        if copy.endpoint == nil {
            copy.endpoint = config.string(forKey: "endpoint")
        }
        return copy
    }
}

#endif
