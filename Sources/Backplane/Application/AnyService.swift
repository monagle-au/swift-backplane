//
//  AnyService.swift
//  swift-backplane
//

import ServiceLifecycle

/// A type-erased ``Service`` wrapper.
///
/// Use this when you need to store or return a concrete `Service`
/// conformance whose generic type cannot be expressed directly — for
/// example, `GRPCServer<HTTP2ServerTransport.Posix>`.
public struct AnyService: Service, Sendable {
    private let _run: @Sendable () async throws -> Void

    public init<S: Service & Sendable>(_ service: S) {
        _run = { try await service.run() }
    }

    public func run() async throws {
        try await _run()
    }
}
