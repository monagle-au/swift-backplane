//
//  LoggingOptions.swift
//  swift-backplane
//

import ArgumentParser
import Configuration
import Logging

/// Reusable `ParsableArguments` for command-line logging configuration.
///
/// Compose into a ``BackplaneCommand`` via `@OptionGroup` and consume the
/// values inside ``BackplaneCommand/bootstrap(config:environment:)`` to drive
/// the ``BootstrapPlan``:
///
/// ```swift
/// struct Serve: PersistentCommand {
///     typealias App = MyApp
///     @OptionGroup var logging: LoggingOptions
///     var requiredServices: [any ServiceKey.Type] { [] }
///
///     func bootstrap(config: ConfigReader, environment: Environment) -> BootstrapPlan {
///         var plan = BootstrapPlan()
///         plan.logLevel = logging.resolvedLogLevel
///         plan.logHandlerFactory = logging.format.factory(default: BackplaneLogging.cloudRunOrStream.asFactory)
///         return plan
///     }
/// }
/// ```
///
/// Apps that want different flag spellings, additional options (e.g.
/// `--log-target=file:/var/log/app.log`), or to skip these flags entirely
/// can write their own `ParsableArguments` — these types are conveniences,
/// not requirements.
public struct LoggingOptions: ParsableArguments, Sendable {
    /// The desired log level. Accepts the swift-log level names
    /// (`trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`)
    /// case-insensitively.
    @Option(
        name: .customLong("log-level"),
        help: "Minimum log level: trace, debug, info, notice, warning, error, critical."
    )
    public var logLevel: String?

    /// Output format selection. `.auto` defers to the bootstrap factory's
    /// default selection (e.g. ``BackplaneLogging/cloudRunOrStream``).
    @Option(
        name: .customLong("log-format"),
        help: "Output format: auto, json, text. Defaults to auto."
    )
    public var format: LogFormat = .auto

    public init() {}

    /// Parse ``logLevel`` into a `Logger.Level`. Returns `nil` when the flag
    /// was not supplied or the value isn't recognised — the
    /// ``BootstrapCoordinator`` then falls back to the `LOG_LEVEL` env var
    /// or `.info`.
    public var resolvedLogLevel: Logger.Level? {
        guard let raw = logLevel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else { return nil }
        return Logger.Level(rawValue: raw)
    }

    /// Returns a copy of these options with any unset CLI fields filled
    /// from the supplied ``ConfigReader`` scope. CLI-supplied values
    /// always win; config fills the gap when CLI was silent.
    ///
    /// Looks up these keys in the supplied scope (typical full keys
    /// after `config.scoped(to: "logging")`):
    ///
    /// | Field      | Config key | Example env var      |
    /// |------------|------------|----------------------|
    /// | `logLevel` | `level`    | `LOGGING_LEVEL=debug`|
    /// | `format`   | `format`   | `LOGGING_FORMAT=json`|
    ///
    /// The exact env-var spelling depends on which `ConfigProvider`
    /// the app composes (e.g. `EnvironmentVariablesProvider`'s default
    /// dotted-key mapping is uppercase + underscores).
    ///
    /// Use inside ``BackplaneCommand/bootstrap(config:environment:)``:
    ///
    /// ```swift
    /// func bootstrap(config: ConfigReader, environment: Environment) -> BootstrapPlan {
    ///     let opts = logging.merging(from: config.scoped(to: "logging"))
    ///     var plan = BootstrapPlan()
    ///     plan.logLevel = opts.resolvedLogLevel
    ///     plan.logHandlerFactory = opts.format.factory(default: BackplaneLogging.cloudRunOrStream.asFactory)
    ///     return plan
    /// }
    /// ```
    public func merging(from config: ConfigReader) -> LoggingOptions {
        var copy = self
        if copy.logLevel == nil, let raw = config.string(forKey: "level") {
            copy.logLevel = raw
        }
        // CLI default is `.auto`, which means "defer to the supplied
        // factory". Treat `.auto` as the unset state so config can
        // override; if CLI explicitly set `.json` or `.text`, leave it.
        if copy.format == .auto, let raw = config.string(forKey: "format"),
           let parsed = LogFormat(rawValue: raw.lowercased())
        {
            copy.format = parsed
        }
        return copy
    }

    public enum LogFormat: String, CaseIterable, ExpressibleByArgument, Sendable {
        /// Defer to the supplied default factory (e.g. JSON in Cloud Run,
        /// plain text on a developer's terminal).
        case auto
        /// Force vendor-neutral structured JSON output via
        /// ``StructuredLogHandler`` with the ``StructuredLogProfile/plain``
        /// profile. Apps that want Cloud Logging's magic-key dialect
        /// should enable the `GCP` package trait and override the
        /// factory in their ``BackplaneCommand/bootstrap(config:environment:)``.
        case json
        /// Force plain stream output regardless of environment.
        case text

        /// Resolve the `LogHandlerFactory` for this format. Pass the
        /// fallback factory (used when ``LogFormat/auto`` is selected).
        public func factory(default fallback: @escaping LogHandlerFactory) -> LogHandlerFactory {
            switch self {
            case .auto: return fallback
            case .json: return BackplaneLogging.plain
            case .text: return BackplaneLogging.stream
            }
        }
    }
}
