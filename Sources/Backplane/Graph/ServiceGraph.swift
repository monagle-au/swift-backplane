//
//  ServiceGraph.swift
//  swift-backplane
//

import Configuration
import Logging
import ServiceLifecycle

// MARK: - ServiceGraph

/// Service registry for Backplane 2.0.
///
/// Owns every registered entry's lifecycle, drives boot and blue-green
/// replacement, and exposes synchronous lookup via `resolve(_:)`.
///
/// **Per-entry mutex pattern:** The actor serialises graph-level operations
/// (boot, restart). Per-entry reads (`resolve`, `state(of:)`, `stateStream(of:)`)
/// go directly through each entry's `Mutex<State>` without an actor hop —
/// making them safe from any isolation context, including timer callbacks
/// and property-wrapper getters.
///
/// **Entries dictionary:** Marked `nonisolated(unsafe)` because:
/// 1. It is set once in `init` and never mutated.
/// 2. Each ``ServiceEntry`` protects its own mutable state with a `Mutex`.
/// Reading the dictionary without the actor hop is therefore sound.
public actor ServiceGraph {

    // MARK: - Storage

    private let entries: [String: ServiceEntry]
    private let logger: Logger?

    /// Application configuration reader supplied at graph construction.
    /// `nil` when the graph is built without one (most graph-machinery
    /// unit tests). Threaded into every minted ``ServiceContext`` so
    /// factories can call `context.config?.scoped(to: "myservice")`.
    private let config: ConfigReader?

    /// How long to allow a draining generation's `shutdown()` to run before
    /// cancelling its task. Configurable so tests can use short timeouts.
    private let shutdownTimeout: Duration

    /// Boot roots consulted by ``run()`` (the
    /// ``ServiceLifecycle/Service`` conformance) to prune the boot set
    /// to a transitive closure. Set via ``setBootRoots(_:)`` before the
    /// graph is added to its outer ``ServiceGroup``. `nil` means "boot
    /// every registered entry" — the existing default when the graph is
    /// driven standalone via ``boot(roots:)`` rather than `run()`.
    private var pendingBootRoots: [AnyServiceKey]?

    /// Resolved ``SubgroupPolicy`` per tag, covering every subgroup
    /// referenced by a descriptor. Resolution combines caller-supplied
    /// overrides with stock defaults for ``SubgroupTag/core`` and
    /// ``SubgroupTag/integrations``; unrecognised custom tags fall back
    /// to the `.core` policy.
    private let resolvedPolicies: [SubgroupTag: SubgroupPolicy]

    // MARK: - Init

    /// Construct a graph from descriptors. Throws if any descriptor
    /// declares an unknown dependency id, or if the declared dependency
    /// graph contains a cycle.
    ///
    /// - Parameter subgroupPolicies: per-tag overrides. Tags absent from
    ///   this map fall back to the stock policy: ``SubgroupPolicy/core``
    ///   for ``SubgroupTag/core``, ``SubgroupPolicy/integrations`` for
    ///   ``SubgroupTag/integrations``, and ``SubgroupPolicy/core`` for
    ///   any other (custom-named) tag.
    public init(
        descriptors: [EntryDescriptor],
        logger: Logger? = nil,
        config: ConfigReader? = nil,
        shutdownTimeout: Duration = .seconds(30),
        subgroupPolicies: [SubgroupTag: SubgroupPolicy] = [:]
    ) throws {
        var map: [String: ServiceEntry] = [:]
        for descriptor in descriptors {
            map[descriptor.id] = ServiceEntry(descriptor: descriptor)
        }
        self.entries = map
        self.logger = logger
        self.config = config
        self.shutdownTimeout = shutdownTimeout
        self.resolvedPolicies = Self.resolvePolicies(
            descriptors: descriptors,
            overrides: subgroupPolicies
        )

        try Self.validateDependencies(descriptors: descriptors)
    }

    /// Build the resolved per-tag policy map: every subgroup tag named
    /// by any descriptor maps to a concrete ``SubgroupPolicy``, picked
    /// from the caller's overrides or the stock defaults.
    private static func resolvePolicies(
        descriptors: [EntryDescriptor],
        overrides: [SubgroupTag: SubgroupPolicy]
    ) -> [SubgroupTag: SubgroupPolicy] {
        let tags = Set(descriptors.map(\.subgroup))
        var result: [SubgroupTag: SubgroupPolicy] = [:]
        for tag in tags {
            if let supplied = overrides[tag] {
                result[tag] = supplied
            } else if tag == .core {
                result[tag] = .core
            } else if tag == .integrations {
                result[tag] = .integrations
            } else {
                // Custom-named subgroups inherit core's policy unless
                // the caller explicitly supplied one.
                result[tag] = .core
            }
        }
        return result
    }

    /// Look up the resolved policy for `tag`. Falls back to
    /// ``SubgroupPolicy/core`` if the tag wasn't seen during init.
    /// In practice this fallback is only reached for restart calls on
    /// entries whose tag changed between init and call, which shouldn't
    /// happen — descriptors are immutable. Defensive only.
    private nonisolated func policy(for tag: SubgroupTag) -> SubgroupPolicy {
        resolvedPolicies[tag] ?? .core
    }

    // MARK: - Validation

    /// Check every descriptor's declared dependencies for unknown ids,
    /// then perform a DFS over the dependency graph to detect cycles.
    /// Cycle detection runs over the *full* descriptor set (not just a
    /// subset) so misconfiguration surfaces even if the cyclic subset
    /// is never booted.
    private static func validateDependencies(descriptors: [EntryDescriptor]) throws {
        // Build id → descriptor for O(1) lookups.
        var index: [String: EntryDescriptor] = [:]
        for d in descriptors { index[d.id] = d }

        // Unknown-dependency pass.
        for d in descriptors {
            for dep in d.dependencies where index[dep.id] == nil {
                throw ServiceGraphError.unknownDependency(
                    id: dep.id, referencedBy: d.id
                )
            }
        }

        // Cycle detection via DFS with three-colour marking.
        // white = unvisited, grey = on the current DFS stack, black = finished.
        enum Colour { case white, grey, black }
        var colour: [String: Colour] = [:]
        for d in descriptors { colour[d.id] = .white }

        // Recursive DFS surfaces the cycle path when re-encountering a grey node.
        func visit(_ id: String, path: [String]) throws {
            switch colour[id] {
            case .black, .none:
                return
            case .grey:
                // Cycle: the path from the first occurrence of `id`
                // through to here, then back to `id`, names the cycle.
                if let start = path.firstIndex(of: id) {
                    throw ServiceGraphError.cyclicDependency(
                        path: Array(path[start...]) + [id]
                    )
                }
                throw ServiceGraphError.cyclicDependency(path: path + [id])
            case .white:
                break
            }
            colour[id] = .grey
            if let descriptor = index[id] {
                for dep in descriptor.dependencies {
                    try visit(dep.id, path: path + [id])
                }
            }
            colour[id] = .black
        }

        for d in descriptors {
            try visit(d.id, path: [])
        }
    }

    // MARK: - Synchronous lookup (nonisolated)

    /// Return the currently-active generation's handle, cast to `T`.
    ///
    /// Returns nil only when the entry has no live handle: never-booted,
    /// `.stopped`, or `.failed`. During a blue-green swap (`.replacing`)
    /// the old generation continues to serve, so nil is never returned.
    nonisolated public func resolve<T: Sendable>(_ key: ServiceKey<T>) -> T? {
        entries[key.id]?.currentHandle(T.self)
    }

    /// Current lifecycle state of the entry, or `.unconfigured` if unknown.
    nonisolated public func state(of id: String) -> ServiceState {
        entries[id]?.currentState ?? .unconfigured
    }

    /// Subscribe to state transitions. Each call returns a fresh stream.
    /// The first element is the current state (replay-first).
    nonisolated public func stateStream(of id: String) -> AsyncStream<ServiceState> {
        guard let entry = entries[id] else {
            return AsyncStream { $0.finish() }
        }
        return entry.stateStream()
    }

    // MARK: - Async resolution

    /// Async resolve that waits for the named entry to reach a
    /// resolution-ready state. Throws ``ServiceGraphError`` if the entry
    /// is unknown, has a wrong instance type, settles into a terminal
    /// non-running state (`.failed` / `.stopped`), or exceeds the
    /// supplied timeout.
    ///
    /// Pass `timeout: nil` (the default) to wait indefinitely. Pass a
    /// `Duration` to cap the wait — exceeding it throws
    /// ``ServiceGraphError/timedOut(id:expectedType:after:)``. Recommended
    /// in production to bound the impact of a slow upstream during a
    /// dependent service's `start()`.
    ///
    /// **Resolution-ready states:** `.running`, `.degraded`, and
    /// `.starting`-with-instance. The last is the design note's §7
    /// boot-deadlock fix: a factory whose peer is still inside `start()`
    /// (but whose factory has returned) can resolve that peer's live
    /// instance without waiting for `start()` to complete. The two-phase
    /// boot architecture from §7 — factory phase, then separate start
    /// phase via an inner ``ServiceGroup`` — is a future evolution; the
    /// spike achieves the same observable in single-phase boot by
    /// swapping the active generation before calling `start()`.
    nonisolated public func requireService<T: Sendable>(
        _ key: ServiceKey<T>,
        timeout: Duration? = nil
    ) async throws -> T {
        guard let entry = entries[key.id] else {
            throw ServiceGraphError.missingService(
                id: key.id,
                expectedType: String(describing: T.self)
            )
        }

        // Synchronous fast-path: live handle available immediately. The
        // fast path bypasses the task-group overhead when the entry is
        // already running by the time the caller arrives.
        if let handle = entry.currentHandle(T.self) {
            return handle
        }

        if let timeout {
            return try await Self.awaitHandle(in: entry, key: key, timeout: timeout)
        } else {
            return try await Self.awaitHandle(in: entry, key: key)
        }
    }

    /// Wait indefinitely for the entry to reach a resolution-ready state.
    ///
    /// Three states are resolution-ready when an instance is present:
    /// `.running` and `.degraded` (post-`start()`), and `.starting` (the
    /// post-factory, pre-`start()`-return window — the design note §7
    /// boot-deadlock fix). For `.starting`, a non-nil `currentHandle`
    /// means the factory has returned and swapped the active generation;
    /// we hand it back without waiting for `start()` to finish.
    ///
    /// `.unconfigured` remains a waiting state in the spike. The
    /// descriptor's ``EntryDescriptor/configuration`` policy is stored
    /// but has no behavioural effect here *yet* — that gains meaning
    /// once factory-failure categorisation lands (a future slice that
    /// lets a factory throw "missing config" and park the entry at
    /// `.unconfigured` rather than `.failed`).
    private static func awaitHandle<T: Sendable>(
        in entry: ServiceEntry,
        key: ServiceKey<T>
    ) async throws -> T {
        for await state in entry.stateStream() {
            switch state {
            case .running, .degraded:
                if let handle = entry.currentHandle(T.self) {
                    return handle
                }
                throw ServiceGraphError.typeMismatch(
                    id: key.id,
                    expectedType: String(describing: T.self)
                )
            case .starting:
                // After the bootEntry-order change, `currentHandle` is
                // non-nil during `.starting` if the factory has returned
                // and swapped the active generation. Treat that as
                // resolution-ready — the consumer captures the reference
                // now; `start()` finishes shortly after. The replay-first
                // semantic on `stateStream` also means we may observe
                // `.starting` before the swap; in that case `currentHandle`
                // is nil and we continue waiting.
                if let handle = entry.currentHandle(T.self) {
                    return handle
                }
                continue
            case .failed, .stopped:
                throw ServiceGraphError.entryTerminated(id: key.id, state: state)
            case .unconfigured, .replacing, .configuring:
                continue
            }
        }
        // Stream finished without a resolution-ready transition.
        throw ServiceGraphError.entryTerminated(id: key.id, state: entry.currentState)
    }

    /// Wait for the entry to reach a resolution-ready state, bounded by
    /// `timeout`. Throws ``ServiceGraphError/timedOut(id:expectedType:after:)``
    /// if the bound is exceeded.
    private static func awaitHandle<T: Sendable>(
        in entry: ServiceEntry,
        key: ServiceKey<T>,
        timeout: Duration
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            // Waiter: yields when the entry becomes resolvable.
            group.addTask {
                try await Self.awaitHandle(in: entry, key: key)
            }
            // Timer: throws once `timeout` elapses.
            group.addTask {
                try await Task.sleep(for: timeout, clock: .continuous)
                throw ServiceGraphError.timedOut(
                    id: key.id,
                    expectedType: String(describing: T.self),
                    after: timeout
                )
            }
            // First task to finish wins; cancel the loser on both paths
            // so structured concurrency's scope-exit wait is quick.
            do {
                guard let result = try await group.next() else {
                    group.cancelAll()
                    throw ServiceGraphError.timedOut(
                        id: key.id,
                        expectedType: String(describing: T.self),
                        after: timeout
                    )
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Context construction

    /// Build a ``ServiceContext`` for a factory invocation.
    ///
    /// Called from both ``bootEntry(_:)`` and the restart task. Nonisolated
    /// because it only reads immutable graph state and the entry's own
    /// nonisolated accessors.
    nonisolated package func makeContext(for entry: ServiceEntry) -> ServiceContext {
        let entryLogger: Logger
        if var l = logger {
            l[metadataKey: "entry"] = "\(entry.descriptor.id)"
            entryLogger = l
        } else {
            entryLogger = Logger(label: "backplane.service-graph.\(entry.descriptor.id)")
        }
        let reporter = ServiceEntryHealthReporter(
            entryID: entry.descriptor.id,
            graph: self
        )
        return ServiceContext(
            entryID: entry.descriptor.id,
            logger: entryLogger,
            lifecycle: entry.lifecycle(in: self),
            health: reporter,
            config: config,
            graph: self
        )
    }

    // MARK: - Health-reporter forwarding (nonisolated)

    /// Called by ``ServiceEntryHealthReporter`` when the entry's service
    /// reports degradation. Delegates to the entry's own conditional
    /// transition (no-op unless currently `.running`).
    nonisolated package func markDegraded(entryID: String, fault: ServiceFault) {
        entries[entryID]?.markDegraded(fault: fault)
    }

    /// Called by ``ServiceEntryHealthReporter`` when the service reports
    /// recovery. No-op unless currently `.degraded`.
    nonisolated package func markHealthy(entryID: String) {
        entries[entryID]?.markHealthy()
    }

    // MARK: - Boot

    /// Boot entries to their terminal-or-running state concurrently.
    ///
    /// - Parameter roots: when `nil` (the default), every registered entry
    ///   is booted — the spike's original behaviour. When non-nil, only
    ///   the transitive closure of the supplied root entries' declared
    ///   dependencies is booted; entries outside the closure remain in
    ///   `.unconfigured`.
    /// - Throws: ``ServiceGraphError/unknownRoot(id:)`` if any id in
    ///   `roots` does not correspond to a registered descriptor.
    ///
    /// **Note on ordering.** Dependencies drive pruning and cycle detection
    /// but do *not* enforce boot ordering. Entries in the closure are
    /// launched concurrently and use
    /// ``ServiceContext/requireService(_:timeout:)`` to wait for any
    /// dependencies their factories actually need. A future slice may
    /// add wave-based parallel ordering as an efficiency.
    public func boot(roots: [AnyServiceKey]? = nil) async throws {
        let bootSet = try resolveBootSet(roots: roots)
        try await bootPartitioned(bootSet: bootSet) { entry in
            await self.bootEntry(entry)
        }
    }

    /// Configure the roots that ``run()`` should boot when the graph is
    /// supervised inside an outer ``ServiceGroup``. Call before adding
    /// the graph to the group. `nil` (the default) means "boot every
    /// registered entry."
    ///
    /// This is the right API to use when a command's `requiredServices`
    /// should prune the boot set under the two-phase boot path. The
    /// single-phase ``boot(roots:)`` takes its roots directly.
    public func setBootRoots(_ roots: [AnyServiceKey]?) {
        self.pendingBootRoots = roots
    }

    /// Resolve a `roots:` argument to the set of entry ids that should
    /// participate in boot. Throws ``ServiceGraphError/unknownRoot(id:)``
    /// on stringified-id typos in `roots`.
    private func resolveBootSet(roots: [AnyServiceKey]?) throws -> Set<String> {
        guard let roots else { return Set(entries.keys) }
        for root in roots where entries[root.id] == nil {
            throw ServiceGraphError.unknownRoot(id: root.id)
        }
        return transitiveClosure(of: roots.map(\.id))
    }

    /// Run the per-subgroup partitioning + failure-policy logic with the
    /// supplied per-entry closure. Used by:
    ///
    /// - ``boot(roots:)`` — passes ``bootEntry(_:)`` to do factory + start.
    /// - ``run()`` — passes ``bootPhase1Entry(_:)`` to do factory only;
    ///   the adapter drives `start()` later inside the inner
    ///   ``ServiceGroup``.
    ///
    /// Either way the subgroup partition + failFast / degraded handling
    /// is identical, so failure policies behave the same in both modes.
    private func bootPartitioned(
        bootSet: Set<String>,
        perEntry: @Sendable @escaping (ServiceEntry) async -> Void
    ) async throws {
        // Partition the booting entries by their declared subgroup.
        // Pruning has already been applied; the partition simply groups
        // the survivors so per-subgroup policies can be enforced.
        var partitioned: [SubgroupTag: [ServiceEntry]] = [:]
        for entry in entries.values where bootSet.contains(entry.descriptor.id) {
            partitioned[entry.descriptor.subgroup, default: []].append(entry)
        }

        // Run each subgroup in its own task group. Cross-subgroup isolation:
        // a failure in one `.failFast` subgroup must not cancel the boot
        // of another subgroup. Each subgroup task returns an optional
        // error; the outer group collects them and throws the first
        // observed failure after all subgroups have settled.
        let failures: [ServiceGraphError] = await withTaskGroup(
            of: ServiceGraphError?.self
        ) { outerGroup in
            for (tag, subgroupEntries) in partitioned {
                let policy = self.policy(for: tag)
                outerGroup.addTask {
                    await self.bootSubgroup(
                        tag: tag,
                        policy: policy,
                        entries: subgroupEntries,
                        perEntry: perEntry
                    )
                }
            }
            var collected: [ServiceGraphError] = []
            for await result in outerGroup {
                if let result { collected.append(result) }
            }
            return collected
        }

        if let first = failures.first {
            throw first
        }
    }

    /// Boot one subgroup's entries under its declared failure policy.
    ///
    /// `perEntry` is the per-entry work — `bootEntry` for single-phase
    /// boot or `bootPhase1Entry` for the run()-driven two-phase boot.
    ///
    /// Returns nil when the subgroup completes cleanly (either no failures
    /// or, for `.degraded`, failures absorbed into per-entry `.failed`
    /// state). Returns a `subgroupBootFailed` error for `.failFast`
    /// subgroups whose first failure cascaded — the in-flight siblings
    /// were cancelled via task-group exit, and their bootEntry catch
    /// blocks transitioned them to `.failed`.
    private func bootSubgroup(
        tag: SubgroupTag,
        policy: SubgroupPolicy,
        entries: [ServiceEntry],
        perEntry: @Sendable @escaping (ServiceEntry) async -> Void
    ) async -> ServiceGraphError? {
        switch policy.failure {
        case .degraded:
            // Each entry boots independently; failures stay isolated.
            await withTaskGroup(of: Void.self) { group in
                for entry in entries {
                    group.addTask { await perEntry(entry) }
                }
            }
            return nil

        case .failFast:
            // Iterate child completions as they arrive. On the first
            // entry observed in `.failed`, call `group.cancelAll()` so
            // in-flight siblings have their awaits cancelled. Each
            // sibling's bootEntry catches the CancellationError and
            // transitions to `.failed`. We let the remaining tasks
            // settle (very quickly after cancel) and then collect every
            // entry that ended up failed.
            //
            // Throwing-task-group + waitForAll() doesn't work here:
            // it waits for ALL tasks to complete before re-throwing,
            // so a slow sibling would finish booting before the cascade
            // could cancel it. Explicit early-cancel is the fix.
            await withTaskGroup(of: ServiceEntry.self) { group in
                for entry in entries {
                    group.addTask {
                        await perEntry(entry)
                        return entry
                    }
                }
                var sawFailure = false
                for await completed in group {
                    if case .failed = completed.currentState, !sawFailure {
                        sawFailure = true
                        group.cancelAll()
                    }
                }
            }

            let faulted = entries.compactMap { entry -> String? in
                if case .failed = entry.currentState {
                    return entry.descriptor.id
                }
                return nil
            }
            if faulted.isEmpty { return nil }

            logger?.error(
                "Subgroup '\(tag.rawValue)' boot failed; faulted: \(faulted)"
            )
            return .subgroupBootFailed(tag: tag, faulted: faulted)
        }
    }

    /// Compute the transitive closure of the supplied root ids over the
    /// declared dependency graph. Caller must have validated that every
    /// id in `roots` refers to a registered descriptor — see
    /// ``boot(roots:)``'s eager check.
    private func transitiveClosure(of roots: [String]) -> Set<String> {
        var visited = Set<String>()
        var stack = roots
        while let id = stack.popLast() {
            guard !visited.contains(id) else { continue }
            guard let entry = entries[id] else { continue }
            visited.insert(id)
            for dep in entry.descriptor.dependencies {
                if !visited.contains(dep.id) {
                    stack.append(dep.id)
                }
            }
        }
        return visited
    }

    /// Phase-1 boot — factory + active-generation swap, no `start()`.
    ///
    /// Used by ``run()`` so the inner ``ServiceGroup``'s per-entry
    /// adapter can drive `start()` and graceful shutdown. The entry
    /// is left in ``ServiceState/starting`` with the live instance
    /// observable via ``ServiceGraph/resolve(_:)`` — the adapter
    /// transitions it to `.running` once `start()` returns.
    ///
    /// Failure semantics match ``bootEntry(_:)``: a factory throw
    /// transitions the entry to `.failed`. The shared failFast /
    /// degraded handling in ``bootSubgroup(tag:policy:entries:perEntry:)``
    /// then applies normally.
    ///
    /// **State ordering.** The `.starting` transition fires *after* the
    /// active-generation swap. This makes every observation of
    /// `.starting` race-free for the §7 boot-deadlock fix: whenever a
    /// peer's `requireService` sees `.starting` on this entry, the
    /// active generation is already in place and `currentHandle`
    /// returns the live instance. The pre-factory window is
    /// `.unconfigured` (still waiting on the spike's `requireService`).
    private func bootPhase1Entry(_ entry: ServiceEntry) async {
        guard entry.currentState == .unconfigured else { return }

        let context = makeContext(for: entry)

        let instance: any ManagedService
        do {
            instance = try await entry.descriptor.factory(context)
        } catch {
            entry.transition(to: .failed(fault: ServiceFault(from: error)))
            logger?.error("bootPhase1 factory failed for '\(entry.descriptor.id)': \(error)")
            return
        }

        let gen = Generation(id: entry.nextGenerationID(), instance: instance)
        _ = entry.swapActiveGeneration(to: gen)
        // `.starting` fires only after the swap, so every observer of
        // `.starting` is guaranteed to see a non-nil `currentHandle`.
        entry.transition(to: .starting)
        // Stop here — adapter will drive start().
    }

    private func bootEntry(_ entry: ServiceEntry) async {
        guard entry.currentState == .unconfigured else { return }

        let context = makeContext(for: entry)

        let instance: any ManagedService
        do {
            instance = try await entry.descriptor.factory(context)
        } catch {
            entry.transition(to: .failed(fault: ServiceFault(from: error)))
            logger?.error("Boot factory failed for '\(entry.descriptor.id)': \(error)")
            return
        }

        // Swap the active generation, then fire `.starting`. The state
        // notification comes *after* the swap so every observer of
        // `.starting` is guaranteed to see a non-nil `currentHandle` —
        // the §7 boot-deadlock fix's race-free observable. Failure
        // semantics: if `start()` throws below, the entry transitions
        // to `.failed`; `currentHandle` filters by state and returns
        // nil for `.failed`, so a caller can't read the failed instance
        // through `resolve(_:)`. Any reference captured during
        // `.starting` is the caller's responsibility — same
        // Swift-reference semantics as a once-live service that later
        // faults.
        let gen = Generation(id: entry.nextGenerationID(), instance: instance)
        _ = entry.swapActiveGeneration(to: gen)
        entry.transition(to: .starting)

        do {
            try await instance.start()
        } catch {
            entry.transition(to: .failed(fault: ServiceFault(from: error)))
            logger?.error("Boot start() failed for '\(entry.descriptor.id)': \(error)")
            return
        }

        entry.transition(to: .running)
    }

    // MARK: - Restart (blue-green)

    /// Trigger replacement of the entry at `id` using its declared strategy.
    ///
    /// Currently only ``.blueGreen`` is implemented; `.hotReload` and
    /// `.coldRestart` fall through to blue-green with a logged note.
    ///
    /// The method returns immediately after transitioning the entry to
    /// `.replacing` and spawning the replacement task. Observe the
    /// lifecycle stream to track progress.
    public func restart(at id: String) async {
        guard let entry = entries[id] else {
            logger?.warning("restart(at:) called for unknown id '\(id)'")
            return
        }

        // Honour the subgroup policy. Non-restartable subgroups silently
        // drop restart requests — matching the same "log a warning and
        // return" pattern used for unknown ids.
        let policy = self.policy(for: entry.descriptor.subgroup)
        guard policy.restartable else {
            logger?.warning(
                "restart(at:) ignored — '\(id)' is in non-restartable subgroup '\(entry.descriptor.subgroup.rawValue)'"
            )
            return
        }

        // Only restart from a live state.
        switch entry.currentState {
        case .running, .degraded:
            break
        default:
            logger?.warning("restart(at:) ignored for '\(id)' in state \(entry.currentState)")
            return
        }

        entry.transition(to: .replacing)
        let descriptor = entry.descriptor
        let shutdownTimeout = self.shutdownTimeout
        let context = makeContext(for: entry)

        // Spawn a detached replacement task so the actor is not held during
        // the potentially-slow factory() and start() calls.
        let task = Task.detached { [logger] in
            // Phase 1: build new instance.
            let newInstance: any ManagedService
            do {
                newInstance = try await descriptor.factory(context)
            } catch {
                entry.transition(to: .degraded(fault: ServiceFault(from: error)))
                logger?.error("Replacement factory failed for '\(descriptor.id)': \(error)")
                return
            }

            guard !Task.isCancelled else {
                entry.transition(to: .degraded(fault: ServiceFault(
                    description: "Replacement cancelled before start",
                    errorType: "CancellationError",
                    firstObservedAt: .init()
                )))
                return
            }

            // Phase 2: start the new generation.
            let newGen = Generation(id: entry.nextGenerationID(), instance: newInstance)
            do {
                try await newInstance.start()
            } catch {
                // Old generation continues serving.
                entry.transition(to: .degraded(fault: ServiceFault(from: error)))
                logger?.error("Replacement start() failed for '\(descriptor.id)': \(error)")
                return
            }

            guard !Task.isCancelled else {
                entry.transition(to: .degraded(fault: ServiceFault(
                    description: "Replacement cancelled after start",
                    errorType: "CancellationError",
                    firstObservedAt: .init()
                )))
                return
            }

            // Phase 3: determine grace from the new instance's strategy.
            let grace: Duration
            if case .blueGreen(let g) = newInstance.replacementStrategy {
                grace = g
            } else {
                // .hotReload / .coldRestart not implemented in spike; fall back.
                grace = .seconds(30)
                logger?.notice("'\(descriptor.id)' declared \(newInstance.replacementStrategy); spike uses blueGreen fallback.")
            }

            // Phase 4: atomic swap — new resolves get the new generation.
            let oldGen = entry.swapActiveGeneration(to: newGen)
            entry.transition(to: .running)
            logger?.debug("Blue-green swap completed for '\(descriptor.id)' (gen \(newGen.id))")

            // Phase 5: drain old generation (fire-and-forget from here).
            guard let oldGen else { return }
            Task.detached {
                await ServiceGraph.drain(oldGen, entry: entry, grace: grace, shutdownTimeout: shutdownTimeout, logger: logger)
            }
        }

        // Cancel any prior in-flight replacement (latest restart wins).
        entry.swapReplacementTask(task)?.cancel()
    }

    // MARK: - Reload

    /// Apply new configuration to an entry's live service in place.
    ///
    /// - If the service conforms to ``HotReloadable``, the graph calls
    ///   ``HotReloadable/reload()`` on the current instance. On success
    ///   the entry stays `.running` (no new generation). On error the
    ///   entry transitions to ``ServiceState/degraded(fault:)`` — the
    ///   old instance keeps serving; the operator can escalate via
    ///   ``restart(at:)``.
    /// - Otherwise the call falls back to ``restart(at:)``. This means
    ///   `reload(at:)` is always a safe primitive: services that don't
    ///   opt into ``HotReloadable`` get blue-green replacement instead,
    ///   subject to the entry's subgroup `restartable` policy.
    ///
    /// Restartability checks happen inside the fall-back path
    /// (``restart(at:)`` rejects non-restartable subgroups). ``reload``
    /// itself does not check `restartable` — a `.core` (non-restartable)
    /// service can still be hot-reloaded if it conforms to
    /// ``HotReloadable``. This is intentional: the design note's
    /// `HotReloadable` story is precisely about config changes (TLS
    /// rotation, log levels) that don't require restartability.
    public func reload(at id: String) async {
        guard let entry = entries[id] else {
            logger?.warning("reload(at:) called for unknown id '\(id)'")
            return
        }

        // Snapshot the live instance under the same conditions as
        // resolve(_:) — we only reload services with a live handle.
        guard let instance = entry.currentManagedService() else {
            logger?.warning(
                "reload(at:) ignored — '\(id)' has no live handle (state: \(entry.currentState))"
            )
            return
        }

        guard let reloadable = instance as? any HotReloadable else {
            logger?.debug(
                "reload(at:) for '\(id)' — service is not HotReloadable; falling back to restart"
            )
            await restart(at: id)
            return
        }

        do {
            try await reloadable.reload()
            logger?.debug("reload(at:) '\(id)' succeeded; entry stays \(entry.currentState)")
        } catch {
            entry.transition(to: .degraded(fault: ServiceFault(from: error)))
            logger?.error("reload(at:) '\(id)' threw: \(error)")
        }
    }

    // MARK: - Drain

    /// Drain an old generation: sleep for the grace period, then call
    /// `shutdown()` with a bounded timeout. If `shutdown()` hangs past the
    /// timeout, cancel its task and move on.
    private static func drain(
        _ generation: Generation,
        entry: ServiceEntry,
        grace: Duration,
        shutdownTimeout: Duration,
        logger: Logger?
    ) async {
        // Sleep for the grace period so in-flight callers holding the old
        // generation reference can complete their work.
        do {
            try await Task.sleep(for: grace, clock: .continuous)
        } catch {
            // Drain task was cancelled (e.g. by a subsequent restart).
            return
        }

        guard !Task.isCancelled else { return }

        entry.removeDraining(generation)
        generation.state.withLock { $0 = .stopping }

        logger?.debug("Draining gen \(generation.id) of '\(entry.descriptor.id)': calling shutdown()")

        // Call shutdown() with a bounded timeout. If it hangs past the
        // timeout the task is cancelled; the generation is leaked at the
        // GC/task level but the entry has already moved on.
        let shutdownTask = Task {
            await generation.instance.shutdown()
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: shutdownTimeout, clock: .continuous)
            shutdownTask.cancel()
            logger?.warning("Shutdown timed out for gen \(generation.id) of '\(entry.descriptor.id)'; cancelling task.")
        }
        await shutdownTask.value
        timeoutTask.cancel()

        generation.state.withLock { $0 = .stopped }
    }
}

// MARK: - ServiceLifecycle.Service conformance

extension ServiceGraph: ServiceLifecycle.Service {

    /// Run the graph inside an outer ``ServiceGroup``.
    ///
    /// **Phase 1.** Factories run and active generations are swapped;
    /// entries reach ``ServiceState/starting`` with live handles
    /// observable via ``resolve(_:)``. Per-subgroup failure policies
    /// (failFast / degraded) apply exactly as in ``boot(roots:)`` —
    /// the shared partition logic is reused.
    ///
    /// **Phase 2.** A per-entry ``ServiceGraphEntryAdapter`` is
    /// supervised by an inner ``ServiceGroup``. Each adapter:
    /// 1. Calls `start()` on the live instance.
    /// 2. Transitions the entry to ``ServiceState/running``.
    /// 3. Awaits `gracefulShutdown()`.
    /// 4. Calls `shutdown()` and transitions to ``ServiceState/stopped``.
    ///
    /// When the outer group triggers graceful shutdown, the inner group
    /// propagates the signal to every adapter. `run()` returns once
    /// the inner group's `run()` returns.
    ///
    /// **Termination behaviours per adapter.** `failFast` subgroups map
    /// to `failureTerminationBehavior: .gracefullyShutdownGroup` —
    /// a failure cascades to draining the whole graph. `degraded`
    /// subgroups map to `failureTerminationBehavior: .ignore` — a
    /// failure leaves siblings running. `successTerminationBehavior`
    /// is `.gracefullyShutdownGroup` for everyone: a service that
    /// returns from its `run()` without a graceful-shutdown signal is
    /// a surprise and should drain the rest. (Real completion modes
    /// from the design note's §4 land in a future slice.)
    ///
    /// **Relationship with ``boot(roots:)``.** This method does not
    /// call ``boot(roots:)``. They are two operational modes:
    /// - Standalone: callers invoke ``boot(roots:)`` and then use
    ///   ``resolve(_:)``/``requireService(_:timeout:)`` — single-phase
    ///   boot, no inner ``ServiceGroup``. This is what the existing
    ///   tests use.
    /// - Composed: callers put the graph inside an outer
    ///   ``ServiceGroup`` and invoke `run()` — two-phase boot, the
    ///   adapter drives `start()`/`shutdown()`.
    /// Mixing the two within one graph lifetime is undefined.
    public func run() async throws {
        // Phase 1: factories run; active generations are swapped. The
        // boot set respects ``setBootRoots(_:)`` so a command's
        // requiredServices prunes to the transitive closure rather
        // than booting the whole graph.
        let bootSet = try resolveBootSet(roots: pendingBootRoots)
        try await bootPartitioned(bootSet: bootSet) { entry in
            await self.bootPhase1Entry(entry)
        }

        // Phase 2: build adapters for every entry whose phase 1 succeeded
        // (i.e. is in `.starting` with a live handle). Skip entries that
        // landed in `.failed` (factory threw) — they're terminal and have
        // nothing for the adapter to drive.
        var configurations: [ServiceGroupConfiguration.ServiceConfiguration] = []
        for entry in entries.values where entry.currentState == .starting {
            let adapter = ServiceGraphEntryAdapter(entry: entry, logger: logger)
            let policy = self.policy(for: entry.descriptor.subgroup)
            let failureBehavior: ServiceGroupConfiguration.ServiceConfiguration.TerminationBehavior =
                (policy.failure == .failFast) ? .gracefullyShutdownGroup : .ignore
            configurations.append(.init(
                service: adapter,
                successTerminationBehavior: .gracefullyShutdownGroup,
                failureTerminationBehavior: failureBehavior
            ))
        }

        let innerLogger = logger ?? Logger(label: "backplane.service-graph")

        if configurations.isEmpty {
            // No entries survived phase 1 (or none were registered).
            // Wait for the outer group's graceful-shutdown signal so
            // `run()` doesn't return early — that would cancel the
            // outer group.
            try await gracefulShutdown()
            return
        }

        // Inner group inherits no signal handlers — the outer group
        // owns those. Graceful shutdown propagates from outer to inner
        // via Swift's structured concurrency cancellation +
        // ServiceLifecycle's `gracefulShutdown()` helper.
        let inner = ServiceGroup(configuration: .init(
            services: configurations,
            gracefulShutdownSignals: [],
            cancellationSignals: [],
            logger: innerLogger
        ))
        try await inner.run()
    }
}
