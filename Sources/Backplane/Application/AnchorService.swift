//
//  AnchorService.swift
//  swift-backplane
//

import ServiceLifecycle

// MARK: - AnchorService

/// A no-op persistent `ServiceLifecycle.Service` that sleeps until
/// cancelled.
///
/// Useful for ``BootstrapPlan/lifecycleServices`` entries that need to
/// participate in the outer `ServiceGroup` lifetime but have no
/// substantive work to do beyond an optional cleanup hook
/// (`init(onShutdown:)`).
///
/// The `init(onShutdown:)` overload runs an async cleanup closure
/// after the surrounding task is cancelled and before the cancellation
/// re-raises:
///
/// ```swift
/// AnchorService {
///     try? await httpClient.shutdown()
/// }
/// ```
public struct AnchorService: Service, Sendable {

    private let onShutdown: (@Sendable () async -> Void)?

    /// Pure-anchor variant — sleeps until cancelled, no cleanup.
    public init() {
        self.onShutdown = nil
    }

    /// Cleanup variant — sleeps until cancelled, then runs `onShutdown`
    /// before re-raising the cancellation. Use when the service owns a
    /// resource that needs async teardown (HTTP client connection pool,
    /// long-lived gRPC channel, etc.).
    ///
    /// `onShutdown` is `async` (not `throws`) — wrap any throwing
    /// teardown call in `try?` because there's nothing the lifecycle
    /// library can do with a thrown error during shutdown.
    public init(onShutdown: @escaping @Sendable () async -> Void) {
        self.onShutdown = onShutdown
    }

    public func run() async throws {
        do {
            // Sleep for a very long but safe duration (Int32.max seconds ≈ 68 years).
            // Int.max overflows when converted to nanoseconds, so we use Int32.max.
            try await Task.sleep(for: .seconds(Int32.max))
        } catch {
            // SIGTERM → ServiceGroup cancels → Task.sleep throws.
            // Run the cleanup hook (if any) before re-raising so the
            // lifecycle library still treats this as a graceful
            // termination via CancellationError.
            await onShutdown?()
            throw error
        }
    }
}
