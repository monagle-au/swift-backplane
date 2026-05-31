//
//  PostgresData+optional.swift
//  budget-forward-cloud
//
//  Created by David Monagle on 4/5/2025.
//

#if BACKPLANE_POSTGRES

import Foundation
import PostgresNIO

/// Convenience helpers for creating `PostgresData` from optional Swift values.
///
/// These functions convert optional values into `PostgresData`, returning `.null` when
/// the input is `nil`. This is useful when binding parameters for SQL queries where a
/// missing value should map to `NULL`.
extension PostgresData {
    /// Creates a `PostgresData` from an optional `UUID`.
    ///
    /// - Parameter value: The optional UUID to convert.
    /// - Returns: `.init(uuid:)` when `value` is non-nil; otherwise `.null`.
    public static func optional(uuid value: UUID?) -> PostgresData {
        value.map { PostgresData(uuid: $0) } ?? .null
    }
    
    /// Creates a `PostgresData` from an optional `Date`.
    ///
    /// - Parameter value: The optional Date to convert.
    /// - Returns: `.init(date:)` when `value` is non-nil; otherwise `.null`.
    public static func optional(date value: Date?) -> PostgresData {
        value.map { PostgresData(date: $0) } ?? .null
    }
    
    /// Creates a `PostgresData` from an optional `Int`.
    ///
    /// - Parameter value: The optional Int to convert.
    /// - Returns: `.init(int:)` when `value` is non-nil; otherwise `.null`.
    public static func optional(int value: Int?) -> PostgresData {
        value.map { PostgresData(int: $0) } ?? .null
    }
}

#endif
