//
//  LoggerMetaDataValue+toString.swift
//  EnergyDB
//
//  Created by David Monagle on 25/6/2025.
//

import Foundation
import Logging

/// Convenience helpers for creating `Logger.MetadataValue` entries from arbitrary values.
///
/// These helpers make it easier to attach rich values to log metadata by converting them
/// to the appropriate `.string` representation, which is what `swift-log` expects for
/// human-readable metadata.
///
/// Usage:
/// - `Logger.MetadataValue.custom(someCustomStringConvertible)`
///   Uses the value's `description` from `CustomStringConvertible`.
/// - `Logger.MetadataValue.describe(anyValue)`
///   Uses `String(describing:)` to produce a best-effort textual representation.
extension Logger.MetadataValue {
    /// Creates a `.string` metadata value using a value's `CustomStringConvertible.description`.
    ///
    /// Prefer this initializer when the value conforms to `CustomStringConvertible`,
    /// because it uses the value's intended textual representation.
    ///
    /// - Parameter value: A value conforming to `CustomStringConvertible`.
    /// - Returns: A `Logger.MetadataValue.string` containing `value.description`.
    static public func custom<V>(_ value: V) -> Self where V : CustomStringConvertible {
        .string(value.description)
    }
    
    /// Creates a `.string` metadata value using `String(describing:)` on any value.
    ///
    /// This is a fallback for values that may not conform to `CustomStringConvertible`.
    /// It uses Swift's general-purpose description which may include type information.
    ///
    /// - Parameter value: Any value to be described.
    /// - Returns: A `Logger.MetadataValue.string` containing `String(describing: value)`.
    static public func describe<V>(_ value: V) -> Self {
        .string(String(describing: value))
    }
}
