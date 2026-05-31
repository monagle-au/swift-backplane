//
//  CommandExecutionService.swift
//  swift-backplane
//

import ServiceLifecycle

/// An internal ``Service`` adapter that wraps an async closure so it can
/// participate in a ``ServiceGroup``.
///
/// `CommandExecutionService` is created by ``ApplicationRunner`` when a
/// ``TaskCommand`` provides an `execute(with:)` implementation. The closure
/// is run as a service inside the group; when it completes (or throws), the
/// group responds according to the configured termination behaviour
/// (`.gracefullyShutdownGroup` for successful task commands).
struct CommandExecutionService: Service, Sendable {
    /// The async closure to execute.
    let execute: @Sendable () async throws -> Void

    /// Runs the wrapped closure.
    ///
    /// The method simply awaits the closure, propagating any thrown errors to
    /// the ``ServiceGroup``.
    func run() async throws {
        try await execute()
    }
}
