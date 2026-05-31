//
//  ServiceContext+Environment.swift
//  budget-forward-cloud
//
//  Created by David Monagle on 3/9/2024.
//

import ServiceContextModule

extension ServiceContextModule.ServiceContext {
    /// The `Environment` associated with this `ServiceContext`.
    public var environment: Environment? {
        set {
            self[EnvironmentContextKey.self] = newValue
        }
        get {
            self[EnvironmentContextKey.self]
        }
    }
    
    private enum EnvironmentContextKey: ServiceContextKey {
        typealias Value = Environment
    }
}
