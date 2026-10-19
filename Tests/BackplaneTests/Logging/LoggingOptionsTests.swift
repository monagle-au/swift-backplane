//
//  LoggingOptionsTests.swift
//  swift-backplane
//

import ArgumentParser
import Configuration
@testable import Backplane
import Logging
import Testing

/// Build an in-memory `ConfigReader` from a flat `[String: String]`
/// map of dotted-path keys.
private func makeConfig(_ values: [String: String]) async -> ConfigReader {
    var converted: [AbsoluteConfigKey: ConfigValue] = [:]
    for (k, v) in values {
        let key = AbsoluteConfigKey(k.split(separator: ".").map(String.init))
        let content: ConfigContent
        if let i = Int(v) {
            content = .int(i)
        } else if let b = Bool(v) {
            content = .bool(b)
        } else if let d = Double(v) {
            content = .double(d)
        } else {
            content = .string(v)
        }
        converted[key] = ConfigValue(content, isSecret: false)
    }
    return ConfigReader(provider: InMemoryProvider(values: converted))
}

/// Build an in-memory `ConfigReader` whose values are string arrays.
private func makeArrayConfig(_ values: [String: [String]]) -> ConfigReader {
    var converted: [AbsoluteConfigKey: ConfigValue] = [:]
    for (k, v) in values {
        let key = AbsoluteConfigKey(k.split(separator: ".").map(String.init))
        converted[key] = ConfigValue(.stringArray(v), isSecret: false)
    }
    return ConfigReader(provider: InMemoryProvider(values: converted))
}

@Suite("LoggingOptions")
struct LoggingOptionsTests {

    @Test("Defaults: empty when no flags supplied")
    func defaults() throws {
        let opts = try LoggingOptions.parse([])
        #expect(opts.logLevel == nil)
        #expect(opts.format == .auto)
        #expect(opts.resolvedLogLevel == nil)
    }

    @Test("--log-level=debug parses into Logger.Level.debug")
    func logLevelDebug() throws {
        let opts = try LoggingOptions.parse(["--log-level", "debug"])
        #expect(opts.resolvedLogLevel == .debug)
    }

    @Test("--log-level value is matched case-insensitively")
    func logLevelCaseInsensitive() throws {
        let opts = try LoggingOptions.parse(["--log-level", "WARNING"])
        #expect(opts.resolvedLogLevel == .warning)
    }

    @Test("--log-level=garbage resolves to nil so the bootstrap can fall back")
    func logLevelGarbage() throws {
        let opts = try LoggingOptions.parse(["--log-level", "garbage"])
        #expect(opts.resolvedLogLevel == nil)
    }

    @Test("--log-format=json picks the GCP factory")
    func formatJSON() throws {
        let opts = try LoggingOptions.parse(["--log-format", "json"])
        #expect(opts.format == .json)
    }

    @Test("--log-format=text picks the stream factory")
    func formatText() throws {
        let opts = try LoggingOptions.parse(["--log-format", "text"])
        #expect(opts.format == .text)
    }

    // MARK: - merging(from:)

    @Test("merging fills logLevel from config when CLI is silent")
    func mergingFillsLogLevelFromConfig() async throws {
        let opts = try LoggingOptions.parse([])
        let config = await makeConfig(["logging.level": "debug"])
        let merged = opts.merging(from: config.scoped(to: "logging"))
        #expect(merged.resolvedLogLevel == .debug)
    }

    @Test("merging keeps CLI logLevel when both CLI and config set it")
    func mergingCLITakesPrecedenceOverConfig() async throws {
        let opts = try LoggingOptions.parse(["--log-level", "warning"])
        let config = await makeConfig(["logging.level": "debug"])
        let merged = opts.merging(from: config.scoped(to: "logging"))
        #expect(merged.resolvedLogLevel == .warning)
    }

    @Test("merging fills format from config when CLI left it at .auto")
    func mergingFillsFormatFromConfig() async throws {
        let opts = try LoggingOptions.parse([])
        let config = await makeConfig(["logging.format": "json"])
        let merged = opts.merging(from: config.scoped(to: "logging"))
        #expect(merged.format == .json)
    }

    @Test("merging keeps CLI format when CLI explicitly chose one")
    func mergingCLIFormatTakesPrecedence() async throws {
        let opts = try LoggingOptions.parse(["--log-format", "text"])
        let config = await makeConfig(["logging.format": "json"])
        let merged = opts.merging(from: config.scoped(to: "logging"))
        #expect(merged.format == .text)
    }

    @Test("merging is a no-op when neither CLI nor config sets anything")
    func mergingNoOpWhenSilent() async throws {
        let opts = try LoggingOptions.parse([])
        let config = await makeConfig([:])
        let merged = opts.merging(from: config.scoped(to: "logging"))
        #expect(merged.resolvedLogLevel == nil)
        #expect(merged.format == .auto)
    }

    // MARK: - --log-rule / logging.rules

    @Test("Defaults: no log rules")
    func defaultLogRules() throws {
        let opts = try LoggingOptions.parse([])
        #expect(opts.logRules.isEmpty)
        #expect(opts.resolvedLogRules.isEmpty)
    }

    @Test("--log-rule is repeatable and parses label[:subsystem]=level")
    func logRuleRepeatable() throws {
        let opts = try LoggingOptions.parse([
            "--log-rule", "acumen.agent=debug",
            "--log-rule", "acumen.agent.matter-agent:mrp=trace",
        ])
        #expect(opts.resolvedLogRules == [
            LogLevelRule(labelPrefix: "acumen.agent", level: .debug),
            LogLevelRule(labelPrefix: "acumen.agent.matter-agent", subsystem: "mrp", level: .trace),
        ])
    }

    @Test("a malformed --log-rule is a validation error")
    func logRuleMalformed() {
        #expect(throws: (any Error).self) {
            try LoggingOptions.parse(["--log-rule", "acumen"])
        }
        #expect(throws: (any Error).self) {
            try LoggingOptions.parse(["--log-rule", "acumen=loud"])
        }
    }

    @Test("merging prepends logging.rules from config; CLI rules come after and win per rule")
    func mergingRules() throws {
        let opts = try LoggingOptions.parse(["--log-rule", "acumen=trace"])
        let config = makeArrayConfig(["logging.rules": ["acumen=debug", "hap-bridge=warning"]])
        let merged = opts.merging(from: config.scoped(to: "logging"))
        #expect(merged.logRules == ["acumen=debug", "hap-bridge=warning", "acumen=trace"])

        let table = LogLevelTable(baseLevel: .info, rules: merged.resolvedLogRules)
        #expect(table.level(for: "acumen.engine", subsystem: nil) == .trace)
        #expect(table.level(for: "hap-bridge", subsystem: nil) == .warning)
    }

    @Test("merging takes logging.rules when CLI supplied none")
    func mergingRulesFromConfigOnly() throws {
        let opts = try LoggingOptions.parse([])
        let config = makeArrayConfig(["logging.rules": ["cloud=debug"]])
        let merged = opts.merging(from: config.scoped(to: "logging"))
        #expect(merged.resolvedLogRules == [LogLevelRule(labelPrefix: "cloud", level: .debug)])
    }

    @Test("malformed config rules are dropped by resolvedLogRules")
    func malformedConfigRulesDropped() throws {
        let opts = try LoggingOptions.parse([])
        let config = makeArrayConfig(["logging.rules": ["cloud=debug", "nonsense"]])
        let merged = opts.merging(from: config.scoped(to: "logging"))
        #expect(merged.logRules.count == 2)
        #expect(merged.resolvedLogRules == [LogLevelRule(labelPrefix: "cloud", level: .debug)])
    }

    @Test("a malformed config rule is reported in rejectedLogRules and absent from resolvedLogRules")
    func malformedRuleRejected() throws {
        let opts = try LoggingOptions.parse([])
        let config = makeArrayConfig(["logging.rules": ["cloud=debug", "acumen.agent=debg"]])
        let merged = opts.merging(from: config.scoped(to: "logging"))
        #expect(merged.rejectedLogRules == ["acumen.agent=debg"])
        #expect(merged.resolvedLogRules == [LogLevelRule(labelPrefix: "cloud", level: .debug)])
    }

    @Test("empty and whitespace-only config rules are neither resolved nor rejected")
    func emptyRulesIgnored() throws {
        let opts = try LoggingOptions.parse([])
        let config = makeArrayConfig(["logging.rules": ["cloud=debug", "", "  "]])
        let merged = opts.merging(from: config.scoped(to: "logging"))
        #expect(merged.logRules.count == 3)
        #expect(merged.rejectedLogRules.isEmpty)
        #expect(merged.resolvedLogRules == [LogLevelRule(labelPrefix: "cloud", level: .debug)])
    }
}
