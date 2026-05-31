//
//  GCPLogProfile.swift
//  swift-backplane
//

#if BACKPLANE_GCP

import Foundation
import Backplane
import Logging

extension StructuredLogProfile {

    /// Cloud Logging profile for Google Cloud Run, GKE, and Cloud Run
    /// Jobs. Emits the magic keys Cloud Logging recognises:
    ///
    /// - `severity` / `time` / `logger` / `message` at the top level
    /// - `logging.googleapis.com/sourceLocation` for source location
    /// - `logging.googleapis.com/trace`,
    ///   `logging.googleapis.com/spanId`, and
    ///   `logging.googleapis.com/trace_sampled` for trace correlation
    ///   when an active ``LoggingTraceContext`` is present and the
    ///   project ID is known
    ///
    /// Reference: <https://cloud.google.com/logging/docs/structured-logging>.
    ///
    /// - Parameter projectID: GCP project ID. Defaults to
    ///   `GOOGLE_CLOUD_PROJECT` (Cloud Run injects this automatically).
    ///   Pass an explicit value when running outside Cloud Run, or pass
    ///   `""`/`nil` to suppress trace correlation even when a
    ///   ``LoggingTraceContext`` is set.
    public static func gcp(
        projectID: String? = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
    ) -> StructuredLogProfile {
        let resolved = (projectID?.isEmpty == true) ? nil : projectID
        return StructuredLogProfile(
            severityKey: "severity",
            timeKey: "time",
            loggerKey: "logger",
            messageKey: "message",
            sourceLocationKey: "logging.googleapis.com/sourceLocation",
            severityFormatter: gcpSeverity(for:),
            sourceLocationFormatter: { file, line, function in
                ["file": file, "line": String(line), "function": function]
            },
            traceCorrelation: { trace in
                guard let resolved else { return [:] }
                return [
                    "logging.googleapis.com/trace": .string("projects/\(resolved)/traces/\(trace.traceID)"),
                    "logging.googleapis.com/spanId": .string(trace.spanID),
                    "logging.googleapis.com/trace_sampled": .string(trace.sampled ? "true" : "false"),
                ]
            }
        )
    }

    /// Map swift-log levels to the GCP `LogSeverity` enum strings.
    /// Reference: <https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#logseverity>.
    static func gcpSeverity(for level: Logger.Level) -> String {
        switch level {
        case .trace, .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .critical: return "CRITICAL"
        }
    }
}

#endif
