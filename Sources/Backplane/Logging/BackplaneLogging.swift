//
//  BackplaneLogging.swift
//  swift-backplane
//

import Foundation
import Logging

/// A factory that produces a `LogHandler` for a given logger label.
///
/// Used as the closure argument to `LoggingSystem.bootstrap(_:)`, either
/// directly or via ``BackplaneApplication/bootstrapLogging(using:metadataProvider:logLevel:)``.
public typealias LogHandlerFactory = @Sendable (_ label: String) -> any LogHandler

/// Namespace for Backplane's logging conveniences: stock `LogHandler`
/// factories and a composable environment-driven selector.
///
/// The intent is to make the default sensible (vendor-neutral
/// structured JSON in cloud environments, plain text on a developer's
/// terminal) without locking apps into any particular sink — every
/// primitive is exposed so apps can compose their own selection or
/// wrap multiple sinks via `MultiplexLogHandler`.
///
/// Vendor-specific dialects (e.g. Cloud Logging's magic-key shape)
/// live in opt-in trait-gated targets: enable the `GCP` package trait
/// for `BackplaneGCP` and use `BackplaneGCP.cloudRunOrStream` for
/// Cloud Logging integration.
public enum BackplaneLogging {

    // MARK: - Stock factories

    /// swift-log's default stream output (stderr by default in
    /// `StreamLogHandler.standardError`, but stdout reads more naturally
    /// for the interactive CLI case).
    public static let stream: LogHandlerFactory = { label in
        StreamLogHandler.standardOutput(label: label)
    }

    /// Vendor-neutral structured JSON via ``StructuredLogHandler`` with
    /// the ``StructuredLogProfile/plain`` profile. Recognised top-level
    /// fields (`severity`, `time`, `message`) survive ingestion by most
    /// cloud log aggregators (Cloud Logging, CloudWatch, Loki,
    /// Datadog) without vendor-specific magic keys.
    public static let plain: LogHandlerFactory = { label in
        StructuredLogHandler(label: label, profile: .plain)
    }

    // MARK: - Stock predicates

    /// True when the process appears to be running on Cloud Run (a
    /// service revision) or a Cloud Run Job. Services set `K_SERVICE`;
    /// Jobs set `CLOUD_RUN_JOB` instead. Either is sufficient evidence
    /// that we're inside the Cloud Run runtime and Cloud Logging will
    /// ingest stdout.
    public static let isCloudRun: EnvironmentSelector.Predicate = {
        let env = ProcessInfo.processInfo.environment
        return env["K_SERVICE"] != nil || env["CLOUD_RUN_JOB"] != nil
    }

    // MARK: - Level resolution

    /// Read a `Logger.Level` from an environment variable.
    ///
    /// The variable's value is matched case-insensitively against
    /// `Logger.Level.rawValue` (`"trace"`, `"debug"`, `"info"`,
    /// `"notice"`, `"warning"`, `"error"`, `"critical"`). Unknown values
    /// and a missing variable both return `nil` so the caller can fall
    /// back to its own default.
    ///
    /// Default variable name is `LOG_LEVEL`. Apps that want a more
    /// specific name (e.g. `MYAPP_LOG_LEVEL`) pass it explicitly.
    public static func resolveLogLevel(envVar: String = "LOG_LEVEL") -> Logger.Level? {
        guard let raw = ProcessInfo.processInfo.environment[envVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty
        else { return nil }
        return Logger.Level(rawValue: raw)
    }

    // MARK: - Default selector

    /// The conventional Backplane default: vendor-neutral structured
    /// JSON (``plain``) when running on Cloud Run / Cloud Run Jobs,
    /// plain text everywhere else (local dev, ad-hoc CLI invocations,
    /// CI).
    ///
    /// Apps that want Cloud Logging's magic-key dialect (the `view
    /// trace` link, GCP-specific severity strings, etc.) should enable
    /// the `GCP` package trait and use `BackplaneGCP.cloudRunOrStream`
    /// from the `BackplaneGCP` target instead.
    public static let cloudRunOrStream = EnvironmentSelector(
        entries: [(isCloudRun, plain)],
        fallback: stream
    )

    // MARK: - EnvironmentSelector

    /// Picks a `LogHandler` factory at bootstrap time by evaluating
    /// predicates against the current process's environment.
    ///
    /// Predicates are evaluated in order; the first match's factory is
    /// adopted. If none match, the `fallback` factory is used.
    ///
    /// ```swift
    /// let selector = BackplaneLogging.EnvironmentSelector(
    ///     entries: [
    ///         ({ ProcessInfo.processInfo.environment["DD_AGENT_HOST"] != nil }, datadogFactory),
    ///         (BackplaneLogging.isCloudRun, BackplaneLogging.plain),
    ///     ],
    ///     fallback: BackplaneLogging.stream
    /// )
    /// MyApp.bootstrapLogging(using: selector.asFactory)
    /// ```
    public struct EnvironmentSelector: Sendable {

        /// A `@Sendable` predicate fired once at bootstrap time.
        ///
        /// Evaluated with no arguments; should consult `ProcessInfo` or
        /// any other process-global state to decide whether the
        /// associated factory wins.
        public typealias Predicate = @Sendable () -> Bool

        /// One predicate paired with the factory to use when it fires.
        public typealias Entry = (predicate: Predicate, factory: LogHandlerFactory)

        public var entries: [Entry]
        public var fallback: LogHandlerFactory

        public init(entries: [Entry] = [], fallback: @escaping LogHandlerFactory) {
            self.entries = entries
            self.fallback = fallback
        }

        /// Add an entry to the front of the list — useful for adding a
        /// site-specific override on top of an existing selector.
        public func prepending(_ predicate: @escaping Predicate, factory: @escaping LogHandlerFactory) -> Self {
            var copy = self
            copy.entries.insert((predicate, factory), at: 0)
            return copy
        }

        /// Resolve a `LogHandler` for the given label by walking entries.
        public func makeHandler(for label: String) -> any LogHandler {
            for entry in entries where entry.predicate() {
                return entry.factory(label)
            }
            return fallback(label)
        }

        /// The selector as a factory closure suitable for
        /// `LoggingSystem.bootstrap(_:)` and
        /// ``BackplaneApplication/bootstrapLogging(using:metadataProvider:logLevel:)``.
        public var asFactory: LogHandlerFactory {
            { label in self.makeHandler(for: label) }
        }
    }
}
