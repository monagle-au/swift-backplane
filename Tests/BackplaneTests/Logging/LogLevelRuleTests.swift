//
//  LogLevelRuleTests.swift
//  swift-backplane
//

import Foundation
import Logging
import Testing
@testable import Backplane

@Suite("LogLevelRule")
struct LogLevelRuleTests {

    @Test("label=level parses with no subsystem")
    func parsesLabelOnly() throws {
        let rule = try LogLevelRule(parsing: "acumen.agent=debug")
        #expect(rule.labelPrefix == "acumen.agent")
        #expect(rule.subsystem == nil)
        #expect(rule.level == .debug)
        #expect(rule.expiresAt == nil)
    }

    @Test("label:subsystem=level parses, level case-insensitively")
    func parsesSubsystem() throws {
        let rule = try LogLevelRule(parsing: "acumen.agent.matter-agent:mrp=TRACE")
        #expect(rule.labelPrefix == "acumen.agent.matter-agent")
        #expect(rule.subsystem == "mrp")
        #expect(rule.level == .trace)
    }

    @Test("subsystem * normalises to nil, both parsed and constructed")
    func starNormalises() throws {
        #expect(try LogLevelRule(parsing: "acumen:*=info").subsystem == nil)
        #expect(LogLevelRule(labelPrefix: "acumen", subsystem: LogLevelRule.anySubsystem, level: .info).subsystem == nil)
        #expect(
            LogLevelRule(labelPrefix: "acumen", subsystem: "*", level: .info)
                == LogLevelRule(labelPrefix: "acumen", level: .info)
        )
    }

    @Test("surrounding whitespace is trimmed")
    func trimsWhitespace() throws {
        let rule = try LogLevelRule(parsing: "  matter : session = Warning ")
        #expect(rule == LogLevelRule(labelPrefix: "matter", subsystem: "session", level: .warning))
    }

    @Test("malformed rules throw the matching ParseError")
    func malformedRulesThrow() {
        #expect(throws: LogLevelRule.ParseError.missingLevel("acumen")) { try LogLevelRule(parsing: "acumen") }
        #expect(throws: LogLevelRule.ParseError.missingLevel("acumen=")) { try LogLevelRule(parsing: "acumen=") }
        #expect(throws: LogLevelRule.ParseError.unknownLevel("acumen=loud")) { try LogLevelRule(parsing: "acumen=loud") }
        #expect(throws: LogLevelRule.ParseError.emptyLabel("=debug")) { try LogLevelRule(parsing: "=debug") }
        #expect(throws: LogLevelRule.ParseError.emptyLabel(":mrp=debug")) { try LogLevelRule(parsing: ":mrp=debug") }
        #expect(throws: LogLevelRule.ParseError.emptySubsystem("acumen:=debug")) { try LogLevelRule(parsing: "acumen:=debug") }
    }

    @Test("description round-trips through the parser")
    func descriptionRoundTrips() throws {
        let rules = [
            LogLevelRule(labelPrefix: "acumen", level: .debug),
            LogLevelRule(labelPrefix: "matter.controller", subsystem: "mrp", level: .trace),
        ]
        for rule in rules {
            #expect(try LogLevelRule(parsing: rule.description) == rule)
        }
        #expect(rules[1].description == "matter.controller:mrp=trace")
    }

    @Test("Codable round-trips including expiresAt")
    func codableRoundTrips() throws {
        let rule = LogLevelRule(
            labelPrefix: "acumen.agent",
            subsystem: "subscription",
            level: .trace,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let data = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(LogLevelRule.self, from: data) == rule)
    }

    @Test("decoding normalises subsystem * to nil")
    func decodeNormalisesStar() throws {
        let json = #"{"labelPrefix":"acumen","subsystem":"*","level":"debug"}"#
        let rule = try JSONDecoder().decode(LogLevelRule.self, from: Data(json.utf8))
        #expect(rule.subsystem == nil)
        #expect(rule == LogLevelRule(labelPrefix: "acumen", level: .debug))
    }

    @Test("isExpired is inclusive of expiresAt; nil never expires")
    func expiryPredicate() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let rule = LogLevelRule(labelPrefix: "a", level: .debug, expiresAt: at)
        #expect(rule.isExpired(at: at.addingTimeInterval(-1)) == false)
        #expect(rule.isExpired(at: at) == true)
        #expect(LogLevelRule(labelPrefix: "a", level: .debug).isExpired(at: .distantFuture) == false)
    }

    @Test("expiry at exactly now counts as expired; a hair after does not")
    func expiryBoundary() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000.123456)
        #expect(LogLevelRule(labelPrefix: "a", level: .debug, expiresAt: now).isExpired(at: now))
        let later = Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.nextUp)
        #expect(LogLevelRule(labelPrefix: "a", level: .debug, expiresAt: later).isExpired(at: now) == false)
    }

    @Test("infinite expiry: +infinity never expires, -infinity is expired")
    func infiniteExpiryPredicate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LogLevelRule(labelPrefix: "a", level: .debug, expiresAt: Date(timeIntervalSinceReferenceDate: .infinity)).isExpired(at: now) == false)
        #expect(LogLevelRule(labelPrefix: "a", level: .debug, expiresAt: Date(timeIntervalSinceReferenceDate: -.infinity)).isExpired(at: now))
    }

    @Test("a NaN expiresAt is normalised to distantPast: expired, equal to itself, round-trips as JSON")
    func nanExpiryNormalised() throws {
        let rule = LogLevelRule(labelPrefix: "a", level: .debug, expiresAt: Date(timeIntervalSince1970: .nan))
        #expect(rule.expiresAt == .distantPast)
        #expect(rule.isExpired(at: Date(timeIntervalSince1970: 0)))
        #expect(rule == rule)
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(LogLevelRule.self, from: data)
        #expect(decoded == rule)
        #expect(decoded.expiresAt == .distantPast)
    }

    @Test("decoding a NaN expiresAt normalises it too")
    func decodeNaNExpiry() throws {
        let json = #"{"labelPrefix":"a","level":"debug","expiresAt":"nan"}"#
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let rule = try decoder.decode(LogLevelRule.self, from: Data(json.utf8))
        #expect(rule.expiresAt == .distantPast)
    }
}
