//
//  ApplicationRunner+Observability.swift
//  swift-backplane
//

import Tracing
import Metrics

extension ApplicationRunner {
    /// Executes a synchronous build closure, recording a metric on success.
    ///
    /// A `Counter` named `backplane.service.builds` is incremented after a
    /// successful build, labelled with the service name.
    ///
    /// - Parameters:
    ///   - label: The service label used in the metric dimension.
    ///   - body: The synchronous build closure.
    /// - Returns: The value returned by `body`.
    /// - Throws: Any error thrown by `body`.
    func withBuildSpan<T>(label: String, body: () async throws -> T) async throws -> T {
        let value = try await body()
        Counter(label: "backplane.service.builds", dimensions: [("service", label)]).increment()
        return value
    }

    /// Executes an async run closure within a distributed tracing span.
    ///
    /// Opens a span named `backplane.application.run` and attaches the application
    /// identifier as a span attribute before awaiting the body.
    ///
    /// - Parameters:
    ///   - label: The application identifier attached to the span as an attribute.
    ///   - body: The async closure to run within the span.
    /// - Throws: Any error thrown by `body`.
    func withRunSpan(label: String, body: () async throws -> Void) async throws {
        try await withSpan("backplane.application.run") { span in
            span.attributes["backplane.identifier"] = label
            try await body()
        }
    }
}
