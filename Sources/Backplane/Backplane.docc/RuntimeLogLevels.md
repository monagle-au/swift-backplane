# Runtime log levels

Raise or lower verbosity for one component, or one subsystem of it,
while the process runs.

## Overview

Every handler that ``BootstrapCoordinator`` installs is a
``LevelTableLogHandler`` that consults a ``LogLevelTable``. By
default that is the process table, ``BackplaneLogging/levelTable``.
The table holds a base level (the bootstrap's resolved level) plus
``LogLevelRule``s:

| Field | Meaning |
|---|---|
| `labelPrefix` | Matched against the logger label with `hasPrefix`. |
| `subsystem` | `nil` or `"*"` (`*` decodes to `nil`): any message from the label. Otherwise only messages whose subsystem metadata equals it. |
| `level` | The minimum level emitted. |
| `expiresAt` | Optional. After it, the rule is ignored and pruned. A far-future date is safe: the expiry is converted to milliseconds with saturation. A NaN date counts as already expired (stored as `Date.distantPast`, so `set` drops it); `+infinity` never expires. |

### Resolution

The rule with the longest matching label prefix wins. At equal
prefixes, a rule for the message's subsystem beats an any-subsystem
rule. A rule limited to another subsystem does not match, and
resolution continues to shorter prefixes. With no match, the base
level applies.

A message's subsystem is the first of
``LogLevelTable/subsystemKeys`` (default `subsystem`,
`matter.subsystem`) found in the message's metadata, else in the
logger's metadata (`logger[metadataKey:]`).

### Configuring at startup

Rules use the syntax `label[:subsystem]=level`, given either as a
repeatable `--log-rule` flag on ``LoggingOptions`` or in the
`logging.rules` config key (a string array). A malformed `--log-rule`
is a `validate()` error; a malformed `logging.rules` entry is skipped
leniently. Config rules come before CLI rules, and later rules win, so
a CLI rule for the same label and subsystem overrides the config one.

Merge first, then copy both the resolved and the rejected rules onto
the plan:

```swift
func bootstrap(config: ConfigReader, environment: Environment) -> BootstrapPlan {
    let merged = logging.merging(from: config.scoped(to: "logging"))
    var plan = BootstrapPlan()
    plan.logLevel = merged.resolvedLogLevel
    plan.logRules = merged.resolvedLogRules
    plan.rejectedLogRules = merged.rejectedLogRules
    return plan
}
```

```bash
my-app serve --log-rule acumen.agent=debug --log-rule 'matter:mrp=trace'
```

On the ``BootstrapCoordinator/apply(_:)`` that installs logging, the
coordinator logs one warning per entry of
``BootstrapPlan/rejectedLogRules``:
`Ignoring malformed logging rule '<text>'`. Two caveats:

- The warning is logged under label `backplane.logging` through the
  table, so that label's level applies. Normally that is the base
  level, so `--log-level error` hides it; a `backplane=…` rule can
  surface it.
- If logging was already bootstrapped, the whole plan's logging
  configuration is skipped, rules and warnings included. Two cases
  follow:
  - **OTel logs enabled.** swift-otel bootstraps `LoggingSystem`
    itself, so no ``LevelTableLogHandler`` is in use. The table is not
    consulted at all: rules and runtime `set` do nothing.
    ``LogLevelTable/isConsulted`` is `false` in this case, so an admin
    flow can tell before offering a change.
  - **`main()` calls `bootstrapLogging` first.** That call goes through
    `apply`, so the table is installed with that call's base level and
    no rules. The command's later plan is skipped, so its `--log-rule`
    / `logging.rules` (and rejected-rule warnings) are dropped.
    Runtime `set(_:)`, `remove` and `reset()` still work.

### Changing at runtime

```swift
let table = BackplaneLogging.levelTable
table.set(LogLevelRule(
    labelPrefix: "acumen.agent.matter-agent",
    subsystem: "*",
    level: .trace,
    expiresAt: Date().addingTimeInterval(3600)
))
table.rules()                                   // live rules, precedence order
table.remove(labelPrefix: "acumen.agent.matter-agent")
table.reset()                                   // back to the configured rules
table.isConsulted                               // whether any handler reads the table
```

Runtime rules are not persisted: a restart returns to the configured
rules. Give verbose rules an `expiresAt` so a forgotten one cannot
flood the log.

### Per-logger levels

Setting `logLevel` on a `Logger` is a per-instance floor. The logger
emits at the higher of its floor and the table's level, so it can be
made quieter than the table but never louder.

### Placing the handler

``LevelTableLogHandler`` must be the outermost handler. Never put it
inside a `MultiplexLogHandler`: the multiplex records its level once,
at construction, so rule changes would not reach it. Wrap the
multiplex instead. The coordinator already does this for the factory
in ``BootstrapPlan/logHandlerFactory``, and a custom `installLogging`
hook receives the already-wrapped factory (its level argument is
informational only). A custom hook must not set
`handler.logLevel = level`: that creates a per-instance floor which
stops rules lowering the level.

### Cost

In the steady state the `logLevel` check swift-log runs on every call
is a few atomic loads and no lock.
Each handler caches its label's minimum level against
``LogLevelTable/generation``, and the table bumps the generation on
every change. While any live rule has an `expiresAt`, each check also reads the
clock, and the lock is taken once when a rule actually expires. The
table lock is also taken after a change, or for a message that passed
the check from a label whose level depends on subsystem.

## Topics

- ``LogLevelTable``
- ``LogLevelTable/isConsulted``
- ``LogLevelRule``
- ``LevelTableLogHandler``
- ``BackplaneLogging/levelTable``
- ``BootstrapPlan/logRules``
- ``BootstrapPlan/rejectedLogRules``
- ``LoggingOptions/resolvedLogRules``
- ``LoggingOptions/rejectedLogRules``
