//
//  BackplaneApplication+Observability.swift
//  swift-backplane
//

import Instrumentation
import Metrics
import Tracing

extension BackplaneApplication {
    /// Bootstrap the global `InstrumentationSystem` with the given
    /// `Instrument` (typically a `Tracer`).
    ///
    /// `InstrumentationSystem.bootstrap(_:)` is a one-shot global. Prefer
    /// the declarative path: build a ``BootstrapPlan`` from
    /// ``BackplaneCommand/bootstrap(config:environment:)`` so CLI-flag values
    /// like `--otel-endpoint` can drive the bootstrap. This static method is
    /// an escape hatch for apps that override `main()`:
    ///
    /// ```swift
    /// @main
    /// struct MyApp: BackplaneApplication {
    ///     public static func main() async {
    ///         bootstrapTracing(using: MyTracer(...))
    ///         bootstrapLogging(metadataProvider: ...)
    ///         await RootCommand.main()
    ///     }
    /// }
    /// ```
    ///
    /// Apps that don't ship spans skip this entirely — swift-distributed-
    /// tracing's `NoOpInstrument` is the default when no bootstrap occurs,
    /// so `withSpan` becomes a near-zero-cost passthrough.
    ///
    /// This method routes through ``BootstrapCoordinator/shared``, so a
    /// later call to ``BackplaneCommand/bootstrap(config:environment:)``
    /// from inside the same process won't re-install the instrumentation
    /// system.
    ///
    /// - Parameter instrument: The `Tracer` (or any `Instrument`) to install
    ///   as the process-wide tracing backend. To run several instruments
    ///   concurrently (e.g. a Cloud Trace exporter alongside Datadog),
    ///   pass a `MultiplexInstrument([a, b, …])`.
    public static func bootstrapTracing(using instrument: any Instrument) {
        var plan = BootstrapPlan()
        plan.instrument = instrument
        BootstrapCoordinator.shared.apply(plan)
    }

    /// Bootstrap the global `MetricsSystem` with the given factory.
    ///
    /// `MetricsSystem.bootstrap(_:)` is a one-shot global. Prefer the
    /// declarative path: build a ``BootstrapPlan`` from
    /// ``BackplaneCommand/bootstrap(config:environment:)``. This static
    /// method is an escape hatch for apps that already override `main()`.
    ///
    /// Apps that don't ship metrics skip this entirely — swift-metrics'
    /// no-op handler is the default.
    ///
    /// This method routes through ``BootstrapCoordinator/shared``, so a
    /// later call to ``BackplaneCommand/bootstrap(config:environment:)``
    /// from inside the same process won't re-install metrics.
    ///
    /// - Parameter factory: The `MetricsFactory` to install as the
    ///   process-wide metrics backend.
    public static func bootstrapMetrics(using factory: any MetricsFactory) {
        var plan = BootstrapPlan()
        plan.metricsFactory = factory
        BootstrapCoordinator.shared.apply(plan)
    }
}
