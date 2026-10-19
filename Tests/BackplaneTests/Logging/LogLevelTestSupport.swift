//
//  LogLevelTestSupport.swift
//  swift-backplane
//

import Foundation
import Logging
import Synchronization
@testable import Backplane

/// A settable clock so expiry tests never sleep.
final class TestClock: Sendable {
    private let current: Mutex<Date>
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = Mutex(start) }
    var now: Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

func rule(_ text: String) -> LogLevelRule {
    // Test literals are well-formed; a failure here is a test bug.
    try! LogLevelRule(parsing: text)
}

/// Collects "<level> <message>" for every event that reaches the inner handler.
final class Sink: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

struct SinkLogHandler: LogHandler {
    let sink: Sink
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    var logLevel: Logger.Level = .info

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        sink.append("\(event.level.rawValue) \(event.message)")
    }
}
