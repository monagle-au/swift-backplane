//
//  PostgresMigrator.swift
//  budget-forward-cloud
//
//  Created by David Monagle on 5/9/2024.
//

#if BACKPLANE_POSTGRES

import PostgresNIO

public enum PostgresMigrator {
    static func ensureMigrationTable(on client: PostgresClient, logger: Logger) async throws {
        logger.info("Ensuring migration table exists")
        try await client.query(
            """
            CREATE TABLE IF NOT EXISTS _migrations (
                name VARCHAR UNIQUE PRIMARY KEY,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );
            """
            , logger: logger
        )
    }
    
    static func insertMigrationRow(_ migration: PostgresMigration, on connection: PostgresConnection, logger: Logger) async throws {
        logger.info("Inserting migration for \(String(reflecting: migration))")
        try await connection.query(
            """
            INSERT INTO _migrations (name) VALUES (\(migration.name))
            """
            , logger: logger
        )
    }

    static func checkMigrationRow(_ migration: PostgresMigration, on client: PostgresClient, logger: Logger) async throws -> Bool {
        let rows = try await client.query(
            """
            SELECT EXISTS(SELECT 1 FROM _migrations WHERE name=\(migration.name))
            """
            , logger: logger
        )

        let decoded = rows.decode(Bool.self)
        let result = try await decoded.first(where: { _ in true })
        return result ?? false
    }
    

    public static func migrate(_ migrations: [any PostgresMigration], on client: PostgresClient, logger: Logger) async throws {
        try await self.ensureMigrationTable(on: client, logger: logger)
        // TODO: Lock the database or _migrations table
        for migration in migrations {
            guard try await !checkMigrationRow(migration, on: client, logger: logger) else {
                logger.debug("migration '\(migration.name)' has already been applied. skipping.")
                continue
            }
            logger.info("applying migration '\(migration.name)'")
            try await client.withTransaction(logger: logger) { connection in
                for query in migration.queries {
                    try await connection.query(query, logger: logger)
                }
                try await insertMigrationRow(migration, on: connection, logger: logger)
            }
        }
    }
}

#endif
