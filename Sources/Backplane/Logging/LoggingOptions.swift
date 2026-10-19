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
///     var requiredServices: ServiceList { [] }
///
///     func bootstrap(config: ConfigReader, environment: Environment) -> BootstrapPlan {
///         let merged = logging.merging(from: config.scoped(to: "logging"))
///         var plan = BootstrapPlan()
///         plan.logLevel = merged.resolvedLogLevel
///         plan.logRules = merged.resolvedLogRules
///         plan.rejectedLogRules = merged.rejectedLogRules
///         plan.logHandlerFactory = merged.format.factory(default: BackplaneLogging.cloudRunOrStream.asFactory)
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

    /// Per-label level rules, `label[:subsystem]=level`, repeatable:
    /// `--log-rule acumen.agent=debug --log-rule matter:mrp=trace`.
    /// Subsystem `*` means any. Installed as the level table's configured
    /// rules (see ``LogLevelTable``).
    @Option(
        name: .customLong("log-rule"),
        help: ArgumentHelp(
            "Per-label level rule, label[:subsystem]=level (subsystem * = any). Repeatable.",
            valueName: "rule"
        )
    )
    public var logRules: [String] = []

    public init() {}

    /// Rejects a malformed `--log-rule` at parse time.
    public mutating func validate() throws {
        for raw in logRules {
            do {
                _ = try LogLevelRule(parsing: raw)
            } catch {
                throw ValidationError("Invalid --log-rule: \(error)")
            }
        }
    }

    /// ``logRules`` parsed into ``LogLevelRule``s, in order (later rules
    /// win for the same label and subsystem). Malformed entries, which can
    /// arrive only from config because ``validate()`` rejects them on the
    /// command line, are dropped.
    public var resolvedLogRules: [LogLevelRule] {
        logRules.compactMap { try? LogLevelRule(parsing: $0) }
    }

    /// The non-empty ``logRules`` entries that fail to parse, in order.
    /// ``resolvedLogRules`` drops these leniently; log each one as a warning
    /// via ``BootstrapPlan/rejectedLogRules`` so a typo such as
    /// `acumen.agent=debg` is not silent (the coordinator warns once logging
    /// is installed).
    /// This covers config-sourced entries (`logging.rules`); a malformed
    /// `--log-rule` never gets here because ``validate()`` rejects it, by
    /// design.
    /// Empty and whitespace-only entries (a trailing comma in an env-var
    /// list produces one) are skipped, not reported.
    public var rejectedLogRules: [String] {
        logRules.filter { raw in
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (try? LogLevelRule(parsing: raw)) == nil
        }
    }

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
    /// from the supplied `ConfigReader` scope. CLI-supplied values
    /// always win; config fills the gap when CLI was silent.
    ///
    /// Looks up these keys in the supplied scope (typical full keys
    /// after `config.scoped(to: "logging")`):
    ///
    /// | Field      | Config key | Example env var                         |
    /// |------------|------------|-----------------------------------------|
    /// | `logLevel` | `level`    | `LOGGING_LEVEL=debug`                   |
    /// | `format`   | `format`   | `LOGGING_FORMAT=json`                   |
    /// | `logRules` | `rules`    | `LOGGING_RULES=cloud=debug,hap=warning` |
    ///
    /// `rules` is a string array. Config rules are placed *before* CLI
    /// rules, so a `--log-rule` for the same label and subsystem wins.
    ///
    /// The exact env-var spelling depends on which `ConfigProvider`
    /// the app composes (e.g. `EnvironmentVariablesProvider`'s default
    /// dotted-key mapping is uppercase + underscores, arrays comma-separated).
    ///
    /// Use inside ``BackplaneCommand/bootstrap(config:environment:)``:
    ///
    /// ```swift
    /// func bootstrap(config: ConfigReader, environment: Environment) -> BootstrapPlan {
    ///     let merged = logging.merging(from: config.scoped(to: "logging"))
    ///     var plan = BootstrapPlan()
    ///     plan.logLevel = merged.resolvedLogLevel
    ///     plan.logRules = merged.resolvedLogRules
    ///     plan.rejectedLogRules = merged.rejectedLogRules
    ///     plan.logHandlerFactory = merged.format.factory(default: BackplaneLogging.cloudRunOrStream.asFactory)
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
        if let configured = config.stringArray(forKey: "rules"), !configured.isEmpty {
            copy.logRules = configured + copy.logRules
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
