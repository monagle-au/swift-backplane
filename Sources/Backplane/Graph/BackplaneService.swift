//
//  BackplaneService.swift
//  swift-backplane
//

/// A ``ManagedService`` that carries its own construction recipe,
/// dependencies, and policies — complete at the point it's written.
///
/// A ``ServiceKey`` whose `Value` conforms needs **no** `services()`
/// entry: the graph materialises a default ``EntryDescriptor`` on
/// demand when a command's `requiredServices` (or another entry's
/// dependencies) reaches the key. `services()` remains the override
/// surface — an explicit descriptor for the same key id always wins.
///
/// ```swift
/// final class Notifier: BackplaneService {
///     static func make(context: BackplaneContext) async throws -> Notifier {
///         // context.config is pre-scoped to the entry id ("notifier").
///         Notifier(webhookURL: try context.requireConfig().requiredString(forKey: "webhookURL"))
///     }
///     static var dependencies: ServiceList { [\.postgres] }
///     static var subgroup: SubgroupTag { .integrations }
///
///     func start() async throws { … }
///     func shutdown() async { … }
/// }
///
/// extension Services {
///     var notifier: ServiceKey<Notifier> { "notifier" }
/// }
/// ```
///
/// Conforming classes should be `final` — a `Self`-returning static
/// requirement is awkward to satisfy from a non-final class.
///
/// The same type may back multiple keys (multi-instance): each key's
/// entry reads its own config scope, because ``BackplaneContext/config``
/// is scoped to the entry id, not the type.
///
/// `start()`/`shutdown()` deliberately have **no** default no-op
/// implementations — a forgotten `start()` on a real service should be
/// a compile error, not a silent no-op. For genuinely passive values,
/// register with ``EntryDescriptor``'s `passive:` closure form instead.
public protocol BackplaneService: ManagedService {
    /// Construct an instance for the entry being booted or replaced.
    /// Called at first boot and again on every replacement cycle.
    static func make(context: BackplaneContext) async throws -> Self

    /// Keys this service's `make(context:)` resolves via
    /// ``BackplaneContext/requireService(_:timeout:)``. Drives pruning,
    /// cycle detection, and default materialisation of the dependencies
    /// themselves. Defaults to none.
    static var dependencies: ServiceList { get }

    /// Failure-policy partition for entries backed by this type.
    /// Defaults to ``SubgroupTag/core``.
    static var subgroup: SubgroupTag { get }

    /// How the graph replaces entries backed by this type.
    /// Defaults to ``ReplacementStrategy/standard``.
    static var replacementStrategy: ReplacementStrategy { get }
}

extension BackplaneService {
    public static var dependencies: ServiceList { [] }
    public static var subgroup: SubgroupTag { .core }
    public static var replacementStrategy: ReplacementStrategy { .standard }
}
