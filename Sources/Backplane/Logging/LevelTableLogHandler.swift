//
//  LevelTableLogHandler.swift
//  swift-backplane
//

import Logging
import Synchronization

/// A `LogHandler` that takes its level from a ``LogLevelTable`` and
/// forwards permitted messages to the handler it wraps.
///
/// - The `logLevel` getter returns the lowest level any live rule allows
///   for this handler's label, so swift-log's fast-path check admits every
///   candidate. In the steady state it is a few atomic loads and no lock;
///   it also reads the clock while any live rule has an `expiresAt`, and
///   each handler takes the lock once, to refill its cache, after a rule
///   expires or the table changes.
/// - ``log(event:)`` then applies the exact rule, using the message's
///   subsystem: the first of ``LogLevelTable/subsystemKeys`` found in the
///   message's metadata, else in the logger's metadata
///   (`logger[metadataKey:]`). Metadata-provider values are not consulted.
/// - Setting `logLevel` on a logger records a per-instance floor: the
///   effective minimum is the higher of the floor and the table's level.
///   A logger can make itself quieter than the table, never louder.
///
/// The wrapped handler's own `logLevel` is set to `.trace` at
/// construction, so a filtering inner handler (e.g. a
/// `MultiplexLogHandler` child) does not re-filter what the table admitted.
public struct LevelTableLogHandler: LogHandler {

    public let label: String

    /// The table consulted for this handler's levels.
    public let table: LogLevelTable

    /// The handler permitted messages are forwarded to.
    public private(set) var wrapped: any LogHandler

    private var instanceFloor: Logger.Level?
    private let cache: LevelCache

    public init(label: String, wrapping handler: any LogHandler, table: LogLevelTable = BackplaneLogging.levelTable) {
        var inner = handler
        inner.logLevel = .trace
        table.markConsulted()
        self.label = label
        self.table = table
        self.wrapped = inner
        self.instanceFloor = nil
        self.cache = LevelCache()
    }

    /// Wrap every handler `factory` builds.
    public static func factory(
        wrapping factory: @escaping LogHandlerFactory,
        table: LogLevelTable = BackplaneLogging.levelTable
    ) -> LogHandlerFactory {
        { label in LevelTableLogHandler(label: label, wrapping: factory(label), table: table) }
    }

    public var logLevel: Logger.Level {
        get {
            table.pruneIfDue()
            let tableLevel = cache.entry(in: table, label: label).level
            guard let instanceFloor else { return tableLevel }
            return max(instanceFloor, tableLevel)
        }
        set {
            instanceFloor = newValue
        }
    }

    public var metadata: Logger.Metadata {
        get { wrapped.metadata }
        set { wrapped.metadata = newValue }
    }

    public var metadataProvider: Logger.MetadataProvider? {
        get { wrapped.metadataProvider }
        set { wrapped.metadataProvider = newValue }
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { wrapped[metadataKey: key] }
        set { wrapped[metadataKey: key] = newValue }
    }

    public func log(event: LogEvent) {
        // An expired rule may still be cached as permissive; prune first so
        // the entry below reflects it (lock-free when nothing is due).
        table.pruneIfDue()
        let entry = cache.entry(in: table, label: label)
        let permitted = entry.subsystemSensitive
            ? table.level(for: label, subsystem: subsystem(of: event))
            : entry.level
        guard max(instanceFloor ?? .trace, permitted) <= event.level else { return }
        wrapped.log(event: event)
    }

    private func subsystem(of event: LogEvent) -> String? {
        let keys = table.subsystemKeys
        if let explicit = event.metadata {
            for key in keys {
                if let value = explicit[key] { return Self.text(of: value) }
            }
        }
        for key in keys {
            if let value = wrapped[metadataKey: key] { return Self.text(of: value) }
        }
        return nil
    }

    private static func text(of value: Logger.MetadataValue) -> String {
        switch value {
        case .string(let string): string
        case .stringConvertible(let convertible): convertible.description
        case .array, .dictionary: value.description
        }
    }
}

/// One handler's cached ``LogLevelTable/LabelEntry``, packed with the
/// generation it was computed at. A reference type because `Atomic` is
/// non-copyable and `LogHandler`s are value types; copies of a handler
/// share a label, so they can share the cache.
final class LevelCache: Sendable {
    /// 0 never matches: table generations start at 1.
    private let packed = Atomic<UInt64>(0)

    func entry(in table: LogLevelTable, label: String) -> LogLevelTable.LabelEntry {
        let generation = table.generation
        let current = packed.load(ordering: .acquiring)
        if current >> 8 == generation {
            return LogLevelTable.LabelEntry(packed: current)
        }
        let (entry, computedGeneration) = table.labelEntry(for: label)
        packed.store(entry.packed(generation: computedGeneration), ordering: .releasing)
        return entry
    }
}
