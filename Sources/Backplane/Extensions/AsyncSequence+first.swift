//
//  AsyncSequence+first.swift
//  budget-forward-cloud
//
//  Created by David Monagle on 16/1/2025.
//

import Foundation

public extension AsyncSequence {
    /// Returns the first element produced by the asynchronous sequence, or `nil` if the sequence is empty.
    ///
    /// This is a convenience wrapper around `first(where:)` that matches any element.
    /// It suspends until the first element becomes available or the sequence finishes.
    ///
    /// - Returns: The first element of the sequence, or `nil` if the sequence contains no elements.
    /// - Throws: Rethrows any error thrown while iterating the underlying sequence.
    func first() async rethrows -> Element? {
        try await first(where: { _ in true })
    }
}
