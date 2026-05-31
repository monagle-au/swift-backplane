//
//  Generation.swift
//  swift-backplane
//

import Synchronization

// MARK: - GenerationState

/// Per-generation lifecycle state.
///
/// Distinct from the entry-level ``ServiceState`` — a generation moves
/// through its own FSM independently of its siblings. The entry
/// aggregates across generations to produce the consumer-visible
/// ``ServiceState``.
package enum GenerationState: Sendable, Hashable {
    case starting
    case running
    case draining
    case stopping
    case stopped
    case failed(fault: ServiceFault)
}

// MARK: - Generation

/// One live instance within a ``ServiceEntry``.
///
/// The ``ServiceGraph`` may have two generations alive simultaneously
/// during a blue-green swap: the old one in ``GenerationState/draining``
/// and the new one in ``GenerationState/running``. The entry's
/// active-pointer swap is the moment consumers see the transition.
package final class Generation: Sendable {
    package let id: UInt64
    package let instance: any ManagedService
    package let state: Mutex<GenerationState>

    package init(id: UInt64, instance: any ManagedService) {
        self.id = id
        self.instance = instance
        self.state = Mutex(.starting)
    }

    package var currentState: GenerationState {
        state.withLock { $0 }
    }
}
