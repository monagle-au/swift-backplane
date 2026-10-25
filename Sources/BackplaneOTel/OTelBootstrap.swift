//
//  OTelBootstrap.swift
//  swift-backplane
//

#if BACKPLANE_OTEL

import Backplane
import Foundation
import Logging
import OTel
import ServiceLifecycle

extension BackplaneOTel {

    /// Build a `BootstrapPlan` that carries swift-otel's backends for
    /// ``BootstrapCoordinator`` to install.
    ///
    /// **This function installs nothing.** It builds each enabled backend with
    /// `OTel.makeTracingBackend`, `OTel.makeMetricsBackend` and
    /// `OTel.makeLoggingBackend`, and returns them as
    /// `BootstrapPlan.instrument`, `.metricsFactory` and `.logHandlerFactory`.
    /// Their export loops go in one `LifecycleService` labelled `otel`.
    /// Apply the plan, through `BackplaneCommand.run()` or
    /// `BootstrapCoordinator.shared.apply(_:)`, and run its lifecycle
    /// services. Because the coordinator installs each subsystem at most once,
    /// a plan applied after `bootstrapLogging` (or any earlier logging plan)
    /// installs tracing and metrics and leaves logging alone. It cannot
    /// bootstrap `LoggingSystem` twice.
    ///
    /// With `logsEnabled`, the OTLP log handler is installed like any other
    /// factory, so the coordinator wraps it in `LevelTableLogHandler`.
    /// `--log-rule`, `logging.rules` and runtime `LogLevelTable.set(_:)`
    /// therefore apply to OTLP records, and `LogLevelTable.isConsulted`
    /// becomes `true`. swift-otel's own `logs.level` / `OTEL_SWIFT_LOG_LEVEL`
    /// no longer filter: the table decides.
    ///
    /// - Parameters:
    ///   - serviceName: `service.name` on every span, metric and log record.
    ///   - tracing: ``OTelTracingOptions/enabled`` gates traces; the endpoint
    ///     and sample rate map onto OTel's configuration.
    ///   - metrics: ``OTelMetricsOptions/enabled`` gates metrics.
    ///   - logsEnabled: Export logs over OTLP. When `false`, the plan leaves
    ///     logging to the caller (`logHandlerFactory` stays `nil`).
    ///   - configure: Last-mile adjustments to `OTel.Configuration` after the
    ///     option groups are applied (endpoints, protocol, headers, mTLS,
    ///     batch sizes). An endpoint set here is used as-is: for OTLP/HTTP
    ///     give the full `/v1/<signal>` URL.
    /// - Returns: An empty plan when every subsystem is off, or when
    ///   `OTEL_SDK_DISABLED` is `true`.
    public static func makeBootstrap(
        serviceName: String,
        tracing: OTelTracingOptions = OTelTracingOptions(),
        metrics: OTelMetricsOptions = OTelMetricsOptions(),
        logsEnabled: Bool = false,
        configure: (@Sendable (inout OTel.Configuration) -> Void)? = nil
    ) throws -> BootstrapPlan {
        try makeBootstrap(
            serviceName: serviceName,
            tracing: tracing,
            metrics: metrics,
            logsEnabled: logsEnabled,
            configure: configure,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func makeBootstrap(
        serviceName: String,
        tracing: OTelTracingOptions,
        metrics: OTelMetricsOptions,
        logsEnabled: Bool,
        configure: (@Sendable (inout OTel.Configuration) -> Void)?,
        environment: [String: String]
    ) throws -> BootstrapPlan {
        var config = OTel.Configuration.default
        config.serviceName = serviceName

        config.traces.enabled = tracing.enabled
        if tracing.enabled {
            if let endpoint = tracing.endpoint {
                config.traces.otlpExporter.endpoint = endpoint
            }
            if let ratio = tracing.sampleRate, let sampler = OTel.Configuration.TracesConfiguration.SamplerConfiguration.traceIDRatio(ratio: ratio) {
                config.traces.sampler = sampler
            }
        }

        config.metrics.enabled = metrics.enabled
        if metrics.enabled, let endpoint = metrics.endpoint {
            config.metrics.otlpExporter.endpoint = endpoint
        }

        config.logs.enabled = logsEnabled

        configure?(&config)

        // swift-otel's make*Backend apply OTEL_SDK_DISABLED themselves and then
        // throw for a disabled subsystem; OTel.bootstrap used to install
        // nothing instead. Keep that: disabled means an empty plan.
        guard !isSDKDisabled(environment),
              config.traces.enabled || config.metrics.enabled || config.logs.enabled
        else {
            return BootstrapPlan()
        }

        var plan = BootstrapPlan()
        var services: [any Service] = []

        if config.traces.enabled {
            let backend = try OTel.makeTracingBackend(configuration: config)
            plan.instrument = backend.factory
            services.append(backend.service)
        }
        if config.metrics.enabled {
            let backend = try OTel.makeMetricsBackend(configuration: config)
            plan.metricsFactory = backend.factory
            services.append(backend.service)
        }
        if config.logs.enabled {
            let backend = try OTel.makeLoggingBackend(configuration: config)
            plan.logHandlerFactory = backend.factory
            if config.traces.enabled {
                plan.loggerMetadataProvider = OTel.makeLoggingMetadataProvider()
            }
            services.append(backend.service)
        }

        // One group, as OTel.bootstrap built: with the default `.cancelGroup`
        // termination, one backend's loop ending stops all three. That matches
        // swift-otel's own bootstrap and is not a new choice.
        plan.lifecycleServices = [
            LifecycleService(
                label: "otel",
                mode: .persistent,
                service: ServiceGroup(services: services, logger: exportLogger)
            )
        ]
        return plan
    }

    /// Whether `OTEL_SDK_DISABLED` is `true` (case- and space-insensitive).
    static func isSDKDisabled(_ environment: [String: String]) -> Bool {
        environment["OTEL_SDK_DISABLED"]?.trimmingCharacters(in: .whitespaces).lowercased() == "true"
    }

    /// The export group's own logger. It writes straight to stderr, not
    /// through `LoggingSystem`, so the OTel services' lifecycle messages can
    /// never loop back into the OTLP log exporter.
    static let exportLogger: Logger = {
        var logger = Logger(label: "backplane.otel", factory: { StreamLogHandler.standardError(label: $0) })
        logger.logLevel = .warning
        return logger
    }()
}

#endif
