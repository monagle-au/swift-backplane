# Contributing to swift-backplane

Thanks for considering a contribution. This document covers the
mechanics — branching, commit style, the build/test matrix, and how
releases work.

## Quick start

```bash
git clone https://github.com/monagle-au/swift-backplane.git
cd swift-backplane
swift test                                  # core only
swift test --traits Postgres,OTel,GCP       # full trait matrix
```

Requirements: Swift 6.2+, macOS 15+. Linux (Swift 6.2 official Docker
images) is also supported and exercised in CI.

## Branching and PR flow

- `main` is protected — direct pushes are blocked. All work lands via
  pull request.
- Topic branches: short, kebab-case, scoped (`bootstrap-coordinator`,
  `fix-postgres-pool-default`).
- One PR per coherent unit. If you find yourself writing
  "and also fixed an unrelated thing" in the description, split it.

The required CI checks before a PR can merge:

| Job              | Runner                    | What it covers                          |
|------------------|---------------------------|-----------------------------------------|
| `macOS / no traits`  | `macos-26`            | Core `Backplane` library + tests.        |
| `macOS / all traits` | `macos-26`            | Postgres + OTel + GCP enabled.          |
| `Linux / no traits`  | `swift:6.2-noble`     | Core, Linux Foundation paths.           |
| `Linux / all traits` | `swift:6.2-noble`     | Trait matrix on Linux.                  |
| `DocC build`         | `macos-26`            | DocC catalogs build clean per-target.   |

## Commit messages

Format: `Topic: short imperative summary` for the subject line, with a
body explaining the *why* when non-obvious. Wrap the body at ~72 chars.

Recent examples worth mimicking:

```
Application: declarative bootstrap pipeline + Postgres/OTel traits
Logging: generalise GCPLogHandler + move Cloud Trace/Logging behind GCP trait
Postgres: expose pool sizing + connect/statement timeout knobs
```

## Code style

- Swift 6 strict concurrency — every public type is `Sendable`.
- Public APIs need DocC-friendly docstrings (`///`-comments). Internal
  helpers can be sparser.
- Prefer fewer, smaller types over deep generic hierarchies.
- New optional integrations live behind a package trait (see the
  existing `Postgres` / `OTel` / `GCP` patterns in `Package.swift`).

## Adding a new optional integration

1. Add a trait in `Package.swift` (`traits:` array).
2. Add a library product gated by the trait.
3. Add a target with:
   - `swiftSettings: [.define("BACKPLANE_<TRAIT>", .when(traits: ["<Trait>"]))]`
   - Trait-conditional product dependencies via
     `condition: .when(traits: ["<Trait>"])`.
4. Wrap every source file in `#if BACKPLANE_<TRAIT> … #endif`.
5. Mirror the structure for tests.
6. Add a `.docc` catalog with at least a root and a walkthrough article.
7. Update `.spi.yml` to list the target under `documentation_targets`.
8. Update `README.md`'s trait table.
9. Update `CHANGELOG.md` under `[Unreleased]`.

## Tests

Use Swift Testing (`@Suite`, `@Test`, `#expect`). For tests that need an
in-memory `ConfigReader`, the
[`makeConfig`](Tests/BackplanePostgresTests/PostgresConfigTests.swift)
helper pattern is already used in several files — copy and adapt.

For tests that exercise services, the `QuickService` no-op in
[ApplicationRunnerTests](Tests/BackplaneTests/ApplicationRunnerTests.swift)
is the conventional placeholder.

## Release process

Releases are tag-driven. The full runbook:

```
1. Open a release PR:
   - Promote the [Unreleased] section in CHANGELOG.md to
     [<version>] — <YYYY-MM-DD>.
   - If publishing a 1.x or 2.x major, double-check the migration notes.
2. Merge the PR via squash. CI re-runs.
3. Pull main, then:    git tag -s vX.Y.Z -m "X.Y.Z"
4.                     git push origin vX.Y.Z
5. The Release workflow picks up the tag, runs the full trait matrix
   on macOS + Linux, and creates a GitHub Release with the
   CHANGELOG.md section as the body.
6. Verify Swift Package Index ingests the tag (typically <10 minutes).
```

Tag style:

- `vMAJOR.MINOR.PATCH` — stable.
- `vMAJOR.MINOR.PATCH-rc.N` / `-beta.N` / `-alpha.N` — pre-release.
  The release workflow flags these as pre-release (not `--latest`).

SemVer commitments from 1.0.0 onwards:

- **Public API additions** — MINOR bump.
- **Public API removals or signature changes** — MAJOR bump.
- **Trait-default changes** — MAJOR (changes every consumer's resolved
  dependency graph).

## Reporting issues

For bugs, include:
- Swift toolchain version (`swift --version`).
- macOS / Linux distro version.
- The trait combination in use.
- A minimal reproduction (a Package.swift + a few files is ideal).

For security issues, please email the maintainer privately rather than
opening a public issue. See the repo's Security Policy if one is
configured.
