//
//  OTelTestSupport.swift
//  swift-backplane
//

#if BACKPLANE_OTEL

import Logging
import OTel
import Synchronization

/// One message as a recording handler saw it.
struct RecordedLog: Sendable, Equatable {
    let level: Logger.Level
    let message: String
    let metadata: [String: String]
}

/// Collects what reaches a ``RecordingHandler``, and how often a metadata
/// provider was assigned to it.
final class LogSink: Sendable {
    private let entries = Mutex<[RecordedLog]>([])
    private let providerAssignments = Atomic<Int>(0)

    func append(_ entry: RecordedLog) { entries.withLock { $0.append(entry) } }
    func noteProviderAssigned() { _ = providerAssignments.wrappingAdd(1, ordering: .relaxed) }

    var logs: [RecordedLog] { entries.withLock { $0 } }
    var messages: [String] { logs.map(\.message) }
    var providerAssignmentCount: Int { providerAssignments.load(ordering: .relaxed) }
}

/// A `LogHandler` that records every event it is given, unfiltered.
struct RecordingHandler: LogHandler {
    let sink: LogSink
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    private var provider: Logger.MetadataProvider?

    init(_ sink: LogSink) { self.sink = sink }

    var metadataProvider: Logger.MetadataProvider? {
        get { provider }
        set {
            sink.noteProviderAssigned()
            provider = newValue
        }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var merged = metadata
        if let explicit = event.metadata { merged.merge(explicit) { $1 } }
        sink.append(RecordedLog(
            level: event.level,
            message: event.message.description,
            metadata: merged.mapValues(\.description)
        ))
    }
}

/// Every exporter off, so building a backend opens nothing.
///
/// The OTel suites assume a clean `OTEL_*` environment: swift-otel's
/// `make*Backend` reads `ProcessInfo` itself, beyond what these tests inject.
@Sendable func noExport(_ config: inout OTel.Configuration) {
    config.traces.exporter = .none
    config.metrics.exporter = .none
    config.logs.exporter = .none
}

#endif
