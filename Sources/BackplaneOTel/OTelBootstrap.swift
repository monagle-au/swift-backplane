//
//  OTelBootstrap.swift
//  swift-backplane
//

#if BACKPLANE_OTEL

import Backplane
import Logging
import OTel
import ServiceLifecycle

extension BackplaneOTel {

    /// Build a `BootstrapPlan` that delegates to swift-otel for global
    /// installation of the LoggingSystem/MetricsSystem/InstrumentationSystem
    /// (per the configuration) and runs the returned OTel service alongside
    /// user services.
    ///
    /// swift-otel's `OTel.bootstrap(configuration:)` synchronously calls
    /// `LoggingSystem.bootstrap`/`MetricsSystem.bootstrap`/
    /// `InstrumentationSystem.bootstrap` for every enabled subsystem. To
    /// keep `BootstrapCoordinator` in sync with that side effect — so a
    /// later coordinator-driven bootstrap from another source doesn't try
    /// to re-install — this helper marks the corresponding subsystems as
    /// already-bootstrapped on the shared coordinator before returning.
    ///
    /// - Parameters:
    ///   - serviceName: `service.name` resource attribute applied to every
    ///     emitted span/metric/log. Pass `BackplaneApplication.identifier`.
    ///   - tracing: Tracing CLI flags. ``OTelTracingOptions/enabled`` gates
    ///     the traces subsystem; the endpoint and sample rate map directly
    ///     onto OTel's configuration.
    ///   - metrics: Metrics CLI flags.
    ///   - logsEnabled: Whether OTel should also bootstrap the logging
    ///     subsystem with an OTLP backend. When `true`, OTel takes over
    ///     `LoggingSystem` — apps that want a different log handler
    ///     (e.g. `StructuredLogHandler` with the
    ///     `StructuredLogProfile.plain` or `.gcp(projectID:)` profile)
    ///     should pass `false` here and bootstrap their own logger via
    ///     `BootstrapPlan.logHandlerFactory` (set
    ///     `BootstrapPlan.loggerMetadataProvider` to
    ///     `OTel.makeLoggingMetadataProvider()` so logs still carry
    ///     trace IDs).
    ///   - configure: Optional last-mile escape hatch for adjusting the
    ///     `OTel.Configuration` after this helper has applied the option
    ///     groups but before swift-otel bootstraps. Use it to set
    ///     mTLS paths, custom headers, resource attributes, etc.
    /// - Returns: A `BootstrapPlan` whose `lifecycleServices`
    ///   contains the OTel service. The plan's tracing/metrics/logging
    ///   fields are intentionally left nil — those subsystems are already
    ///   installed by the time the coordinator's `apply(_:)` runs.
    public static func makeBootstrap(
        serviceName: String,
        tracing: OTelTracingOptions = OTelTracingOptions(),
        metrics: OTelMetricsOptions = OTelMetricsOptions(),
        logsEnabled: Bool = false,
        configure: (@Sendable (inout OTel.Configuration) -> Void)? = nil
    ) throws -> BootstrapPlan {
        var config = OTel.Configuration.default
        config.serviceName = serviceName

        // Traces
        config.traces.enabled = tracing.enabled
        if tracing.enabled {
            if let endpoint = tracing.endpoint {
                config.traces.otlpExporter.endpoint = endpoint
            }
            if let ratio = tracing.sampleRate, let sampler = OTel.Configuration.TracesConfiguration.SamplerConfiguration.traceIDRatio(ratio: ratio) {
                config.traces.sampler = sampler
            }
        }

        // Metrics
        config.metrics.enabled = metrics.enabled
        if metrics.enabled, let endpoint = metrics.endpoint {
            config.metrics.otlpExporter.endpoint = endpoint
        }

        // Logs
        config.logs.enabled = logsEnabled

        // Caller's last-mile adjustments
        configure?(&config)

        // OTel needs at least one subsystem enabled — if all three are
        // disabled, return an empty plan rather than throw.
        guard config.traces.enabled || config.metrics.enabled || config.logs.enabled else {
            return BootstrapPlan()
        }

        let service = try OTel.bootstrap(configuration: config)

        // Sync the coordinator's view with the side effect we just performed.
        if config.traces.enabled { BootstrapCoordinator.shared.markTracingBootstrapped() }
        if config.metrics.enabled { BootstrapCoordinator.shared.markMetricsBootstrapped() }
        if config.logs.enabled { BootstrapCoordinator.shared.markLoggingBootstrapped() }

        var plan = BootstrapPlan()
        plan.lifecycleServices = [
            LifecycleService(label: "otel", mode: .persistent, service: service)
        ]
        return plan
    }
}

#endif
