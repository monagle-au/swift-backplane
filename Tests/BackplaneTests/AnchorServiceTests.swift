//
//  AnchorServiceTests.swift
//  swift-backplane
//

import Synchronization
import Testing
@testable import Backplane

@Suite("AnchorService")
struct AnchorServiceTests {

    @Test("init() — sleeps until cancelled, propagates CancellationError")
    func sleepsUntilCancelled() async throws {
        let service = AnchorService()
        let task = Task {
            try await service.run()
        }
        // Give the task a moment to enter Task.sleep, then cancel.
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        // The task should throw CancellationError; assert by awaiting
        // and checking the thrown type.
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("init(onShutdown:) — runs cleanup before re-raising cancellation")
    func runsCleanupOnCancel() async throws {
        let cleanupRan = Mutex<Bool>(false)
        let service = AnchorService {
            cleanupRan.withLock { $0 = true }
        }
        let task = Task {
            try await service.run()
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        // After the task throws, cleanup must have run.
        #expect(cleanupRan.withLock { $0 } == true)
    }

    @Test("init(onShutdown:) — does NOT run cleanup until cancellation")
    func cleanupNotRunBeforeCancel() async throws {
        let cleanupRan = Mutex<Bool>(false)
        let service = AnchorService {
            cleanupRan.withLock { $0 = true }
        }
        let task = Task {
            try await service.run()
        }
        // Without cancelling, the cleanup must not fire.
        try await Task.sleep(for: .milliseconds(20))
        #expect(cleanupRan.withLock { $0 } == false)
        task.cancel()
        _ = try? await task.value
    }
}
