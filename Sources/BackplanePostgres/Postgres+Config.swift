//
//  Postgres+Config.swift
//  budget-forward-cloud
//
//  Created by David Monagle on 17/9/2024.
//

#if BACKPLANE_POSTGRES

import Configuration
import NIOSSL
import PostgresNIO

extension PostgresClient.Configuration {
    /// Build a `PostgresClient.Configuration` from a `ConfigReader` scope.
    ///
    /// Connection parameters (matching the existing keys):
    /// - `username` (default `"postgres"`), `password` (secret), `database`
    /// - Either `unixSocketPath`, OR `host` (default `"localhost"`) + `port` (default `5432`) +
    ///   TLS knobs at the same scope (`base`, `minimumTLSVersion`, `maximumTLSVersion`, `cipherSuites`)
    ///
    /// Pool + timeout knobs (all optional; absent keys preserve postgres-nio defaults):
    /// - `pool.minimumConnections` (Int; default 0 — postgres-nio default)
    /// - `pool.maximumConnections` (Int; default 20 — postgres-nio default)
    /// - `pool.connectionIdleTimeoutSeconds` (Int; default 60 — postgres-nio default)
    /// - `connectTimeoutSeconds` (Int; default 10 — postgres-nio default)
    /// - `statementTimeoutSeconds` (Int; default unset — when set, sent as the
    ///   `statement_timeout` startup parameter so every session inherits it.
    ///   Use 0 to explicitly disable the GUC for callers that need long-
    ///   running queries; omit the key entirely to inherit the server default.)
    public init(config: ConfigReader) {
        let username = config.string(forKey: "username", default: "postgres")
        let password = config.string(forKey: "password", isSecret: true)
        let database = config.string(forKey: "database")

        if let unixSocketPath = config.string(forKey: "unixSocketPath") {
            self.init(
                unixSocketPath: unixSocketPath, username: username, password: password,
                database: database)
        } else {
            let host = config.string(forKey: "host", default: "localhost")
            let port = config.int(forKey: "port", default: 5432)
            let tls = PostgresClient.Configuration.TLS(config: config)

            self.init(
                host: host, port: port, username: username, password: password, database: database,
                tls: tls)
        }

        applyPoolAndTimeoutOverrides(from: config)
    }

    /// Apply optional pool + timeout config keys to `self.options`. Each key
    /// is optional; absent keys leave the postgres-nio defaults intact.
    ///
    /// Public so apps that construct `PostgresClient.Configuration` directly
    /// (e.g. for legacy reasons) can layer the same env-driven knobs on top.
    public mutating func applyPoolAndTimeoutOverrides(from config: ConfigReader) {
        let pool = config.scoped(to: "pool")
        if let minConns: Int = pool.int(forKey: "minimumConnections") {
            self.options.minimumConnections = minConns
        }
        if let maxConns: Int = pool.int(forKey: "maximumConnections") {
            self.options.maximumConnections = maxConns
        }
        if let idleSeconds: Int = pool.int(forKey: "connectionIdleTimeoutSeconds") {
            self.options.connectionIdleTimeout = .seconds(idleSeconds)
        }
        if let connectSeconds: Int = config.int(forKey: "connectTimeoutSeconds") {
            self.options.connectTimeout = .seconds(connectSeconds)
        }
        // Statement timeout is per-session; postgres accepts it as a startup
        // parameter, so every connection in the pool inherits it without
        // needing a per-checkout SET. Value is milliseconds; "0" disables.
        if let statementSeconds: Int = config.int(forKey: "statementTimeoutSeconds") {
            self.options.additionalStartupParameters.append(
                ("statement_timeout", "\(statementSeconds * 1000)")
            )
        }
    }
}

extension PostgresClient.Configuration.TLS {
    public init(config: ConfigReader) {
        switch config.string(forKey: "base", as: TLSOption.self, default: .disable) {
        case .disable:
            self = .disable
        case .prefer:
            var tlsConfig = NIOSSL.TLSConfiguration.makeClientConfiguration()
            tlsConfig.configure(config)
            self = .prefer(tlsConfig)
        case .require:
            var tlsConfig = NIOSSL.TLSConfiguration.makeClientConfiguration()
            tlsConfig.configure(config)
            self = .require(tlsConfig)
        }
    }
}

extension NIOSSL.TLSConfiguration {
    public mutating func configure(_ config: ConfigReader) {
        if let minimumTLSVersion: NIOSSL.TLSVersion = config.string(forKey: "minimumTLSVersion") {
            self.minimumTLSVersion = minimumTLSVersion
        }

        if let maximumTLSVersion = config.string(
            forKey: "maximumTLSVersion", as: NIOSSL.TLSVersion.self)
        {
            self.maximumTLSVersion = maximumTLSVersion
        }

        if let cipherSuites = config.string(forKey: "cipherSuites") {
            self.cipherSuites = cipherSuites
        }

        // TODO: Important! This needs to be fleshed out to support SSL
    }
}

private enum TLSOption: String {
    case disable
    case prefer
    case require
}

extension TLSVersion: @retroactive RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "tlsv1": self = .tlsv1
        case "tlsv11": self = .tlsv11
        case "tlsv12": self = .tlsv12
        case "tlsv13": self = .tlsv13
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .tlsv1: return "tlsv1"
        case .tlsv11: return "tlsv11"
        case .tlsv12: return "tlsv12"
        case .tlsv13: return "tlsv13"
        }
    }
}

#endif
