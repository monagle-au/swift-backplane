//
//  LogLevelTable.swift
//  swift-backplane
//

import Foundation
import Logging
import Synchronization

/// A runtime-mutable table of log levels, keyed by logger-label prefix
/// and an optional subsystem.
///
/// Every handler installed through ``BootstrapCoordinator`` is a
/// ``LevelTableLogHandler`` that consults the process's table
/// (``BackplaneLogging/levelTable``), so an admin flow can raise or
/// lower verbosity for one component, or for one subsystem of it,
/// without a restart:
///
/// ```swift
/// BackplaneLogging.levelTable.set(LogLevelRule(
///     labelPrefix: "acumen.agent.matter-agent",
///     subsystem: "mrp",
///     level: .trace,
///     expiresAt: Date().addingTimeInterval(3600)
/// ))
/// ```
///
/// ## Resolution
///
/// For a label and a message subsystem, the rule with the longest
/// matching ``LogLevelRule/labelPrefix`` wins. Among rules with equal
/// prefixes, one whose ``LogLevelRule/subsystem`` equals the message's
/// beats an any-subsystem rule. A rule limited to a different subsystem
/// does not match, and resolution continues to shorter prefixes. With
/// no match, ``baseLevel`` applies.
///
/// ## Configured vs live rules
///
/// ``install(baseLevel:configuredRules:)`` (called by the bootstrap)
/// records the configured rules. ``set(_:)`` and ``remove(labelPrefix:subsystem:)``
/// change only the live rules, and ``reset()`` restores the configured
/// ones. Nothing is persisted: a restart returns to configuration.
///
/// ## Cost
///
/// Every change bumps ``generation``. Handlers cache their label's
/// minimum level against it, so the per-call `logLevel` check is two
/// atomic loads; the lock is taken only after a change, or for
/// messages from a label whose level depends on subsystem.
public final class LogLevelTable: Sendable {

    /// Metadata keys read for a message's subsystem, in order.
    public static let defaultSubsystemKeys: [String] = ["subsystem", "matter.subsystem"]

    /// A consistent view of the table, for listing.
    public struct Snapshot: Sendable, Equatable {
        public let baseLevel: Logger.Level
        /// Live, unexpired rules in precedence order.
        public let rules: [LogLevelRule]
        /// The rules ``LogLevelTable/reset()`` restores (unexpired only).
        public let configuredRules: [LogLevelRule]
        public let generation: UInt64
    }

    /// What a handler caches for its label: the lowest level any message
    /// from the label can be emitted at, and whether the exact level
    /// depends on the message's subsystem.
    struct LabelEntry: Equatable, Sendable {
        let level: Logger.Level
        let subsystemSensitive: Bool

        init(level: Logger.Level, subsystemSensitive: Bool) {
            self.level = level
            self.subsystemSensitive = subsystemSensitive
        }

        init(packed: UInt64) {
            self.level = Logger.Level(tableIndex: packed & 0x7)
            self.subsystemSensitive = packed & 0x80 != 0
        }

        /// `(generation << 8) | sensitivity bit (0x80) | level index (0...6)`.
        func packed(generation: UInt64) -> UInt64 {
            (generation << 8) | (subsystemSensitive ? 0x80 : 0) | level.tableIndex
        }
    }

    /// Metadata keys consulted, in order, for a message's subsystem.
    public let subsystemKeys: [String]

    private struct State: Sendable {
        var baseLevel: Logger.Level
        var configuredRules: [LogLevelRule]
        /// Live rules, normalised, unique by identity, in precedence order.
        var rules: [LogLevelRule]
    }

    private let state: Mutex<State>
    /// Starts at 1 so a zeroed handler cache never matches.
    private let generationCounter = Atomic<UInt64>(1)
    /// Earliest live `expiresAt`, as ceiling milliseconds since 1970; `.max` when none.
    private let nextExpiryMillis = Atomic<Int64>(.max)
    /// Number of label-entry computations; read by tests to prove the cache holds.
    private let entryComputations = Atomic<Int>(0)
    private let now: @Sendable () -> Date

    public init(
        baseLevel: Logger.Level = .info,
        rules: [LogLevelRule] = [],
        subsystemKeys: [String] = LogLevelTable.defaultSubsystemKeys,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let ordered = Self.ordered(rules)
        self.subsystemKeys = subsystemKeys
        self.now = now
        self.state = Mutex(State(baseLevel: baseLevel, configuredRules: ordered, rules: ordered))
        let start = now()
        state.withLock { state in
            _ = self.pruneLocked(&state, at: start)
        }
    }

    // MARK: - Reading

    /// Increases on every change, including the pruning of an expired rule.
    public var generation: UInt64 {
        generationCounter.load(ordering: .acquiring)
    }

    /// The level used when no rule matches.
    public var baseLevel: Logger.Level {
        state.withLock { $0.baseLevel }
    }

    /// Base level, live rules and configured rules under one lock.
    public func snapshot() -> Snapshot {
        let date = now()
        return state.withLock { state in
            _ = pruneLocked(&state, at: date)
            return Snapshot(
                baseLevel: state.baseLevel,
                rules: state.rules,
                configuredRules: state.configuredRules.filter { !$0.isExpired(at: date) },
                generation: generationCounter.load(ordering: .acquiring)
            )
        }
    }

    /// Live, unexpired rules in precedence order.
    public func rules() -> [LogLevelRule] {
        snapshot().rules
    }

    /// The exact level for a message from `label` with `subsystem`.
    public func level(for label: String, subsystem: String?) -> Logger.Level {
        let date = now()
        return state.withLock { state in
            _ = pruneLocked(&state, at: date)
            return Self.resolve(label, subsystem: subsystem, in: state)
        }
    }

    /// The lowest level any message from `label` can be emitted at,
    /// whatever its subsystem.
    public func minimumLevel(for label: String) -> Logger.Level {
        labelEntry(for: label).entry.level
    }

    // MARK: - Writing

    /// Set the base level and the configured rules, and make the
    /// configured rules live. Called by ``BootstrapCoordinator/apply(_:)``.
    public func install(baseLevel: Logger.Level, configuredRules: [LogLevelRule]) {
        let ordered = Self.ordered(configuredRules)
        mutate { state in
            state.baseLevel = baseLevel
            state.configuredRules = ordered
            state.rules = ordered
        }
    }

    /// Add `rule`, replacing any live rule with the same label prefix and subsystem.
    public func set(_ rule: LogLevelRule) {
        let rule = rule.normalized
        mutate { state in
            state.rules.removeAll { $0.identity == rule.identity }
            state.rules.append(rule)
        }
    }

    /// Remove the live rule for `labelPrefix` and `subsystem` (`"*"` and
    /// `nil` name the same rule). Returns whether one was removed.
    @discardableResult
    public func remove(labelPrefix: String, subsystem: String? = nil) -> Bool {
        let identity = LogLevelRule(labelPrefix: labelPrefix, subsystem: subsystem, level: .info).identity
        return mutate { state in
            let before = state.rules.count
            state.rules.removeAll { $0.identity == identity }
            return state.rules.count != before
        }
    }

    /// Discard runtime changes: the live rules become the configured rules.
    public func reset() {
        mutate { state in
            state.rules = state.configuredRules
        }
    }

    // MARK: - Handler support (internal)

    /// The label's cache entry and the generation it is valid for.
    func labelEntry(for label: String) -> (entry: LabelEntry, generation: UInt64) {
        let date = now()
        _ = entryComputations.wrappingAdd(1, ordering: .relaxed)
        return state.withLock { state in
            _ = pruneLocked(&state, at: date)
            return (Self.entry(for: label, in: state), generationCounter.load(ordering: .acquiring))
        }
    }

    /// Prune expired rules if the earliest expiry has passed. Lock-free
    /// when nothing is due. Called by handlers before applying a cached level.
    func pruneIfDue() {
        let due = nextExpiryMillis.load(ordering: .acquiring)
        guard due != .max else { return }
        let date = now()
        guard Self.floorMillis(date) >= due else { return }
        state.withLock { state in
            _ = pruneLocked(&state, at: date)
        }
    }

    var entryComputationCount: Int {
        entryComputations.load(ordering: .relaxed)
    }

    // MARK: - Internals

    @discardableResult
    private func mutate<R: Sendable>(_ body: (inout State) -> R) -> R {
        let date = now()
        return state.withLock { state in
            let result = body(&state)
            state.rules = Self.ordered(state.rules)
            _ = pruneLocked(&state, at: date)
            // Bump after mutating, inside the lock: a reader that sees the
            // new generation is guaranteed to compute from the new state.
            bumpGenerationLocked()
            return result
        }
    }

    /// Drop expired live rules and refresh the expiry watermark. Bumps the
    /// generation when a rule was removed. Call only inside `state.withLock`.
    private func pruneLocked(_ state: inout State, at date: Date) -> Bool {
        let before = state.rules.count
        state.rules.removeAll { $0.isExpired(at: date) }
        let removed = state.rules.count != before
        let next = state.rules.compactMap(\.expiresAt).min()
        nextExpiryMillis.store(next.map(Self.ceilingMillis) ?? .max, ordering: .releasing)
        if removed { bumpGenerationLocked() }
        return removed
    }

    private func bumpGenerationLocked() {
        _ = generationCounter.wrappingAdd(1, ordering: .releasing)
    }

    private static func resolve(_ label: String, subsystem: String?, in state: State) -> Logger.Level {
        for rule in state.rules where label.hasPrefix(rule.labelPrefix) {
            guard let ruleSubsystem = rule.subsystem else { return rule.level }
            if ruleSubsystem == subsystem { return rule.level }
        }
        return state.baseLevel
    }

    private static func entry(for label: String, in state: State) -> LabelEntry {
        var level = resolve(label, subsystem: nil, in: state)
        var sensitive = false
        for rule in state.rules where rule.subsystem != nil && label.hasPrefix(rule.labelPrefix) {
            sensitive = true
            level = min(level, resolve(label, subsystem: rule.subsystem, in: state))
        }
        return LabelEntry(level: level, subsystemSensitive: sensitive)
    }

    /// Normalise, keep the last rule per identity, sort by precedence.
    static func ordered(_ rules: [LogLevelRule]) -> [LogLevelRule] {
        var byIdentity: [LogLevelRule.Identity: LogLevelRule] = [:]
        for rule in rules {
            let normalized = rule.normalized
            byIdentity[normalized.identity] = normalized
        }
        return byIdentity.values.sorted(by: precedes)
    }

    /// Longer prefix first; at equal length, subsystem-specific first; then
    /// lexicographic, so the order is total and listing is deterministic.
    private static func precedes(_ a: LogLevelRule, _ b: LogLevelRule) -> Bool {
        let aCount = a.labelPrefix.count, bCount = b.labelPrefix.count
        if aCount != bCount { return aCount > bCount }
        if (a.subsystem != nil) != (b.subsystem != nil) { return a.subsystem != nil }
        if a.labelPrefix != b.labelPrefix { return a.labelPrefix < b.labelPrefix }
        return (a.subsystem ?? "") < (b.subsystem ?? "")
    }

    private static func ceilingMillis(_ date: Date) -> Int64 {
        saturatingMillis((date.timeIntervalSince1970 * 1000).rounded(.up))
    }

    private static func floorMillis(_ date: Date) -> Int64 {
        saturatingMillis((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// `Int64(_:)` traps on NaN, infinity and out-of-range values. NaN and
    /// the far future map to `.max` (the "nothing due" sentinel); the far
    /// past maps to `.min`.
    private static func saturatingMillis(_ value: Double) -> Int64 {
        if value.isNaN || value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value)
    }
}

extension Logger.Level {
    /// Dense index in severity order, for packing into an atomic word.
    var tableIndex: UInt64 {
        switch self {
        case .trace: 0
        case .debug: 1
        case .info: 2
        case .notice: 3
        case .warning: 4
        case .error: 5
        case .critical: 6
        }
    }

    init(tableIndex: UInt64) {
        switch tableIndex {
        case 0: self = .trace
        case 1: self = .debug
        case 2: self = .info
        case 3: self = .notice
        case 4: self = .warning
        case 5: self = .error
        default: self = .critical
        }
    }
}
