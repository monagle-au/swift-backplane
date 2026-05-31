//
//  LoggingTraceContext.swift
//  swift-backplane
//

import ServiceContextModule

/// Trace identity surfaced into log lines for correlating logs with traces
/// emitted by any active tracer.
///
/// Backplane does not produce these IDs — that's the tracer's job. Apps
/// running an OpenTelemetry tracer (or any other span emitter) populate
/// this key on the active ``ServiceContext`` at span entry. When set,
/// ``StructuredLogHandler`` calls
/// ``StructuredLogProfile/traceCorrelation`` to convert the IDs into
/// vendor-specific log metadata. The
/// ``StructuredLogProfile/plain`` profile emits no correlation by
/// default; the GCP profile (in the `BackplaneGCP` target) emits the
/// `logging.googleapis.com/trace`, `.../spanId`, and `.../trace_sampled`
/// fields recognised by Cloud Logging.
///
/// The IDs follow the W3C Trace Context spec:
/// 32 lower-case hex chars for `traceID`, 16 for `spanID`. Cloud Logging
/// (and most other ingesters) require those exact shapes — anything
/// else gets emitted as plain metadata without the "view trace" link.
///
/// Decoupling note: this type names neither OpenTelemetry nor any other
/// tracing implementation. The bridge from the tracer's span context to
/// `LoggingTraceContext` lives in the consumer's tracing setup so
/// Backplane stays vendor-neutral.
public struct LoggingTraceContext: Sendable, Equatable {

    /// W3C trace ID — 32 lower-case hex characters.
    public let traceID: String

    /// W3C parent span ID for the active span — 16 lower-case hex characters.
    public let spanID: String

    /// Sampled flag from the W3C `traceparent` header. Cloud Logging uses
    /// this to decide whether the linked trace was actually persisted.
    public let sampled: Bool

    public init(traceID: String, spanID: String, sampled: Bool = true) {
        self.traceID = traceID
        self.spanID = spanID
        self.sampled = sampled
    }
}

/// `ServiceContextKey` for carrying ``LoggingTraceContext`` through the
/// task-local ``ServiceContext``.
public enum LoggingTraceContextKey: ServiceContextKey {
    public typealias Value = LoggingTraceContext
}

extension ServiceContextModule.ServiceContext {

    /// The trace context associated with this `ServiceContext`, if any.
    ///
    /// Set this in your tracing setup at span entry;
    /// ``StructuredLogHandler`` reads it from `ServiceContext.current`
    /// on every log call and routes through the active profile's
    /// ``StructuredLogProfile/traceCorrelation`` formatter.
    public var loggingTraceContext: LoggingTraceContext? {
        get { self[LoggingTraceContextKey.self] }
        set { self[LoggingTraceContextKey.self] = newValue }
    }
}
