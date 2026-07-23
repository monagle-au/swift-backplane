//
//  CloudTraceExporter.swift
//  swift-backplane
//

#if BACKPLANE_GCP

import Foundation
#if canImport(FoundationNetworking)
// On Linux, URL/HTTP networking types live in a separate module.
import FoundationNetworking
#endif
import Backplane
import Tracing

/// Buffers finished spans and uploads them to the Cloud Trace v2 REST API in
/// batches.
///
/// Spans accumulate in memory and are flushed in two cases:
///
/// - Every 5 seconds via the background flush loop started by
///   ``Backplane/BackplaneApplication/bootstrapGCPTracing(projectID:)``.
/// - When the batch reaches 200 spans (the Cloud Trace `batchWrite` limit).
///
/// All export is best-effort: a failed upload is silently dropped rather than
/// retried, and the exporter never blocks a request path. The sole mechanism
/// against permanent data loss is the 5-second flush cadence — any span that
/// finishes more than 5 seconds before process exit will be exported before
/// shutdown.
///
/// When `gcpProjectID` is empty, spans are silently dropped. Use an empty
/// project ID during local development where the GCP metadata server is not
/// reachable.
public actor CloudTraceExporter {

    // MARK: - Configuration

    private let gcpProjectID: String

    // MARK: - Tuning constants

    private let batchLimit = 200
    private let flushInterval: Duration = .seconds(5)

    // MARK: - State

    private var pending: [GCPFinishedSpan] = []

    // MARK: - URLSession
    //
    // A dedicated session so we never hit the URLSession.shared implicit 60-second
    // timeout — the root cause of the ACS hang that motivated this library feature.

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    // MARK: - Init

    public init(gcpProjectID: String) {
        self.gcpProjectID = gcpProjectID
    }

    // MARK: - Public API

    /// Buffer a finished span for the next flush.
    ///
    /// Triggers an immediate flush when the batch reaches `batchLimit` so
    /// memory usage stays bounded even under very high span throughput.
    public func record(_ span: GCPFinishedSpan) async {
        pending.append(span)
        if pending.count >= batchLimit {
            await flush()
        }
    }

    /// Upload all buffered spans to Cloud Trace immediately.
    ///
    /// Safe to call from outside the actor (e.g. at graceful shutdown).
    /// No-ops when there are no pending spans, or when `gcpProjectID` is
    /// empty.
    public func flush() async {
        guard !gcpProjectID.isEmpty, !pending.isEmpty else {
            pending.removeAll()
            return
        }
        let batch = pending
        pending.removeAll()
        await upload(batch)
    }

    /// Background flush loop — runs until the enclosing task is cancelled.
    ///
    /// Started by `BackplaneApplication.bootstrapGCPTracing(projectID:)` as
    /// an unstructured `Task`. Wakes every `flushInterval` seconds and
    /// uploads any accumulated spans.
    public func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: flushInterval)
            await flush()
        }
    }

    // MARK: - Upload

    private func upload(_ spans: [GCPFinishedSpan]) async {
        guard let token = await fetchToken() else { return }
        guard let body = try? buildRequestBody(spans: spans) else { return }

        let urlString = "https://cloudtrace.googleapis.com/v2/projects/\(gcpProjectID)/traces:batchWrite"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Best-effort upload — errors are silently dropped.
        _ = try? await session.data(for: request)
    }

    // MARK: - GCP metadata server token

    private func fetchToken() async -> String? {
        let urlString = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Google", forHTTPHeaderField: "Metadata-Flavor")
        request.timeoutInterval = 3

        guard let (data, _) = try? await session.data(for: request) else { return nil }

        struct TokenResponse: Decodable { let access_token: String }  // swiftlint:disable:this identifier_name
        return try? JSONDecoder().decode(TokenResponse.self, from: data).access_token
    }

    // MARK: - Cloud Trace v2 request body

    private func buildRequestBody(spans: [GCPFinishedSpan]) throws -> Data {
        let spanObjects = spans.map { span -> [String: Any] in
            var obj: [String: Any] = [
                "name": "projects/\(gcpProjectID)/traces/\(span.traceID)/spans/\(span.spanID)",
                "spanId": span.spanID,
                "displayName": [
                    "value": String(span.displayName.prefix(128)),
                    "truncatedByteCount": 0,
                ],
                "startTime": rfc3339(span.startTime),
                "endTime": rfc3339(span.endTime),
            ]

            if let parent = span.parentSpanID {
                obj["parentSpanId"] = parent
            }

            let attrMap = attributeMap(span.attributes)
            if !attrMap.isEmpty {
                obj["attributes"] = ["attributeMap": attrMap]
            }

            if let status = span.status {
                obj["status"] = [
                    "code": gcpStatusCode(status.code),
                    "message": status.message ?? "",
                ]
            }

            return obj
        }

        return try JSONSerialization.data(withJSONObject: ["spans": spanObjects])
    }

    /// Maps a `SpanStatus.Code` to the gRPC canonical code integers that Cloud
    /// Trace expects in the `status.code` field.
    private func gcpStatusCode(_ code: SpanStatus.Code) -> Int {
        switch code {
        case .ok: return 0     // google.rpc.Code.OK
        case .error: return 2  // google.rpc.Code.UNKNOWN
        }
    }

    /// Converts `SpanAttributes` to the Cloud Trace v2 `attributeMap` shape:
    /// `{ "key": { "stringValue": { "value": "...", "truncatedByteCount": 0 } } }`.
    ///
    /// All attribute values are serialised to strings — Cloud Trace indexes
    /// attribute values as strings regardless of their original type, so the
    /// distinction has no practical query impact.
    private func attributeMap(_ attributes: SpanAttributes) -> [String: Any] {
        var map: [String: Any] = [:]
        attributes.forEach { key, attribute in
            let str: String
            switch attribute {
            case .bool(let b):       str = b ? "true" : "false"
            case .int32(let i):      str = String(i)
            case .int64(let i):      str = String(i)
            case .double(let d):     str = String(d)
            case .string(let s):     str = s
            case .stringConvertible(let c): str = c.description
            default:                 str = String(describing: attribute)
            }
            map[key] = ["stringValue": ["value": str, "truncatedByteCount": 0]]
        }
        return map
    }

    // MARK: - Timestamp formatting

    /// RFC 3339 with millisecond precision — accepted by Cloud Trace v2.
    private func rfc3339(_ date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

#endif
