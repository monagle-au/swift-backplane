//
//  LogLevelTableTests.swift
//  swift-backplane
//

import Foundation
import Logging
import Testing
@testable import Backplane

@Suite("LogLevelTable")
struct LogLevelTableTests {

    // MARK: - Precedence

    @Test("no rules: every label resolves to the base level")
    func baseLevelOnly() {
        let table = LogLevelTable(baseLevel: .notice)
        #expect(table.level(for: "anything", subsystem: nil) == .notice)
        #expect(table.level(for: "anything", subsystem: "mrp") == .notice)
        #expect(table.minimumLevel(for: "anything") == .notice)
    }

    @Test("the longest matching label prefix wins")
    func longestPrefixWins() {
        let table = LogLevelTable(baseLevel: .info, rules: [
            rule("acumen=warning"),
            rule("acumen.agent=debug"),
            rule("acumen.agent.matter=trace"),
        ])
        #expect(table.level(for: "acumen.agent.matter-agent", subsystem: nil) == .trace)
        #expect(table.level(for: "acumen.agent.hue", subsystem: nil) == .debug)
        #expect(table.level(for: "acumen.engine", subsystem: nil) == .warning)
        #expect(table.level(for: "other", subsystem: nil) == .info)
    }

    @Test("at equal prefix, a subsystem-specific rule beats a subsystem-less one")
    func subsystemBeatsAny() {
        let table = LogLevelTable(baseLevel: .info, rules: [
            rule("matter=debug"),
            rule("matter:mrp=trace"),
            rule("matter:session=error"),
        ])
        #expect(table.level(for: "matter.controller", subsystem: "mrp") == .trace)
        #expect(table.level(for: "matter.controller", subsystem: "session") == .error)
        #expect(table.level(for: "matter.controller", subsystem: "exchange") == .debug)
        #expect(table.level(for: "matter.controller", subsystem: nil) == .debug)
    }

    @Test("a longer prefix whose subsystem does not match falls back to a shorter prefix")
    func nonMatchingSubsystemFallsBack() {
        let table = LogLevelTable(baseLevel: .info, rules: [
            rule("acumen=debug"),
            rule("acumen.agent:mrp=trace"),
        ])
        #expect(table.level(for: "acumen.agent.matter", subsystem: "mrp") == .trace)
        #expect(table.level(for: "acumen.agent.matter", subsystem: "exchange") == .debug)
        #expect(table.level(for: "acumen.agent.matter", subsystem: nil) == .debug)
    }

    @Test("a rule can make a label quieter than the base level")
    func quietingRule() {
        let table = LogLevelTable(baseLevel: .info, rules: [rule("hap-bridge=warning")])
        #expect(table.level(for: "hap-bridge", subsystem: nil) == .warning)
        #expect(table.minimumLevel(for: "hap-bridge") == .warning)
    }

    // MARK: - Minimum per label

    @Test("minimumLevel is the lowest level any subsystem of the label can reach")
    func minimumAcrossSubsystems() {
        let table = LogLevelTable(baseLevel: .info, rules: [
            rule("matter:mrp=trace"),
            rule("matter:session=warning"),
        ])
        #expect(table.minimumLevel(for: "matter.controller") == .trace)
        #expect(table.level(for: "matter.controller", subsystem: nil) == .info)
        #expect(table.minimumLevel(for: "unrelated") == .info)
    }

    @Test("labelEntry flags labels whose exact level depends on subsystem")
    func subsystemSensitivity() {
        let table = LogLevelTable(baseLevel: .info, rules: [rule("matter:mrp=trace"), rule("acumen=debug")])
        #expect(table.labelEntry(for: "matter.x").entry == .init(level: .trace, subsystemSensitive: true))
        #expect(table.labelEntry(for: "acumen.x").entry == .init(level: .debug, subsystemSensitive: false))
    }

    @Test("LabelEntry packs and unpacks every level and the sensitivity bit")
    func labelEntryPacking() {
        for level in Logger.Level.allCases {
            for sensitive in [false, true] {
                let entry = LogLevelTable.LabelEntry(level: level, subsystemSensitive: sensitive)
                let packed = entry.packed(generation: 42)
                #expect(packed >> 8 == 42)
                #expect(LogLevelTable.LabelEntry(packed: packed) == entry)
            }
        }
    }

    // MARK: - Admin API

    @Test("set adds a rule and replaces one with the same label and subsystem")
    func setReplacesSameIdentity() {
        let table = LogLevelTable()
        table.set(rule("matter:*=trace"))
        table.set(rule("matter=debug"))
        table.set(rule("matter:mrp=trace"))
        #expect(table.rules() == [rule("matter:mrp=trace"), rule("matter=debug")])
    }

    @Test("a decoded rule with subsystem * is stored as any-subsystem")
    func decodedStarNormalised() throws {
        let json = #"{"labelPrefix":"matter","subsystem":"*","level":"trace"}"#
        let decoded = try JSONDecoder().decode(LogLevelRule.self, from: Data(json.utf8))
        let table = LogLevelTable()
        table.set(decoded)
        #expect(table.rules().first?.subsystem == nil)
    }

    @Test("remove reports whether a rule was removed; * and nil name the same rule")
    func removeRule() {
        let table = LogLevelTable(rules: [rule("matter:*=trace"), rule("matter:mrp=debug")])
        #expect(table.remove(labelPrefix: "matter") == true)
        #expect(table.remove(labelPrefix: "matter") == false)
        #expect(table.remove(labelPrefix: "matter", subsystem: "mrp") == true)
        #expect(table.rules().isEmpty)
    }

    @Test("reset restores the configured rules, discarding runtime changes")
    func resetRestoresConfigured() {
        let table = LogLevelTable(baseLevel: .info, rules: [rule("acumen=debug")])
        table.set(rule("matter=trace"))
        table.remove(labelPrefix: "acumen")
        table.reset()
        #expect(table.rules() == [rule("acumen=debug")])
        #expect(table.level(for: "matter.x", subsystem: nil) == .info)
    }

    @Test("install replaces base level, configured rules and live rules")
    func installReplacesEverything() {
        let table = LogLevelTable(baseLevel: .info, rules: [rule("acumen=debug")])
        table.set(rule("matter=trace"))
        table.install(baseLevel: .warning, configuredRules: [rule("cloud=debug")])
        let snapshot = table.snapshot()
        #expect(snapshot.baseLevel == .warning)
        #expect(snapshot.rules == [rule("cloud=debug")])
        #expect(snapshot.configuredRules == [rule("cloud=debug")])
        table.set(rule("x=trace"))
        table.reset()
        #expect(table.rules() == [rule("cloud=debug")])
    }

    @Test("rules are listed in precedence order")
    func rulesInPrecedenceOrder() {
        let table = LogLevelTable(rules: [rule("a=debug"), rule("a.b=info"), rule("a.b:mrp=trace"), rule("a.c=error")])
        #expect(table.rules().map(\.description) == ["a.b:mrp=trace", "a.b=info", "a.c=error", "a=debug"])
    }

    // MARK: - Generation

    @Test("every write bumps the generation; reads do not")
    func generationBumpsOnWrite() {
        let table = LogLevelTable()
        let g0 = table.generation
        _ = table.level(for: "x", subsystem: nil)
        _ = table.minimumLevel(for: "x")
        _ = table.rules()
        _ = table.snapshot()
        #expect(table.generation == g0)

        table.set(rule("x=debug"))
        let g1 = table.generation
        #expect(g1 > g0)
        table.remove(labelPrefix: "x")
        let g2 = table.generation
        #expect(g2 > g1)
        table.reset()
        let g3 = table.generation
        #expect(g3 > g2)
        table.install(baseLevel: .debug, configuredRules: [])
        #expect(table.generation > g3)
        #expect(table.snapshot().generation == table.generation)
    }

    // MARK: - Expiry

    @Test("a rule applies until expiresAt, then is ignored and pruned with a generation bump")
    func expiry() {
        let clock = TestClock()
        let table = LogLevelTable(baseLevel: .info, now: { clock.now })
        table.set(LogLevelRule(labelPrefix: "matter", level: .trace, expiresAt: clock.now.addingTimeInterval(10)))
        #expect(table.level(for: "matter.x", subsystem: nil) == .trace)
        #expect(table.rules().count == 1)

        let before = table.generation
        clock.advance(10)
        #expect(table.level(for: "matter.x", subsystem: nil) == .info)
        #expect(table.minimumLevel(for: "matter.x") == .info)
        #expect(table.rules().isEmpty)
        #expect(table.generation > before)
    }

    @Test("pruneIfDue removes expired rules once the watermark passes, and not before")
    func pruneIfDue() {
        let clock = TestClock()
        let table = LogLevelTable(baseLevel: .info, now: { clock.now })
        table.set(LogLevelRule(labelPrefix: "a", level: .debug, expiresAt: clock.now.addingTimeInterval(5)))
        let g = table.generation
        table.pruneIfDue()
        #expect(table.generation == g)
        clock.advance(6)
        table.pruneIfDue()
        #expect(table.generation > g)
        #expect(table.labelEntry(for: "a").entry.level == .info)
    }

    @Test("an already-expired rule is never listed")
    func alreadyExpired() {
        let clock = TestClock()
        let table = LogLevelTable(now: { clock.now })
        table.set(LogLevelRule(labelPrefix: "a", level: .trace, expiresAt: clock.now))
        #expect(table.rules().isEmpty)
        #expect(table.level(for: "a", subsystem: nil) == .info)
    }

    @Test("reset drops configured rules that have since expired")
    func resetSkipsExpiredConfigured() {
        let clock = TestClock()
        let table = LogLevelTable(
            rules: [LogLevelRule(labelPrefix: "a", level: .trace, expiresAt: clock.now.addingTimeInterval(1))],
            now: { clock.now }
        )
        clock.advance(2)
        table.reset()
        #expect(table.rules().isEmpty)
    }

    @Test("a far-future expiresAt neither traps nor expires")
    func farFutureExpiry() {
        let table = LogLevelTable(baseLevel: .info)
        table.set(LogLevelRule(labelPrefix: "a", level: .trace, expiresAt: Date(timeIntervalSince1970: 1e300)))
        #expect(table.rules().count == 1)
        #expect(table.level(for: "a.x", subsystem: nil) == .trace)
        let g = table.generation
        table.pruneIfDue()
        #expect(table.generation == g)
    }

    @Test("a NaN expiresAt is already expired: set drops it and other rules still prune")
    func nanExpiryIsDropped() {
        let clock = TestClock()
        let table = LogLevelTable(baseLevel: .info, now: { clock.now })
        table.set(LogLevelRule(labelPrefix: "nan-rule", level: .trace, expiresAt: Date(timeIntervalSince1970: .nan)))
        #expect(table.rules().isEmpty)
        #expect(table.level(for: "nan-rule.x", subsystem: nil) == .info)
        table.set(LogLevelRule(labelPrefix: "short", level: .debug, expiresAt: clock.now.addingTimeInterval(5)))
        clock.advance(6)
        let g = table.generation
        table.pruneIfDue()
        #expect(table.generation > g)
        #expect(table.rules().isEmpty)
    }

    @Test("a +infinity expiresAt is kept and never expires; -infinity is dropped")
    func infiniteExpiry() {
        let clock = TestClock()
        let table = LogLevelTable(baseLevel: .info, now: { clock.now })
        table.set(LogLevelRule(labelPrefix: "forever", level: .trace, expiresAt: Date(timeIntervalSinceReferenceDate: .infinity)))
        table.set(LogLevelRule(labelPrefix: "gone", level: .trace, expiresAt: Date(timeIntervalSinceReferenceDate: -.infinity)))
        #expect(table.rules().map(\.labelPrefix) == ["forever"])
        clock.advance(1_000_000)
        table.pruneIfDue()
        #expect(table.level(for: "forever.x", subsystem: nil) == .trace)
    }

    // MARK: - Subsystem keys

    @Test("default subsystem keys are subsystem and matter.subsystem")
    func defaultSubsystemKeys() {
        #expect(LogLevelTable().subsystemKeys == ["subsystem", "matter.subsystem"])
        #expect(LogLevelTable(subsystemKeys: ["component"]).subsystemKeys == ["component"])
    }

    // MARK: - Concurrency

    @Test("concurrent set / remove / lookup settles on the last write per rule")
    func concurrentSetAndLookup() async {
        let table = LogLevelTable(baseLevel: .info)
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<4 {
                group.addTask {
                    for i in 0..<200 {
                        if i % 20 == 0 { await Task.yield() }
                        let prefix = "w\(writer).\(i % 10)"
                        table.set(LogLevelRule(labelPrefix: prefix, level: .debug))
                        if i % 2 == 0 { table.remove(labelPrefix: prefix) }
                    }
                }
            }
            for reader in 0..<4 {
                group.addTask {
                    for n in 0..<400 {
                        if n % 40 == 0 { await Task.yield() }
                        let minimum = table.minimumLevel(for: "w\(reader).3.x")
                        #expect(minimum == .info || minimum == .debug)
                        let exact = table.level(for: "w\(reader).4.x", subsystem: "mrp")
                        #expect(exact == .info || exact == .debug)
                    }
                }
            }
        }
        // The last op per prefix "wN.k" ran at i = 190 + k: even k ends removed, odd k ends set.
        #expect(table.rules().count == 20)
        #expect(table.minimumLevel(for: "w0.3.x") == .debug)
        #expect(table.minimumLevel(for: "w0.2.x") == .info)
    }
}
