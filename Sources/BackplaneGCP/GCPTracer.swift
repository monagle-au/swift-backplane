//
//  GCPTracer.swift
//  swift-backplane
//

#if BACKPLANE_GCP

import Foundation
import Backplane
import Instrumentation
import Tracing
import ServiceContextModule

/// A `Tracer` that exports spans to Google Cloud Trace and correlates log
/// lines in Cloud Logging.
///
/// Install via ``Backplane/BackplaneApplication/bootstrapGCPTracing(projectID:)``
/// at the very start of `main()`. After bootstrap:
///
/// 1. Every `withSpan` / `startSpan` call (including those in
///    `connect-swift-server` that wrap each gRPC handler) generates or
///    continues a W3C trace ID and span ID.
/// 2. The IDs are stored in `LoggingTraceContext` on the active
///    `ServiceContext` so ``GCPLogHandler`` can read them on every log call
///    and emit `logging.googleapis.com/trace` + `.../spanId` — the fields
///    Cloud Logging uses to render the "view trace" link.
/// 3. Finished spans are handed to ``CloudTraceExporter`` which batches and
///    uploads them to the Cloud Trace v2 REST API.
///
/// W3C Trace Context propagation (`traceparent` header) is supported for both
/// inbound extraction and outbound injection, enabling end-to-end trace
/// continuity through APNs/FCM/upstream HTTP calls.
public struct GCPTracer: Tracer {
    public typealias Span = GCPSpan

    private let gcpProjectID: String
    private let exporter: CloudTraceExporter

    // MARK: - Init (internal — callers use bootstrapGCPTracing)

    init(gcpProjectID: String, exporter: CloudTraceExporter) {
        self.gcpProjectID = gcpProjectID
        self.exporter = exporter
    }

    // MARK: - Tracer

    public func startSpan<Instant: TracerInstant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContextModule.ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> GCPSpan {
        var ctx = context()

        // Inherit the existing trace or start a new one.
        let traceID: String
        let parentSpanID: String?
        if let existing = ctx.loggingTraceContext {
            // Continuing an inbound or previously-started trace — this is a child span.
            traceID = existing.traceID
            parentSpanID = existing.spanID
        } else {
            // Root span — generate a fresh W3C-compliant trace ID (32 hex chars).
            traceID = newHex(bytes: 16)
            parentSpanID = nil
        }

        // Generate a new span ID (16 hex chars) and write it into the context
        // so that every log call inside this span picks it up automatically
        // via GCPLogHandler's ServiceContext.current lookup.
        let spanID = newHex(bytes: 8)
        ctx.loggingTraceContext = LoggingTraceContext(
            traceID: traceID,
            spanID: spanID,
            sampled: true
        )

        let capturedExporter = exporter
        return GCPSpan(
            context: ctx,
            operationName: operationName,
            parentSpanID: parentSpanID,
            startDate: Date(),
            onEnd: { finished in
                // Hand off to the exporter from an unstructured task so `end()`
                // never blocks the caller's execution context. The actor's
                // internal buffer prevents unbounded memory growth.
                Task { await capturedExporter.record(finished) }
            }
        )
    }

    /// No-op — the exporter's background flush loop handles export timing.
    /// A fire-and-forget `Task` initiates one final flush for completeness.
    @available(*, deprecated)
    public func forceFlush() {
        let capturedExporter = exporter
        Task { await capturedExporter.flush() }
    }

    // MARK: - W3C Trace Context propagation

    /// Inject the current span's trace and span IDs into an outbound carrier
    /// as a W3C `traceparent` header.
    ///
    /// Enables end-to-end trace continuity when making outbound HTTP calls
    /// (APNs, FCM, Cloud Trace REST, etc.). The downstream will recognise the
    /// header and continue the same trace tree.
    public func inject<Carrier, Inject: Injector>(
        _ context: ServiceContextModule.ServiceContext,
        into carrier: inout Carrier,
        using injector: Inject
    ) where Inject.Carrier == Carrier {
        guard let trace = context.loggingTraceContext else { return }
        let flags = trace.sampled ? "01" : "00"
        injector.inject(
            "00-\(trace.traceID)-\(trace.spanID)-\(flags)",
            forKey: "traceparent",
            into: &carrier
        )
    }

    /// Extract a W3C `traceparent` header from an inbound carrier and write it
    /// into the `ServiceContext` as a `LoggingTraceContext`.
    ///
    /// Called by connect-swift-server's `ConnectRouter` at request entry so
    /// that the server-side root span continues the caller's trace rather than
    /// starting a fresh one.
    public func extract<Carrier, Extract: Extractor>(
        _ carrier: Carrier,
        into context: inout ServiceContextModule.ServiceContext,
        using extractor: Extract
    ) where Extract.Carrier == Carrier {
        guard let header = extractor.extract(key: "traceparent", from: carrier),
              let parsed = parseTraceparent(header)
        else { return }
        context.loggingTraceContext = parsed
    }

    // MARK: - Helpers

    /// Parse a W3C `traceparent` header value.
    ///
    /// Format: `version-traceId-parentId-traceFlags`
    /// - version: 2 hex digits (only "00" is currently defined)
    /// - traceId: 32 lower-case hex digits
    /// - parentId: 16 lower-case hex digits
    /// - traceFlags: 2 hex digits, bit 0 = sampled
    private func parseTraceparent(_ value: String) -> LoggingTraceContext? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let version = String(parts[0])
        let traceID = String(parts[1])
        let spanID = String(parts[2])
        let flags = String(parts[3])
        // Skip unknown future versions as the spec requires.
        guard version == "00" else { return nil }
        guard traceID.count == 32, spanID.count == 16 else { return nil }
        let sampled = flags.hasSuffix("1")
        return LoggingTraceContext(traceID: traceID, spanID: spanID, sampled: sampled)
    }

    /// Generate `byteCount` random bytes as a lower-case hex string.
    ///
    /// Delegates to `UUID` which on Apple platforms uses `arc4random` and on
    /// Linux reads from `/dev/urandom` — both are cryptographically random
    /// sources suitable for trace/span IDs.
    private func newHex(bytes byteCount: Int) -> String {
        var result = [UInt8]()
        result.reserveCapacity(byteCount)
        while result.count < byteCount {
            let uuid = UUID().uuid
            withUnsafeBytes(of: uuid) { raw in
                let needed = byteCount - result.count
                result.append(contentsOf: raw.prefix(needed))
            }
        }
        return result.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - BackplaneApplication convenience

extension BackplaneApplication {
    /// Bootstrap the global `InstrumentationSystem` with a ``GCPTracer`` that
    /// exports spans to Cloud Trace and correlates log lines in Cloud Logging.
    ///
    /// Call this once at the top of `main()`, **before**
    /// `bootstrapLogging(using:metadataProvider:logLevel:)` so the tracer is
    /// in place before any logger is constructed:
    ///
    /// ```swift
    /// @main
    /// struct MyApp: BackplaneApplication {
    ///     public static func main() async {
    ///         bootstrapGCPTracing()
    ///         bootstrapLogging(metadataProvider: ...)
    ///         await RootCommand.main()
    ///     }
    /// }
    /// ```
    ///
    /// `GOOGLE_CLOUD_PROJECT` is read automatically — Cloud Run injects it for
    /// every service. Pass an explicit `projectID` when running outside Cloud
    /// Run (e.g. local CI, integration tests). Pass `""` to install the tracer
    /// infrastructure without Cloud Trace export: spans are generated and
    /// available for log correlation, but silently dropped instead of uploaded.
    ///
    /// - Parameter projectID: GCP project ID. Defaults to the
    ///   `GOOGLE_CLOUD_PROJECT` environment variable, then `""` (local mode —
    ///   no upload).
    public static func bootstrapGCPTracing(
        projectID: String = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ?? ""
    ) {
        let exporter = CloudTraceExporter(gcpProjectID: projectID)
        let tracer = GCPTracer(gcpProjectID: projectID, exporter: exporter)
        InstrumentationSystem.bootstrap(tracer)
        // The flush loop must outlive the ServiceGroup — an unstructured Task
        // is intentional here. It persists until the process exits and ensures
        // spans are flushed even after the ServiceGroup tears down its services.
        Task { await exporter.run() }
    }
}

#endif
