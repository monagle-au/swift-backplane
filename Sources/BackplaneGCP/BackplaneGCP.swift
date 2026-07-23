//
//  BackplaneGCP.swift
//  swift-backplane
//

import Backplane
import Logging

/// Namespace for BackplaneGCP APIs.
///
/// Trait-gated. Enable the `GCP` package trait when adding swift-backplane
/// as a dependency to make this target's Cloud Trace tracer / Cloud
/// Trace exporter / Cloud Logging-shaped log handler available.
public enum BackplaneGCP {

    #if BACKPLANE_GCP

    /// `LogHandlerFactory` that constructs a ``GCPLogHandler`` for each
    /// logger label. Pair with `BackplaneApplication.bootstrapLogging(using:metadataProvider:logLevel:)`
    /// or feed into `BootstrapPlan.logHandlerFactory`.
    public static let logHandlerFactory: LogHandlerFactory = { label in
        GCPLogHandler(label: label)
    }

    /// Environment selector that picks ``logHandlerFactory`` (Cloud
    /// Logging-shaped JSON) when running on Cloud Run / Cloud Run Jobs
    /// and falls back to plain stream output everywhere else.
    ///
    /// Use this from an app's
    /// `BackplaneCommand.bootstrap(config:environment:)` when running
    /// on GCP and you want Cloud Trace/Cloud Logging integration:
    ///
    /// ```swift
    /// func bootstrap(config: ConfigReader, environment: Environment) -> BootstrapPlan {
    ///     var plan = BootstrapPlan()
    ///     plan.logHandlerFactory = BackplaneGCP.cloudRunOrStream.asFactory
    ///     return plan
    /// }
    /// ```
    public static let cloudRunOrStream = BackplaneLogging.EnvironmentSelector(
        entries: [(BackplaneLogging.isCloudRun, logHandlerFactory)],
        fallback: BackplaneLogging.stream
    )

    #endif
}
