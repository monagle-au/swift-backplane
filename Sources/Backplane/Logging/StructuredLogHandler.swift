//
//  StructuredLogHandler.swift
//  swift-backplane
//

import Foundation
import Logging
import ServiceContextModule

// MARK: - StructuredLogProfile

/// A vendor-flavour for ``StructuredLogHandler``: which top-level JSON
/// keys to use, how to format severity, where source location lives, and
/// what to emit for trace correlation.
///
/// The default ``StructuredLogProfile/plain`` profile emits generic
/// names that any structured-log ingester recognises (Datadog, Loki,
/// CloudWatch, OTel filelog, plus Cloud Logging itself). Vendor
/// shipping their own magic-key dialect provide an extension method
/// returning a customised profile — see
/// `StructuredLogProfile.gcp(projectID:)` in the `BackplaneGCP` target.
public struct StructuredLogProfile: Sendable {

    /// Top-level JSON key for the log severity / level.
    public var severityKey: String

    /// Top-level JSON key for the timestamp.
    public var timeKey: String

    /// Top-level JSON key for the logger label.
    public var loggerKey: String

    /// Top-level JSON key for the human-readable message.
    public var messageKey: String

    /// Top-level JSON key for the structured source-location object.
    /// `nil` omits source location entirely.
    public var sourceLocationKey: String?

    /// Map a `Logger.Level` to the string emitted under
    /// ``severityKey``. The default uppercases the swift-log level name
    /// (`Logger.Level.info` becomes `"INFO"`), which matches both the
    /// RFC 5424 syslog severity names and the GCP `LogSeverity` enum.
    public var severityFormatter: @Sendable (Logger.Level) -> String

    /// Format a source location into the inner JSON object. Default
    /// emits `{ "file": ..., "line": ..., "function": ... }` with `line`
    /// stringified — the shape Cloud Logging and most other ingesters
    /// recognise.
    public var sourceLocationFormatter: @Sendable (_ file: String, _ line: UInt, _ function: String) -> [String: String]

    /// Build vendor-specific trace-correlation metadata from the active
    /// ``LoggingTraceContext``. The returned metadata merges into the
    /// log payload at top level. Caller-supplied metadata wins on
    /// collision. Return `[:]` when no correlation should be emitted —
    /// the ``StructuredLogProfile/plain`` default.
    public var traceCorrelation: @Sendable (LoggingTraceContext) -> Logger.Metadata

    public init(
        severityKey: String,
        timeKey: String,
        loggerKey: String,
        messageKey: String,
        sourceLocationKey: String?,
        severityFormatter: @escaping @Sendable (Logger.Level) -> String,
        sourceLocationFormatter: @escaping @Sendable (_ file: String, _ line: UInt, _ function: String) -> [String: String],
        traceCorrelation: @escaping @Sendable (LoggingTraceContext) -> Logger.Metadata
    ) {
        self.severityKey = severityKey
        self.timeKey = timeKey
        self.loggerKey = loggerKey
        self.messageKey = messageKey
        self.sourceLocationKey = sourceLocationKey
        self.severityFormatter = severityFormatter
        self.sourceLocationFormatter = sourceLocationFormatter
        self.traceCorrelation = traceCorrelation
    }
}

extension StructuredLogProfile {

    /// Vendor-neutral structured JSON with generic keys
    /// (`severity` / `time` / `logger` / `message` / `source`) and
    /// uppercase severity names (`INFO`, `WARNING`, …). No automatic
    /// trace correlation — apps that want trace IDs in logs should
    /// install a `Logger.MetadataProvider` (e.g. swift-otel's
    /// `OTel.makeLoggingMetadataProvider()`).
    public static let plain: StructuredLogProfile = StructuredLogProfile(
        severityKey: "severity",
        timeKey: "time",
        loggerKey: "logger",
        messageKey: "message",
        sourceLocationKey: "source",
        severityFormatter: { $0.rawValue.uppercased() },
        sourceLocationFormatter: { file, line, function in
            ["file": file, "line": String(line), "function": function]
        },
        traceCorrelation: { _ in [:] }
    )
}

// MARK: - StructuredLogHandler

/// A swift-log `LogHandler` that emits one structured-JSON record per
/// call, shaped by a ``StructuredLogProfile``.
///
/// Newline-delimited JSON to stdout is the de facto standard for
/// cloud-native structured logging — Cloud Run/GKE, AWS Fargate's
/// CloudWatch agent, the Datadog agent, Loki/Promtail, and OTel filelog
/// all consume it. The handler emits exactly that shape.
///
/// The default ``StructuredLogProfile/plain`` profile is vendor-neutral.
/// For Cloud Logging's magic key dialect, enable the `GCP` package
/// trait and use `StructuredLogProfile.gcp(projectID:)` (declared in
/// the `BackplaneGCP` target).
public struct StructuredLogHandler: LogHandler {

    /// Synchronous sink for the encoded JSON line (newline already
    /// appended). Defaults to stdout. Tests inject an in-memory sink to
    /// assert output.
    public typealias Sink = @Sendable (_ line: String) -> Void

    public let label: String

    /// The vendor-flavour profile driving key names, severity strings,
    /// source-location placement, and trace-correlation metadata.
    public var profile: StructuredLogProfile

    public var metadata: Logger.Metadata = [:]
    public var metadataProvider: Logger.MetadataProvider?
    public var logLevel: Logger.Level = .info

    private let sink: Sink

    /// Create a handler writing to standard output.
    public init(
        label: String,
        profile: StructuredLogProfile = .plain,
        metadataProvider: Logger.MetadataProvider? = nil,
        logLevel: Logger.Level = .info
    ) {
        self.init(
            label: label,
            profile: profile,
            metadataProvider: metadataProvider,
            logLevel: logLevel,
            sink: Self.standardOutputSink
        )
    }

    /// Create a handler with a custom sink. Used by tests to capture
    /// output without mutating real stdout.
    public init(
        label: String,
        profile: StructuredLogProfile = .plain,
        metadataProvider: Logger.MetadataProvider? = nil,
        logLevel: Logger.Level = .info,
        sink: @escaping Sink
    ) {
        self.label = label
        self.profile = profile
        self.metadataProvider = metadataProvider
        self.logLevel = logLevel
        self.sink = sink
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
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
        // Merge precedence (lowest → highest): handler.metadata, provider, explicit.
        // Same order swift-log's StreamLogHandler uses.
        var merged = self.metadata
        if let provided = metadataProvider?.get(), !provided.isEmpty {
            merged.merge(provided, uniquingKeysWith: { _, new in new })
        }
        if let explicit = explicitMetadata, !explicit.isEmpty {
            merged.merge(explicit, uniquingKeysWith: { _, new in new })
        }

        // Vendor-specific trace correlation. The profile decides what
        // (if anything) to inject. Caller-supplied metadata wins on
        // collision — `uniquingKeysWith: { current, _ in current }`
        // preserves whatever was already merged from explicit/provider/
        // handler sources.
        if let trace = ServiceContextModule.ServiceContext.current?.loggingTraceContext {
            let correlation = profile.traceCorrelation(trace)
            if !correlation.isEmpty {
                merged.merge(correlation, uniquingKeysWith: { existing, _ in existing })
            }
        }

        let payload = LogPayload(
            severityKey: profile.severityKey,
            severityValue: profile.severityFormatter(level),
            timeKey: profile.timeKey,
            timeValue: Self.iso8601.string(from: Date()),
            loggerKey: profile.loggerKey,
            loggerValue: label,
            messageKey: profile.messageKey,
            messageValue: message.description,
            sourceLocationKey: profile.sourceLocationKey,
            sourceLocationValue: profile.sourceLocationFormatter(file, line, function),
            metadata: merged
        )

        guard let data = try? Self.encoder.encode(payload),
              let line = String(data: data, encoding: .utf8)
        else {
            // Encoding failure is unreachable for well-formed payloads;
            // metadata flatten always emits string values. Drop on the
            // floor rather than throw — log handlers can't propagate
            // errors.
            return
        }
        sink(line + "\n")
    }

    // MARK: - Encoding

    /// Encodable view of the log line. Custom `encode(to:)` instead of
    /// `CodingKeys` so the per-line key set is dynamic (the metadata
    /// keys are user-controlled) and the structural keys are
    /// profile-controlled.
    private struct LogPayload: Encodable {
        let severityKey: String
        let severityValue: String
        let timeKey: String
        let timeValue: String
        let loggerKey: String
        let loggerValue: String
        let messageKey: String
        let messageValue: String
        let sourceLocationKey: String?
        let sourceLocationValue: [String: String]
        let metadata: Logger.Metadata

        private struct StringKey: CodingKey {
            let stringValue: String
            init(_ s: String) { self.stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue _: Int) { nil }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: StringKey.self)
            try container.encode(severityValue, forKey: StringKey(severityKey))
            try container.encode(timeValue, forKey: StringKey(timeKey))
            try container.encode(loggerValue, forKey: StringKey(loggerKey))
            try container.encode(messageValue, forKey: StringKey(messageKey))
            if let sourceLocationKey {
                try container.encode(sourceLocationValue, forKey: StringKey(sourceLocationKey))
            }

            // Flatten metadata. Reserved key names — the structural
            // ones we just emitted — are skipped to avoid clobbering the
            // typed fields above; logging metadata that collides loses
            // to the structural field.
            var reserved: Set<String> = [severityKey, timeKey, loggerKey, messageKey]
            if let sourceLocationKey { reserved.insert(sourceLocationKey) }

            for (key, value) in metadata where !reserved.contains(key) {
                try container.encode(Self.flatten(value), forKey: StringKey(key))
            }
        }

        /// Flatten a `Logger.MetadataValue` to its string description.
        /// Loses structural fidelity (a stringified `[1, 2, 3]` becomes
        /// `"[1, 2, 3]"`) but preserves searchability without the
        /// ingester rejecting unknown shapes.
        private static func flatten(_ value: Logger.MetadataValue) -> String {
            switch value {
            case .string(let s): return s
            case .stringConvertible(let c): return c.description
            case .array, .dictionary: return value.description
            }
        }
    }

    // MARK: - Internals

    /// ISO 8601 with millisecond precision and explicit Z. Sorts cleanly
    /// as a string — handy when diffing log lines.
    ///
    /// `nonisolated(unsafe)` is correct here: `ISO8601DateFormatter` is
    /// documented thread-safe for `string(from:)` once its
    /// `formatOptions` are set.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Stable key ordering helps log diff-readability.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Default sink: write atomically to stdout. Each call is one
    /// `FileHandle.write` of a single line, atomic at the syscall level
    /// when the write fits in `PIPE_BUF` (typically ≥512 bytes — enough
    /// for any sensible structured log line).
    static let standardOutputSink: Sink = { line in
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }
}
