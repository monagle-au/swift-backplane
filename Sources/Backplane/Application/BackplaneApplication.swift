//
//  BackplaneApplication.swift
//  swift-backplane
//

import ArgumentParser
import Configuration

/// The main entry point protocol for a Backplane application.
///
/// Conform to this protocol to define your application's identity,
/// service descriptors, and root CLI command in a single place. Mark
/// the conforming type with `@main` to make it the program entry point.
///
/// For a single-command application, set `RootCommand` directly to a
/// ``BackplaneCommand`` conformance:
///
/// ```swift
/// @main
/// struct MyApp: BackplaneApplication {
///     typealias RootCommand = ServeCommand
///     static let identifier = "my-app"
///
///     static func services() -> [EntryDescriptor] {
///         [
///             EntryDescriptor(databaseKey) { context in
///                 PostgresService(logger: context.logger)
///             },
///         ]
///     }
/// }
/// ```
///
/// For multiple commands, declare a plain `AsyncParsableCommand` as your
/// root and use ArgumentParser's `CommandConfiguration` normally:
///
/// ```swift
/// struct AppCommand: AsyncParsableCommand {
///     static var configuration = CommandConfiguration(
///         subcommands: [ServeCommand.self, MigrateCommand.self],
///         defaultSubcommand: ServeCommand.self
///     )
/// }
///
/// @main
/// struct MyApp: BackplaneApplication {
///     typealias RootCommand = AppCommand
///     static let identifier = "my-app"
///
///     static func services() -> [EntryDescriptor] { [ ... ] }
/// }
/// ```
public protocol BackplaneApplication: Sendable {
    /// A unique identifier for this application.
    ///
    /// Used as the default logger label, tracing service name, and in
    /// diagnostic messages.
    static var identifier: String { get }

    /// Produces the full set of service descriptors the application may
    /// need. Commands select which subset boots via their
    /// ``BackplaneCommand/requiredServices``.
    ///
    /// Called once during startup, before any command runs.
    static func services() -> [EntryDescriptor]

    /// Builds the ``ConfigReader`` used by all commands in this
    /// application.
    ///
    /// Override to customise the configuration stack — for example, to
    /// load values from a `.env` file or inject in-memory defaults:
    ///
    /// ```swift
    /// static func configReader(for environment: Environment) async throws -> ConfigReader {
    ///     await ConfigReader(providers: [
    ///         try EnvironmentVariablesProvider(environmentFilePath: ".env", allowMissing: true),
    ///         InMemoryProvider(values: ["postgres.database": .init(.string("myapp_\(environment.name)"), isSecret: false)]),
    ///     ])
    /// }
    /// ```
    ///
    /// The default implementation reads only from process environment
    /// variables.
    ///
    /// - Parameter environment: The resolved runtime environment
    ///   (e.g. `.development`, `.production`).
    /// - Returns: A configured ``ConfigReader`` for the application.
    static func configReader(for environment: Environment) async throws -> ConfigReader

    /// The root CLI command for this application.
    ///
    /// This type is the ArgumentParser entry point. For a single-command
    /// app, set this to a ``BackplaneCommand`` directly. For multiple
    /// commands, use a plain `AsyncParsableCommand` with
    /// `CommandConfiguration.subcommands`.
    associatedtype RootCommand: AsyncParsableCommand
}

extension BackplaneApplication {
    /// Entry point called by `@main`. Delegates directly to
    /// `RootCommand.main()`.
    public static func main() async {
        await RootCommand.main()
    }

    /// Default implementation — reads from process environment variables
    /// only.
    public static func configReader(for environment: Environment) async throws -> ConfigReader {
        ConfigReader(provider: EnvironmentVariablesProvider())
    }
}
