//
//  ConfigWriter.swift
//  swift-backplane
//

import Foundation

/// Handles reading and writing JSON configuration files with atomic writes
/// and nested key support via dot notation.
public struct ConfigWriter: Sendable {

    /// Read a JSON config file into a flat dictionary of string keys to JSON-compatible values.
    ///
    /// Returns an empty dictionary if the file does not exist.
    ///
    /// - Parameter filePath: Absolute path to the JSON file.
    /// - Returns: A flat dictionary of dot-separated keys to their values.
    /// - Throws: If the file exists but cannot be parsed as JSON.
    public static func read(filePath: String) throws -> [String: Any] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: filePath) else { return [:] }

        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigWriterError.invalidFormat("Root element must be a JSON object")
        }

        return flatten(json)
    }

    /// Write a flat dictionary of string keys to a JSON file atomically.
    ///
    /// Creates parent directories if they do not exist. Keys with dots are
    /// expanded into nested objects (e.g., `"bridge.ip"` → `{"bridge": {"ip": ...}}`).
    /// The file is written with `0o600` permissions (owner read+write only) so
    /// other local users cannot read it even though secrets are also encrypted.
    ///
    /// - Parameters:
    ///   - values: A flat dictionary of dot-separated keys to JSON-compatible values.
    ///   - filePath: Absolute path to the JSON file.
    /// - Throws: If the file cannot be written.
    public static func write(_ values: [String: Any], to filePath: String) throws {
        let nested = unflatten(values)
        let url = URL(fileURLWithPath: filePath)

        // Create parent directory if needed
        let directory = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let data = try JSONSerialization.data(
            withJSONObject: nested,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)

        // Re-apply restrictive permissions defensively. `.atomic` writes
        // through a temp file + rename so the umask may have set wider
        // permissions than we want.
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: filePath
        )
    }

    /// Merge a single key-value pair into an existing JSON file.
    ///
    /// Reads the current file contents fresh (or starts with an empty
    /// dictionary), sets the key, and writes back atomically — all while
    /// holding the file's cross-process ``FileLock``, so a concurrent writer
    /// in another process (or another store on the same file in this
    /// process) can never have its keys erased by this write.
    ///
    /// This is the synchronous entry point; the wait for the lock parks the
    /// calling thread for at most `lockTimeout`. Async callers that manage
    /// the lock themselves use the internal `mergeHoldingLock(key:value:filePath:)`.
    ///
    /// - Parameters:
    ///   - key: The dot-separated key to set.
    ///   - value: The value to set. Pass `nil` to remove the key.
    ///   - filePath: Absolute path to the JSON file.
    ///   - lockTimeout: How long to wait for the file lock before throwing
    ///     ``FileLockError/timedOut(lockFilePath:timeout:)``.
    /// - Throws: If the lock cannot be acquired or the file cannot be read
    ///   or written.
    public static func merge(
        key: String,
        value: Any?,
        filePath: String,
        lockTimeout: Duration = .seconds(5)
    ) throws {
        let lock = try FileLock.acquireBlocking(forProtecting: filePath, timeout: lockTimeout)
        defer { lock.release() }
        try mergeHoldingLock(key: key, value: value, filePath: filePath)
    }

    /// The read-merge-write core shared by ``merge(key:value:filePath:lockTimeout:)``
    /// and `ConfigStoreBackend`. Callers MUST hold the file's ``FileLock``
    /// for the duration of the call.
    ///
    /// - Returns: The full merged dictionary that was written, so callers
    ///   can refresh in-memory state from the authoritative result.
    @discardableResult
    static func mergeHoldingLock(key: String, value: Any?, filePath: String) throws -> [String: Any] {
        var values = try read(filePath: filePath)
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        try write(values, to: filePath)
        return values
    }

    // MARK: - Flatten / Unflatten

    /// Flatten a nested dictionary into dot-separated keys.
    ///
    /// `{"bridge": {"ip": "192.168.1.10"}}` → `{"bridge.ip": "192.168.1.10"}`
    private static func flatten(_ dict: [String: Any], prefix: String = "") -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                let flattened = flatten(nested, prefix: fullKey)
                result.merge(flattened) { _, new in new }
            } else {
                result[fullKey] = value
            }
        }
        return result
    }

    /// Unflatten dot-separated keys into a nested dictionary.
    ///
    /// `{"bridge.ip": "192.168.1.10"}` → `{"bridge": {"ip": "192.168.1.10"}}`
    private static func unflatten(_ flat: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in flat {
            let parts = key.split(separator: ".").map(String.init)
            setNestedValue(&result, parts: parts, value: value)
        }
        return result
    }

    /// Recursively set a value in a nested dictionary.
    private static func setNestedValue(
        _ dict: inout [String: Any],
        parts: [String],
        value: Any
    ) {
        guard let first = parts.first else { return }
        if parts.count == 1 {
            dict[first] = value
        } else {
            var nested = dict[first] as? [String: Any] ?? [:]
            setNestedValue(&nested, parts: Array(parts.dropFirst()), value: value)
            dict[first] = nested
        }
    }
}

// MARK: - Errors

public enum ConfigWriterError: Error, CustomStringConvertible {
    case invalidFormat(String)

    public var description: String {
        switch self {
        case .invalidFormat(let message): "Invalid config file format: \(message)"
        }
    }
}
