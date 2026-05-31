//
//  PostgresMigration.swift
//  budget-forward-cloud
//
//  Created by David Monagle on 5/9/2024.
//

#if BACKPLANE_POSTGRES

import PostgresNIO

public protocol PostgresMigration: Sendable {
    var name: String { get }
    var queries: [PostgresQuery] { get }
}

#endif
