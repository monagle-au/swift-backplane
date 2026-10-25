//
//  OTelLogging.swift
//  swift-backplane
//

#if BACKPLANE_OTEL

import Backplane
import Logging

extension BackplaneOTel {

    /// The attribute every OTLP log record carries its swift-log label in.
    ///
    /// swift-otel's logging backend serves every label with one handler and
    /// keeps no label on the record, so without this a log store cannot tell
    /// `acumen.engine` from `acumen.agent.matter-agent`. A message's or the
    /// logger's own `logger` key wins.
    public static let loggerLabelKey = "logger"

    /// The logging factory ``makeBootstrap(serviceName:tracing:metrics:logsEnabled:configure:localLogs:)``
    /// puts in `BootstrapPlan.logHandlerFactory` when OTel logs are on.
    ///
    /// Each label gets an ``OTelRecordLogHandler`` over `otel`'s handler.
    /// With `localLogs`, the two are multiplexed, local first. The
    /// coordinator wraps the result in `LevelTableLogHandler`, which stays
    /// outermost, so one table decides for both legs. `LevelTableLogHandler`
    /// sets the multiplex's level to `.trace`, so its children never refilter.
    static func logHandlerFactory(
        otel: @escaping LogHandlerFactory,
        localLogs: LogHandlerFactory?
    ) -> LogHandlerFactory {
        { label in
            let record = OTelRecordLogHandler(label: label, wrapping: otel(label))
            guard let localLogs else { return record }
            return MultiplexLogHandler([localLogs(label), record])
        }
    }
}

/// Wraps swift-otel's log handler for one label.
///
/// - Stamps ``BackplaneOTel/loggerLabelKey`` with the label, unless the
///   message or the wrapped handler already has that key.
/// - Accepts and drops a metadata provider. The OTLP record takes its trace
///   and span ids from `InstrumentationContext.current` itself, and swift-otel's
///   handler has no provider support (assigning one would log swift-log's
///   DEBUG-only "did not implement support" warning).
struct OTelRecordLogHandler: LogHandler {

    let label: String
    var wrapped: any LogHandler

    init(label: String, wrapping handler: any LogHandler) {
        self.label = label
        self.wrapped = handler
    }

    var logLevel: Logger.Level {
        get { wrapped.logLevel }
        set { wrapped.logLevel = newValue }
    }

    var metadata: Logger.Metadata {
        get { wrapped.metadata }
        set { wrapped.metadata = newValue }
    }

    var metadataProvider: Logger.MetadataProvider? {
        get { nil }
        set { _ = newValue }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { wrapped[metadataKey: key] }
        set { wrapped[metadataKey: key] = newValue }
    }

    func log(event: LogEvent) {
        var event = event
        var metadata = event.metadata ?? [:]
        if metadata[BackplaneOTel.loggerLabelKey] == nil,
           wrapped[metadataKey: BackplaneOTel.loggerLabelKey] == nil {
            metadata[BackplaneOTel.loggerLabelKey] = .string(label)
        }
        event.metadata = metadata
        wrapped.log(event: event)
    }

    // As in `LevelTableLogHandler`: keep the deprecated flat entry point
    // forwarding, so a caller of it cannot recurse through swift-log's defaults.
    @available(*, deprecated, renamed: "log(event:)")
    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        self.log(
            event: LogEvent(
                level: level,
                message: message,
                metadata: metadata,
                source: source,
                file: file,
                function: function,
                line: line
            )
        )
    }
}

#endif
