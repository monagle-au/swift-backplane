//
//  PostgresQuery+multiValueRow.swift
//  budget-forward-cloud
//
//  Created by David Monagle on 21/1/2025.
//

#if BACKPLANE_POSTGRES

import PostgresNIO
import Foundation

/// Helpers for building multi-row INSERT (or similar) queries with bound parameters.
///
/// This enables constructing queries like:
///   INSERT INTO table (col1, col2) VALUES ($1, $2), ($3, $4), ...
/// while collecting the corresponding `PostgresBindings` for safe parameterization.
extension PostgresQuery {
    /// Builds a `PostgresQuery` for a multi-row VALUES clause from a sequence of elements.
    ///
    /// You provide:
    /// - a sequence of values to insert,
    /// - a closure that maps each element into an array of `PostgresData` (one per column),
    /// - and a closure that receives the generated placeholder list (e.g. "($1,$2),($3,$4)")
    ///   and returns the full SQL string (e.g. "INSERT INTO t (a,b) VALUES \(placeholders)").
    ///
    /// The function will:
    /// - Generate the correctly offset placeholders for each row.
    /// - Accumulate all bindings in the order of the placeholders.
    /// - Return a `PostgresQuery` with `unsafeSQL` set to your returned SQL string and
    ///   `binds` containing the accumulated bindings.
    ///
    /// Important:
    /// - The `unsafeSQL` closure should only interpolate the provided `valuePlaceholders`
    ///   string. Do not interpolate untrusted input directly into the SQL; use bindings.
    ///
    /// - Parameters:
    ///   - sequence: The sequence of input elements (one row per element).
    ///   - unsafeSQL: A closure that takes the generated placeholders string and returns
    ///                the complete SQL statement to execute.
    ///   - bindings: A closure that converts one element into the array of `PostgresData`
    ///               values to bind for that row (order must match your column list).
    /// - Returns: A `PostgresQuery` ready to be executed with the generated SQL and bindings.
    public static func multiValueRowQuery<S>(
        from sequence: S,
        unsafeSQL: (_ valuePlaceholders: String) -> String,
        bindings: (S.Element) -> [PostgresData]
    ) -> PostgresQuery where S : Sequence {
        let inputs = sequence.createPostgresMultiValuePlaceholdersAndBindings(bindings)
        let sql = unsafeSQL(inputs.placeholders)
        return PostgresQuery(unsafeSQL: sql, binds: inputs.bindings)
    }
}

fileprivate extension Sequence {
    /// Creates a comma-separated list of VALUES tuples with correctly offset placeholders,
    /// along with the accumulated `PostgresBindings`.
    ///
    /// For a sequence of N elements where each element yields M bound values, this will
    /// produce a placeholder string like:
    ///   "($1,$2,...,$M),($(M+1),...,$(2M)), ..."
    /// and fill the bindings in the same order.
    ///
    /// - Parameter makeBindings: A closure mapping each element to its array of `PostgresData`.
    /// - Returns: A tuple containing:
    ///   - placeholders: String suitable for injection into a VALUES clause.
    ///   - bindings: Accumulated `PostgresBindings` matching the placeholder order.
    func createPostgresMultiValuePlaceholdersAndBindings(
        _ makeBindings: (Element) -> [PostgresData]
    ) -> (placeholders: String, bindings: PostgresBindings) {
        var placeholders = [String]()
        var bindings = PostgresBindings()

        for value in self {
            let offset = bindings.count

            let pgData = makeBindings(value)
            let placeholderRow = (offset + 1...offset + pgData.count)
                .map { "$\($0)" }
                .joined(separator: ",")
            placeholders.append("(\(placeholderRow))")

            for datum in pgData {
                bindings.append(datum)
            }
        }
        return (placeholders: placeholders.joined(separator: ","), bindings: bindings)
    }
}

#endif
