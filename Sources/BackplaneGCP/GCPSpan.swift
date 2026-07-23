//
//  GCPSpan.swift
//  swift-backplane
//

#if BACKPLANE_GCP

import Foundation
import Backplane
import Tracing
import ServiceContextModule

/// A completed span value ready for export to Cloud Trace.
///
/// Produced by ``GCPSpan`` on ``GCPSpan/end(at:)``. All fields required by the
/// Cloud Trace v2 `batchWrite` API are present.
public struct GCPFinishedSpan: Sendable {
    /// 32 lower-case hex chars — the W3C trace ID.
    public let traceID: String
    /// 16 lower-case hex chars — this span's own ID.
    public let spanID: String
    /// 16 lower-case hex chars — the direct parent span, or `nil` for a root span.
    public let parentSpanID: String?
    /// Human-readable display name (typically the RPC or operation name).
    public let displayName: String
    public let startTime: Date
    public let endTime: Date
    public let attributes: SpanAttributes
    public let status: SpanStatus?
}

/// A live tracing span produced by ``GCPTracer``.
///
/// Each span writes `LoggingTraceContext` into its `ServiceContext` so that
/// every log call made while the span is active includes
/// `logging.googleapis.com/trace` and `logging.googleapis.com/spanId` — the
/// fields Cloud Logging uses to render a "view trace" link alongside each
/// log entry.
///
/// Call ``end(at:)`` exactly once when the measured operation finishes. The span
/// produces a ``GCPFinishedSpan`` and hands it to ``CloudTraceExporter`` via an
/// `onEnd` closure. After `end()` returns, the span must not be used again.
public final class GCPSpan: Tracing.Span, @unchecked Sendable {

    // MARK: - Span protocol

    public let context: ServiceContextModule.ServiceContext

    public var operationName: String {
        get { lock.withLock { _operationName } }
        set { lock.withLock { _operationName = newValue } }
    }

    public var attributes: SpanAttributes {
        get { lock.withLock { _attributes } }
        set { lock.withLock { _attributes = newValue } }
    }

    public var isRecording: Bool {
        lock.withLock { !_ended }
    }

    // MARK: - Private state

    private let lock = NSLock()
    private var _operationName: String
    private var _attributes: SpanAttributes = [:]
    private var _status: SpanStatus?
    private var _ended = false

    private let parentSpanID: String?
    private let startDate: Date
    private let onEnd: @Sendable (GCPFinishedSpan) -> Void

    // MARK: - Init

    init(
        context: ServiceContextModule.ServiceContext,
        operationName: String,
        parentSpanID: String?,
        startDate: Date,
        onEnd: @Sendable @escaping (GCPFinishedSpan) -> Void
    ) {
        self.context = context
        self._operationName = operationName
        self.parentSpanID = parentSpanID
        self.startDate = startDate
        self.onEnd = onEnd
    }

    // MARK: - Span methods

    public func setStatus(_ status: SpanStatus) {
        lock.withLock { _status = status }
    }

    public func addEvent(_ event: SpanEvent) {
        // Span events are not forwarded to Cloud Trace v2 in this implementation.
    }

    public func addLink(_ link: SpanLink) {
        // Span links are not forwarded to Cloud Trace v2 in this implementation.
    }

    public func recordError<I: TracerInstant>(
        _ error: Error,
        attributes: SpanAttributes,
        at instant: @autoclosure () -> I
    ) {
        setStatus(SpanStatus(code: .error, message: error.localizedDescription))
    }

    public func end<I: TracerInstant>(at instant: @autoclosure () -> I) {
        let finished: GCPFinishedSpan? = lock.withLock {
            guard !_ended else { return nil }
            _ended = true
            return GCPFinishedSpan(
                traceID: context.loggingTraceContext?.traceID ?? "",
                spanID: context.loggingTraceContext?.spanID ?? "",
                parentSpanID: parentSpanID,
                displayName: _operationName,
                startTime: startDate,
                endTime: Date(),
                attributes: _attributes,
                status: _status
            )
        }
        if let finished {
            onEnd(finished)
        }
    }
}

#endif
