//
//  LogLevelRule.swift
//  swift-backplane
//

import Foundation
import Logging

/// One entry in a ``LogLevelTable``.
///
/// Loggers whose label starts with ``labelPrefix`` log at ``level``.
/// When ``subsystem`` is set, the rule applies only to messages whose
/// subsystem metadata (see ``LogLevelTable/subsystemKeys``) equals it.
/// A `nil` subsystem, or `"*"` (normalised to `nil`), applies to every
/// message from the label. A rule with an ``expiresAt`` in the past is
/// ignored and pruned from the table.
///
/// The textual form, used by `--log-rule` and the `logging.rules` config
/// key, is `label[:subsystem]=level`:
///
/// ```
/// acumen.agent=debug
/// acumen.agent.matter-agent:mrp=trace
/// matter:*=info
/// ```
public struct LogLevelRule: Sendable, Hashable, Codable, CustomStringConvertible {

    /// The subsystem spelling that means "any subsystem". Normalised to `nil`.
    public static let anySubsystem = "*"

    /// Plain string prefix matched against the logger label (`hasPrefix`).
    public let labelPrefix: String

    /// The subsystem this rule is limited to, or `nil` for any.
    public let subsystem: String?

    /// The minimum level messages matching this rule are emitted at.
    public let level: Logger.Level

    /// When set, the rule stops applying at this instant.
    public let expiresAt: Date?

    public init(labelPrefix: String, subsystem: String? = nil, level: Logger.Level, expiresAt: Date? = nil) {
        self.labelPrefix = labelPrefix
        self.subsystem = subsystem == Self.anySubsystem ? nil : subsystem
        self.level = level
        self.expiresAt = expiresAt
    }

    /// Parse `label[:subsystem]=level`. Splits on the last `=`, then on the
    /// first `:` of the selector; trims whitespace; matches the level
    /// case-insensitively against `Logger.Level.rawValue`.
    public init(parsing text: String) throws(ParseError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equals = trimmed.lastIndex(of: "=") else { throw .missingLevel(text) }
        let selector = trimmed[..<equals]
        let rawLevel = trimmed[trimmed.index(after: equals)...]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !rawLevel.isEmpty else { throw .missingLevel(text) }
        guard let level = Logger.Level(rawValue: rawLevel) else { throw .unknownLevel(text) }

        let label: String
        let subsystem: String?
        if let colon = selector.firstIndex(of: ":") {
            label = selector[..<colon].trimmingCharacters(in: .whitespaces)
            let rawSubsystem = selector[selector.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !rawSubsystem.isEmpty else { throw .emptySubsystem(text) }
            subsystem = rawSubsystem
        } else {
            label = selector.trimmingCharacters(in: .whitespaces)
            subsystem = nil
        }
        guard !label.isEmpty else { throw .emptyLabel(text) }
        self.init(labelPrefix: label, subsystem: subsystem, level: level)
    }

    /// `true` once `date` has reached ``expiresAt``.
    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// The rule in `label[:subsystem]=level` form. ``expiresAt`` is not part
    /// of the textual syntax and is omitted.
    public var description: String {
        if let subsystem {
            return "\(labelPrefix):\(subsystem)=\(level.rawValue)"
        }
        return "\(labelPrefix)=\(level.rawValue)"
    }

    /// Why a textual rule was rejected. Each case carries the original text.
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingLevel(String)
        case unknownLevel(String)
        case emptyLabel(String)
        case emptySubsystem(String)

        public var description: String {
            switch self {
            case .missingLevel(let text): "log rule '\(text)' has no '=level'"
            case .unknownLevel(let text): "log rule '\(text)' names an unknown level (trace, debug, info, notice, warning, error, critical)"
            case .emptyLabel(let text): "log rule '\(text)' has an empty label"
            case .emptySubsystem(let text): "log rule '\(text)' has an empty subsystem after ':'"
            }
        }
    }
}

extension LogLevelRule {
    /// A rule's slot in a table: setting a rule with the same identity
    /// replaces the existing one.
    struct Identity: Hashable, Sendable {
        let labelPrefix: String
        let subsystem: String?
    }

    var identity: Identity { Identity(labelPrefix: labelPrefix, subsystem: subsystem) }

    /// Re-applies `*` normalisation. Decoded rules bypass `init`, so the
    /// table normalises everything it stores.
    var normalized: LogLevelRule {
        LogLevelRule(labelPrefix: labelPrefix, subsystem: subsystem, level: level, expiresAt: expiresAt)
    }
}
