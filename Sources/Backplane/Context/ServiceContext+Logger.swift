//
//  ServiceContext+Logger.swift
//  budget-forward-cloud
//
//  Created by David Monagle on 28/8/2024.
//

import ServiceContextModule
import Logging

private enum LoggerKey: ServiceContextKey {
    typealias Value = Logger
}

extension ServiceContextModule.ServiceContext {
    /// A `Logger` associated with this `ServiceContext`.
    public var logger: Logger? {
        set {
            self[LoggerKey.self] = newValue
        }
        get {
            self[LoggerKey.self]
        }
    }
}
