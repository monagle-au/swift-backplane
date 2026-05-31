//
//  PGReflectedError.swift
//  budget-forward-cloud
//
//  Created by David Monagle on 14/9/2024.
//

#if BACKPLANE_POSTGRES

import Logging
import PostgresNIO

public protocol PGReflectableError<BaseError>: Error {
    associatedtype BaseError: Error
    var reflectedError: BaseError { get }
}

extension PGReflectableError {
    public var reflectedErrorString: String {
        String(reflecting: self)
    }
}

extension PostgresNIO.PSQLError: PGReflectableError {
    public var reflectedError: PGReflectedError<PSQLError.Code> {
        .init(code: self.code, message: reflectedErrorString)
    }
}

extension PostgresNIO.PostgresDecodingError: PGReflectableError {
    public var reflectedError: PGReflectedError<PostgresDecodingError.Code> {
        .init(code: self.code, message: reflectedErrorString)
    }
}

/// A lightweight wrapper for Postgres-related errors, carrying a stable code and message.
public struct PGReflectedError<Code: Sendable>: Error {
    let code: Code
    let message: String
    
    init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - General-purpose wrappers

#if DEBUG

/// DEBUG-only: Wraps an async throwing operation, and if a PostgreSQL-related error occurs
/// (i.e., one conforming to `PGReflectableError`), logs a concise, reflected message
/// and rethrows the original error.
public func logUnwrappedPostgreSQLErrors<T>(
    logger: Logger? = nil,
    operation: () async throws -> T
) async rethrows -> T {
    do {
        return try await operation()
    } catch let pgError as any PGReflectableError {
        if let logger {
            logger.error("\(String(describing: type(of: pgError))): \(pgError.reflectedErrorString)")
        }
        throw pgError
    }
}

/// DEBUG-only: Synchronous sibling of `logUnwrappedPostgreSQLErrors(logger:operation:)`.
public func logUnwrappedPostgreSQLErrors<T>(
    logger: Logger? = nil,
    operation: () throws -> T
) rethrows -> T {
    do {
        return try operation()
    } catch let pgError as any PGReflectableError {
        if let logger {
            logger.error("\(String(describing: type(of: pgError))): \(pgError.reflectedErrorString)")
        }
        throw pgError
    }
}

#else

/// RELEASE: Pass-through async variant with no logging or extra overhead.
public func logUnwrappedPostgreSQLErrors<T>(
    logger: Logger? = nil,
    operation: () async throws -> T
) async rethrows -> T {
    try await operation()
}

/// RELEASE: Pass-through sync variant with no logging or extra overhead.
public func logUnwrappedPostgreSQLErrors<T>(
    logger: Logger? = nil,
    operation: () throws -> T
) rethrows -> T {
    try operation()
}

#endif

#endif
