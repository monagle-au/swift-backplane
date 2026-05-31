//
//  ServiceContext+active.swift
//  budget-forward-cloud
//
//  Created by David Monagle on 4/10/2024.
//

import ServiceContextModule

/// Convenience access to the currently active `ServiceContext`, falling back to a top-level context.
///
/// This helper returns `ServiceContext.current` when available (e.g., within a task or request scope),
/// otherwise it returns `.topLevel`, providing a safe default that avoids optional handling at call sites.
extension ServiceContextModule.ServiceContext {
    /// The active `ServiceContext` for the current execution, or `.topLevel` if none is set.
    public static var active: ServiceContextModule.ServiceContext {
        ServiceContextModule.ServiceContext.current ?? .topLevel
    }
}
