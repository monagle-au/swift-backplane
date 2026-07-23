//
//  BackplaneApplication+Logging.swift
//  swift-backplane
//

import Logging

extension BackplaneApplication {
    /// Bootstrap `LoggingSystem` with the given factory.
    ///
    /// `LoggingSystem.bootstrap(_:)` is a one-shot global. Prefer the
    /// declarative path: build a ``BootstrapPlan`` from
    /// ``BackplaneCommand/bootstrap(config:environment:)`` so CLI-flag values
    /// like `--log-level` can drive the bootstrap. This static method is an
    /// escape hatch for apps that override `main()`:
    ///
    /// ```swift
    /// @main
    /// struct MyApp: BackplaneApplication {
    ///     // …
    ///     public static func main() async {
    ///         bootstrapLogging()
    ///         await RootCommand.main()
    ///     }
    /// }
    /// ```
    ///
    /// The default factory is ``BackplaneLogging/cloudRunOrStream`` —
    /// JSON for Cloud Logging on Cloud Run / Cloud Run Jobs, plain
    /// stream output everywhere else. Apps wanting different sinks
    /// (Datadog, Honeycomb, multiplexed forwarding, …) supply their own
    /// factory or build a custom ``BackplaneLogging/EnvironmentSelector``.
    ///
    /// Pass a `Logger.MetadataProvider` to attach cross-cutting
    /// metadata (request id, authenticated identity, trace id, …) to
    /// every log line emitted by every `Logger` constructed after this
    /// call. Provider state is typically read from `TaskLocal` values
    /// set by request-scoping middleware. Without one, only metadata
    /// the caller passes via `logger.info(metadata:)` is included.
    ///
    /// This method routes through ``BootstrapCoordinator/shared``, so a
    /// later call to ``BackplaneCommand/bootstrap(config:environment:)``
    /// from inside the same process won't re-install logging.
    ///
    /// - Parameters:
    ///   - factory: Produces the `LogHandler` for each new logger. The
    ///     closure runs once per logger label, the first time that
    ///     label is referenced.
    ///   - metadataProvider: Optional cross-cutting metadata source.
    ///     Evaluated on every log call. Defaults to `nil` (no extra
    ///     metadata).
    ///   - logLevel: Default level applied to every handler this
    ///     bootstrap produces. When `nil`, ``BackplaneLogging/resolveLogLevel(envVar:)``
    ///     reads the `LOG_LEVEL` env var; if that's also unset or unparseable,
    ///     `.info` is used.
    public static func bootstrapLogging(
        using factory: @escaping LogHandlerFactory = BackplaneLogging.cloudRunOrStream.asFactory,
        metadataProvider: Logger.MetadataProvider? = nil,
        logLevel: Logger.Level? = nil
    ) {
        var plan = BootstrapPlan()
        plan.logHandlerFactory = factory
        plan.logLevel = logLevel
        plan.loggerMetadataProvider = metadataProvider
        BootstrapCoordinator.shared.apply(plan)
    }
}
