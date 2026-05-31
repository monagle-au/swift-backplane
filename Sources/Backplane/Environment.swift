//
//  Environment.swift
//  budget-forward-cloud
//
//  Created by David Monagle on 3/9/2024.
//

import Foundation
import ArgumentParser

/// A lightweight representation of the application's deployment environment
/// (e.g., development, testing, production).
///
/// Environment instances are value types identified by a `name`. Common presets
/// are provided for convenience, but you can construct custom environments with
/// arbitrary names as needed (e.g., "staging", "preview").
///
/// This type is `Sendable` and `Equatable`, making it safe to use across
/// concurrency boundaries and easy to compare in tests and control flow.
public struct Environment: Sendable, Equatable {
    /// The environment name (e.g., "development", "testing", "production").
    public let name: String

    /// Creates a new `Environment` with the given name.
    ///
    /// - Parameter name: The environment name.
    public init(name: String) {
        self.name = name
    }
    
    /// Creates a new `Environment` from parsed CLI arguments.
    ///
    /// returns nil if environment is not set in the arguments
    ///
    /// - Parameter arguments: Parsed command-line arguments.
    public init?(arguments: Arguments) {
        guard let env = arguments.environment else { return nil }
        self.init(name: env)
    }

    // MARK: - Presets

    /// A production environment.
    public static var production: Environment { .init(name: "production") }

    /// A development environment, suitable for local development.
    public static var development: Environment { .init(name: "development") }

    /// A testing environment, useful for automated tests.
    public static var testing: Environment { .init(name: "testing") }

    // MARK: - Env Accessors

    /// Returns the value for the specified key from the current process environment.
    ///
    /// - Parameter key: The environment variable name.
    /// - Returns: The value of the environment variable if present, otherwise `nil`.
    public static func get(_ key: String) -> String? {
        return ProcessInfo.processInfo.environment[key]
    }

    /// Provides a new `Process` instance representing the current process.
    ///
    /// Note: This returns a fresh `Process` object each time. It can be used
    /// to configure and launch subprocesses if needed.
    public static var process: Process {
        return Process()
    }
    
    // MARK: - Equatable

    /// Returns `true` if both environments share the same name.
    ///
    /// - Parameters:
    ///   - lhs: Left-hand side environment.
    ///   - rhs: Right-hand side environment.
    /// - Returns: `true` when `lhs.name == rhs.name`.
    public static func ==(lhs: Environment, rhs: Environment) -> Bool {
        return lhs.name == rhs.name
    }
}

extension Environment {
    /// Command-line arguments for configuring an `Environment`.
    ///
    /// This type is compatible with the `ArgumentParser` package and can be used
    /// to parse the environment from CLI input. Any unrecognized arguments are
    /// captured in `unknowns`.
    public struct Arguments: ParsableArguments, Sendable {
        public init() {
        }
        
        /// The environment in which to operate (e.g., "development", "production").
        @Argument(help: "The environment in which to operate.")
        public var environment: String?
        
        /// Captures any unrecognized arguments for later inspection.
        @Argument(parsing: .allUnrecognized)
        var unknowns: [String] = []
    }
}

extension Environment {
    /// Appends the environment name as a suffix to the provided string,
    /// separated by an underscore.
    ///
    /// Example:
    ///   Environment.production.addSuffix("DATABASE") // "DATABASE_production"
    ///
    /// - Parameter string: The base string to suffix.
    /// - Returns: A new string in the format `"<string>_<environment.name>"`.
    public func addSuffix(_ string: String) -> String {
        "\(string)_\(self.name)"
    }
}
