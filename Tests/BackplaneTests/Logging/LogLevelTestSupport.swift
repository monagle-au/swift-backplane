//
//  LogLevelTestSupport.swift
//  swift-backplane
//

import Foundation
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
