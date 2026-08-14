//
//  PostgresConfigTests.swift
//  swift-backplane
//

#if BACKPLANE_POSTGRES

import Configuration
import BackplanePostgres
import PostgresNIO
import Testing

@Suite("PostgresClient.Configuration(config:)")
struct PostgresConfigTests {

    /// Build an in-memory `ConfigReader` from a flat `[String: String]` map
    /// of dotted-path keys. Values that parse as `Int` are stored as `.int`
    /// so `config.int(forKey:)` finds them; everything else as `.string`.
    /// `InMemoryProvider` matches on the stored content's typed shape, not
    /// on a string-coerced view.
    private func makeConfig(_ values: [String: String]) async -> ConfigReader {
        var converted: [AbsoluteConfigKey: ConfigValue] = [:]
        for (k, v) in values {
            let key = AbsoluteConfigKey(k.split(separator: ".").map(String.init))
            let content: ConfigContent
            if let i = Int(v) {
                content = .int(i)
            } else {
                content = .string(v)
            }
            converted[key] = ConfigValue(content, isSecret: false)
        }
        return ConfigReader(provider: InMemoryProvider(values: converted))
    }

    // MARK: - Connection-mode dispatch

    @Test("unixSocketPath path takes precedence over host/port when both present")
    func socketWinsOverHostPort() async {
        let config = await makeConfig([
            "postgres.unixSocketPath": "/cloudsql/proj:region:inst/.s.PGSQL.5432",
            "postgres.host": "ignored.example",
            "postgres.port": "5433",
            "postgres.username": "user",
            "postgres.password": "pw",
            "postgres.database": "db",
        ])
        let pgConfig = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
        #expect(pgConfig.unixSocketPath != nil)
        #expect(pgConfig.host == nil)
    }

    @Test("host + port path used when no unix socket")
    func hostPortPath() async {
        let config = await makeConfig([
            "postgres.host": "db.internal",
            "postgres.port": "5444",
            "postgres.username": "user",
            "postgres.password": "pw",
            "postgres.database": "mydb",
        ])
        let pgConfig = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
        #expect(pgConfig.host == "db.internal")
        #expect(pgConfig.port == 5444)
        #expect(pgConfig.unixSocketPath == nil)
    }

    // MARK: - Pool / timeout overrides

    @Test("absent pool keys leave postgres-nio defaults")
    func defaultsPreserved() async {
        let config = await makeConfig([
            "postgres.host": "db.internal",
            "postgres.username": "u",
            "postgres.password": "p",
            "postgres.database": "d",
        ])
        let pgConfig = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
        // postgres-nio defaults from Pool/PostgresClient.swift:
        #expect(pgConfig.options.minimumConnections == 0)
        #expect(pgConfig.options.maximumConnections == 20)
        #expect(pgConfig.options.connectionIdleTimeout == .seconds(60))
        #expect(pgConfig.options.connectTimeout == .seconds(10))
        #expect(pgConfig.options.additionalStartupParameters.isEmpty)
    }

    @Test("pool sizing keys flow through to options")
    func poolSizingApplied() async {
        let config = await makeConfig([
            "postgres.host": "x",
            "postgres.username": "u",
            "postgres.password": "p",
            "postgres.database": "d",
            "postgres.pool.minimumConnections": "2",
            "postgres.pool.maximumConnections": "10",
            "postgres.pool.connectionIdleTimeoutSeconds": "120",
        ])
        let pgConfig = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
        #expect(pgConfig.options.minimumConnections == 2)
        #expect(pgConfig.options.maximumConnections == 10)
        #expect(pgConfig.options.connectionIdleTimeout == .seconds(120))
    }

    @Test("connectTimeoutSeconds applied")
    func connectTimeoutApplied() async {
        let config = await makeConfig([
            "postgres.host": "x",
            "postgres.username": "u",
            "postgres.password": "p",
            "postgres.database": "d",
            "postgres.connectTimeoutSeconds": "5",
        ])
        let pgConfig = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
        #expect(pgConfig.options.connectTimeout == .seconds(5))
    }

    @Test("statementTimeoutSeconds added as startup parameter in milliseconds")
    func statementTimeoutAsStartupParameter() async {
        let config = await makeConfig([
            "postgres.host": "x",
            "postgres.username": "u",
            "postgres.password": "p",
            "postgres.database": "d",
            "postgres.statementTimeoutSeconds": "10",
        ])
        let pgConfig = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
        let params = pgConfig.options.additionalStartupParameters
        #expect(params.count == 1)
        #expect(params.first?.0 == "statement_timeout")
        #expect(params.first?.1 == "10000")
    }

    @Test("statementTimeoutSeconds=0 emits literal '0' (Postgres syntax for disabled)")
    func statementTimeoutZeroDisables() async {
        let config = await makeConfig([
            "postgres.host": "x",
            "postgres.username": "u",
            "postgres.password": "p",
            "postgres.database": "d",
            "postgres.statementTimeoutSeconds": "0",
        ])
        let pgConfig = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
        #expect(pgConfig.options.additionalStartupParameters.first?.1 == "0")
    }

    @Test("applyPoolAndTimeoutOverrides is callable on a manually-built config")
    func manualOverrideApplyable() async {
        var pgConfig = PostgresClient.Configuration(
            host: "x", port: 5432, username: "u", password: "p", database: "d",
            tls: .disable
        )
        let config = await makeConfig([
            "postgres.pool.maximumConnections": "30",
        ])
        pgConfig.applyPoolAndTimeoutOverrides(from: config.scoped(to: "postgres"))
        #expect(pgConfig.options.maximumConnections == 30)
    }

    // MARK: - TLS (`tls.` sub-scope)

    /// `PostgresClient.Configuration.TLS` exposes no public
    /// introspection, so reflect its internal `base` enum to observe the
    /// resolved mode and the `NIOSSL.TLSConfiguration` it carries.
    private func tlsCase(
        of pgConfig: PostgresClient.Configuration
    ) -> (mode: String, tlsConfig: TLSConfiguration?) {
        guard
            let base = Mirror(reflecting: pgConfig.tls).children
                .first(where: { $0.label == "base" })?.value
        else { return ("<no base>", nil) }
        if let payload = Mirror(reflecting: base).children.first {
            return (payload.label ?? "<unlabelled>", payload.value as? TLSConfiguration)
        }
        return (String(describing: base), nil)
    }

    @Test("absent tls keys default to disable")
    func tlsDefaultsToDisable() async {
        let config = await makeConfig([
            "postgres.host": "x",
            "postgres.username": "u",
            "postgres.password": "p",
            "postgres.database": "d",
        ])
        let pgConfig = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
        #expect(tlsCase(of: pgConfig).mode == "disable")
    }

    @Test("tls.mode=prefer builds a prefer configuration")
    func tlsPrefer() async {
        let config = await makeConfig([
            "postgres.host": "x",
            "postgres.username": "u",
            "postgres.password": "p",
            "postgres.database": "d",
            "postgres.tls.mode": "prefer",
        ])
        let pgConfig = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
        let (mode, tlsConfig) = tlsCase(of: pgConfig)
        #expect(mode == "prefer")
        #expect(tlsConfig != nil)
    }

    @Test("tls.mode=require applies nested version and cipher keys")
    func tlsRequireWithKnobs() async {
        let config = await makeConfig([
            "postgres.host": "x",
            "postgres.username": "u",
            "postgres.password": "p",
            "postgres.database": "d",
            "postgres.tls.mode": "require",
            "postgres.tls.minimumVersion": "tlsv12",
            "postgres.tls.maximumVersion": "tlsv13",
            "postgres.tls.cipherSuites": "ECDHE-RSA-AES256-GCM-SHA384",
        ])
        let pgConfig = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
        let (mode, tlsConfig) = tlsCase(of: pgConfig)
        #expect(mode == "require")
        #expect(tlsConfig?.minimumTLSVersion == .tlsv12)
        #expect(tlsConfig?.maximumTLSVersion == .tlsv13)
        #expect(tlsConfig?.cipherSuites == "ECDHE-RSA-AES256-GCM-SHA384")
    }

    @Test("legacy flat TLS keys (pre-2.0) are not read")
    func legacyFlatTLSKeysIgnored() async {
        let config = await makeConfig([
            "postgres.host": "x",
            "postgres.username": "u",
            "postgres.password": "p",
            "postgres.database": "d",
            "postgres.base": "require",
            "postgres.minimumTLSVersion": "tlsv12",
        ])
        let pgConfig = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
        #expect(tlsCase(of: pgConfig).mode == "disable")
    }

    @Test("TLSConfiguration.configure reads keys at the reader's own scope")
    func configureAppliesKnobs() async {
        let config = await makeConfig([
            "tls.minimumVersion": "tlsv13",
        ])
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.configure(config.scoped(to: "tls"))
        #expect(tlsConfig.minimumTLSVersion == .tlsv13)
    }
}

#endif
