//
//  GCPLogHandler.swift
//  swift-backplane
//

#if BACKPLANE_GCP

import Foundation
import Backplane
import Logging

/// A swift-log `LogHandler` that emits one structured-JSON record per
/// call, shaped for ingestion by Google Cloud Logging.
///
/// Cloud Run, Cloud Run Jobs, and GKE forward stdout/stderr to Cloud
/// Logging. When the captured line is valid JSON, the ingester promotes
/// recognised top-level fields to first-class log entry properties
/// (`severity`, `timestamp`, source location, trace, span) and exposes
/// the remainder as `jsonPayload`. The handler emits exactly that shape.
///
/// This is a thin wrapper around `StructuredLogHandler` configured
/// with the ``Backplane/StructuredLogProfile/gcp(projectID:)`` profile. Apps that
/// don't need the Cloud Logging dialect should use
/// `StructuredLogHandler` directly with the
/// `StructuredLogProfile.plain` profile.
///
/// Reference: <https://cloud.google.com/logging/docs/structured-logging>.
public struct GCPLogHandler: LogHandler {

    /// Synchronous sink for the encoded JSON line (newline already
    /// appended). Defaults to stdout. Tests inject an in-memory sink to
    /// assert output.
    public typealias Sink = StructuredLogHandler.Sink

    /// GCP project ID used to format the
    /// `logging.googleapis.com/trace` field. Cloud Logging requires the
    /// full path `projects/<id>/traces/<traceId>` — the project ID must
    /// be known at log-write time. When `nil`, trace correlation
    /// fields are suppressed even if a `LoggingTraceContext` is
    /// present.
    public let gcpProjectID: String?

    private var inner: StructuredLogHandler

    /// Create a handler writing to standard output (the GCP-recommended
    /// stream — Cloud Logging treats stdout/stderr identically but
    /// stdout reads as the more conventional choice for non-error
    /// severities).
    ///
    /// `gcpProjectID` defaults to `GOOGLE_CLOUD_PROJECT` (Cloud Run
    /// injects this automatically). Pass an explicit value when running
    /// outside Cloud Run, or pass `""` to suppress trace correlation
    /// even when a `LoggingTraceContext` is set.
    public init(
        label: String,
        metadataProvider: Logger.MetadataProvider? = nil,
        logLevel: Logger.Level = .info,
        gcpProjectID: String? = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
    ) {
        let resolved = (gcpProjectID?.isEmpty == true) ? nil : gcpProjectID
        self.gcpProjectID = resolved
        self.inner = StructuredLogHandler(
            label: label,
            profile: .gcp(projectID: resolved),
            metadataProvider: metadataProvider,
            logLevel: logLevel
        )
    }

    /// Create a handler with a custom sink. Used by tests to capture
    /// output without mutating real stdout.
    public init(
        label: String,
        metadataProvider: Logger.MetadataProvider? = nil,
        logLevel: Logger.Level = .info,
        gcpProjectID: String? = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"],
        sink: @escaping Sink
    ) {
        let resolved = (gcpProjectID?.isEmpty == true) ? nil : gcpProjectID
        self.gcpProjectID = resolved
        self.inner = StructuredLogHandler(
            label: label,
            profile: .gcp(projectID: resolved),
            metadataProvider: metadataProvider,
            logLevel: logLevel,
            sink: sink
        )
    }

    // MARK: - LogHandler conformance (forwarded to inner)

    public var label: String { inner.label }

    public var metadata: Logger.Metadata {
        get { inner.metadata }
        set { inner.metadata = newValue }
    }

    public var metadataProvider: Logger.MetadataProvider? {
        get { inner.metadataProvider }
        set { inner.metadataProvider = newValue }
    }

    public var logLevel: Logger.Level {
        get { inner.logLevel }
        set { inner.logLevel = newValue }
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { inner[metadataKey: key] }
        set { inner[metadataKey: key] = newValue }
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata explicitMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        inner.log(
            level: level,
            message: message,
            metadata: explicitMetadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }

    // MARK: - Severity mapping (preserved for backward compat / tests)

    /// Map swift-log levels to the GCP `LogSeverity` enum strings.
    /// Forwards to the implementation in ``StructuredLogProfile``.
    static func gcpSeverity(for level: Logger.Level) -> String {
        StructuredLogProfile.gcpSeverity(for: level)
    }
}

#endif
