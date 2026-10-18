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

    @Test("isExpired is inclusive of expiresAt; nil never expires")
    func expiryPredicate() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let rule = LogLevelRule(labelPrefix: "a", level: .debug, expiresAt: at)
        #expect(rule.isExpired(at: at.addingTimeInterval(-1)) == false)
        #expect(rule.isExpired(at: at) == true)
        #expect(LogLevelRule(labelPrefix: "a", level: .debug).isExpired(at: .distantFuture) == false)
    }
}
