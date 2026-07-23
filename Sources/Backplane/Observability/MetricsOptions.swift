//
//  MetricsOptions.swift
//  swift-backplane
//

import ArgumentParser
import Configuration

/// Reusable `ParsableArguments` for command-line metrics configuration.
///
/// Vendor-neutral: it carries values only. The app's
/// ``BackplaneCommand/bootstrap(config:environment:)`` consumes them to
/// construct an actual `MetricsFactory` and assigns it to
/// ``BootstrapPlan/metricsFactory``.
public struct MetricsOptions: ParsableArguments, Sendable {
    /// Master enable/disable for metrics. When `false`, the bootstrap
    /// leaves the global metrics system on its no-op default.
    @Flag(
        name: .customLong("metrics"),
        inversion: .prefixedNo,
        help: "Enable metrics export. Defaults to off."
    )
    public var enabled: Bool = false

    /// Metrics-collector endpoint. Format depends on the exporter the
    /// app builds (OTLP/Prometheus pushgateway/StatsD/…).
    @Option(
        name: .customLong("metrics-endpoint"),
        help: "Metrics collector endpoint."
    )
    public var endpoint: String?

    /// Optional explicit interval (seconds) between metrics pushes. `nil`
    /// defers to the exporter's default.
    @Option(
        name: .customLong("metrics-interval"),
        help: "Interval (seconds) between metrics pushes."
    )
    public var intervalSeconds: Int?

    public init() {}

    /// Returns a copy of these options with any unset CLI fields filled
    /// from the supplied `ConfigReader` scope. CLI-supplied values
    /// always win; config fills the gap when CLI was silent.
    ///
    /// Looks up these keys in the supplied scope (typical full keys
    /// after `config.scoped(to: "metrics")`):
    ///
    /// | Field             | Config key         |
    /// |-------------------|--------------------|
    /// | `enabled`         | `enabled`          |
    /// | `endpoint`        | `endpoint`         |
    /// | `intervalSeconds` | `intervalSeconds`  |
    ///
    /// As with ``TracingOptions/merging(from:)``, config can *enable*
    /// the flag when CLI is silent but can't be overridden by an
    /// explicit `--no-metrics` once enabled in config.
    public func merging(from config: ConfigReader) -> MetricsOptions {
        var copy = self
        if !copy.enabled, let configEnabled = config.bool(forKey: "enabled") {
            copy.enabled = configEnabled
        }
        if copy.endpoint == nil {
            copy.endpoint = config.string(forKey: "endpoint")
        }
        if copy.intervalSeconds == nil {
            copy.intervalSeconds = config.int(forKey: "intervalSeconds")
        }
        return copy
    }
}
