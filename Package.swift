// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "swift-backplane",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        // Core Backplane — always available.
        .library(
            name: "Backplane",
            targets: ["Backplane"]
        ),
        // Opt-in via the `Postgres` package trait.
        .library(
            name: "BackplanePostgres",
            targets: ["BackplanePostgres"]
        ),
        // Opt-in via the `OTel` package trait.
        .library(
            name: "BackplaneOTel",
            targets: ["BackplaneOTel"]
        ),
        // Opt-in via the `GCP` package trait. Bundles the Cloud Trace
        // tracer, Cloud Trace exporter, and the Cloud Logging-shaped
        // GCPLogHandler.
        .library(
            name: "BackplaneGCP",
            targets: ["BackplaneGCP"]
        ),
        // Writable, encryption-aware configuration. The protocol and a
        // passthrough no-op are always available; opting into the
        // `KeyfileEncryption` trait additionally enables the AES-256-GCM
        // `LocalKeyfileEncryption` reference implementation.
        .library(
            name: "BackplaneVault",
            targets: ["BackplaneVault"]
        ),
    ],
    traits: [
        // Opt-in for consumers — the bare `Backplane` library has no transitive
        // postgres-nio, swift-otel, or GCP dependency. Consumers add the
        // matching trait on the package import to enable each library product.
        .default(enabledTraits: []),
        .trait(
            name: "Postgres",
            description: "Enable the BackplanePostgres target and the postgres-nio dependency."
        ),
        .trait(
            name: "OTel",
            description: "Enable the BackplaneOTel target and the swift-otel dependency."
        ),
        .trait(
            name: "GCP",
            description: "Enable the BackplaneGCP target (Cloud Trace + Cloud Logging integration)."
        ),
        .trait(
            name: "KeyfileEncryption",
            description: "Enable LocalKeyfileEncryption (AES-256-GCM, machine-local keyfile) and the swift-crypto dependency on BackplaneVault."
        ),
        .trait(
            name: "Macros",
            description: "Enable the #service declaration macro (pulls swift-syntax at build time; off by default)."
        ),
    ],
    dependencies: [
        // Core Backplane — always resolved.
        .package(url: "https://github.com/apple/swift-configuration", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.1"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.8.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.2.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.7.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.2.1"),

        // Postgres — used only by the BackplanePostgres target. Resolved
        // unconditionally (SwiftPM resolves the full dependency graph), but the
        // product is only linked into BackplanePostgres when the `Postgres` trait
        // is enabled, so consumers without the trait don't pull it into their
        // binary.
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.27.0"),

        // OTel — used only by the BackplaneOTel target. Same pattern as
        // postgres-nio: resolved at the package level, conditionally linked
        // by trait.
        .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.0.0"),

        // swift-crypto — used only by the BackplaneVault target's
        // `LocalKeyfileEncryption` reference implementation. Resolved
        // unconditionally; conditionally linked only when the
        // `KeyfileEncryption` trait is enabled, so consumers without the
        // trait pull no swift-crypto code into their binary.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),

        // swift-syntax — used only by the BackplaneMacros compiler-plugin
        // target. Resolved unconditionally (SwiftPM resolves the full
        // dependency graph), but only *compiled* when the `Macros` trait
        // links BackplaneMacros into Backplane — so consumers without the
        // trait never build swift-syntax. The range is deliberately wide:
        // it lets SwiftPM pick the version matching the active toolchain's
        // prebuilt swift-syntax (Swift 6.0–6.3 → 600–603) and lets a
        // macro-heavy consumer (already on some swift-syntax 6.x) dedupe
        // to a single resolved copy rather than building a second one.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0" ..< "604.0.0"),

        // DocC plugin — build-tool only. Powers
        // `swift package generate-documentation` for the four DocC
        // catalogs in this repo (Backplane, BackplanePostgres, BackplaneOTel,
        // BackplaneGCP). Adds nothing at runtime.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        // MARK: - Core
        .target(
            name: "Backplane",
            dependencies: [
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "Instrumentation", package: "swift-distributed-tracing"),
                // The #service macro plugin — linked (and thus swift-syntax
                // compiled) only when the `Macros` trait is enabled. The
                // `BACKPLANE_MACROS` define gates the macro *declaration* in
                // ServiceKeyMacro.swift so the bare module references nothing.
                .target(name: "BackplaneMacros", condition: .when(traits: ["Macros"])),
            ],
            swiftSettings: [
                .define("BACKPLANE_MACROS", .when(traits: ["Macros"])),
            ]
        ),

        // MARK: - BackplaneMacros (Macros trait)
        // Compiler-plugin target backing the `#service` freestanding
        // declaration macro. Builds swift-syntax, so it is only reached —
        // and therefore only compiled — when a Macros-trait-enabled
        // consumer links it via the Backplane target above.
        .macro(
            name: "BackplaneMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),

        // MARK: - BackplanePostgres (Postgres trait)
        .target(
            name: "BackplanePostgres",
            dependencies: [
                "Backplane",
                .product(
                    name: "PostgresNIO",
                    package: "postgres-nio",
                    condition: .when(traits: ["Postgres"])
                ),
                .product(
                    name: "ServiceContextModule",
                    package: "swift-service-context",
                    condition: .when(traits: ["Postgres"])
                ),
            ],
            swiftSettings: [
                .define("BACKPLANE_POSTGRES", .when(traits: ["Postgres"])),
            ]
        ),

        // MARK: - BackplaneOTel (OTel trait)
        .target(
            name: "BackplaneOTel",
            dependencies: [
                "Backplane",
                .product(
                    name: "OTel",
                    package: "swift-otel",
                    condition: .when(traits: ["OTel"])
                ),
            ],
            swiftSettings: [
                .define("BACKPLANE_OTEL", .when(traits: ["OTel"])),
            ]
        ),

        // MARK: - BackplaneGCP (GCP trait)
        // Hosts the Cloud Trace tracer/exporter and the Cloud Logging
        // GCPLogHandler. The handler delegates to the vendor-neutral
        // ``StructuredLogHandler`` in core with the .gcp profile.
        .target(
            name: "BackplaneGCP",
            dependencies: [
                "Backplane",
            ],
            swiftSettings: [
                .define("BACKPLANE_GCP", .when(traits: ["GCP"])),
            ]
        ),

        // MARK: - BackplaneVault (KeyfileEncryption trait)
        // Writable, encryption-aware configuration: `ConfigStore` on top of
        // swift-configuration's reader chain with async writers,
        // `DecryptingConfigProvider` for plaintext-ephemeral secret reads,
        // and the `ConfigEncryption` protocol for backend-agnostic
        // encryption. The protocol and `PassthroughEncryption` are always
        // available. The `KeyfileEncryption` trait additionally pulls
        // swift-crypto and enables `LocalKeyfileEncryption` (AES-256-GCM,
        // machine-local keyfile reference implementation).
        .target(
            name: "BackplaneVault",
            dependencies: [
                .product(name: "Configuration", package: "swift-configuration"),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(traits: ["KeyfileEncryption"])
                ),
            ],
            swiftSettings: [
                .define("BACKPLANE_VAULT_KEYFILE", .when(traits: ["KeyfileEncryption"])),
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "BackplaneTests",
            dependencies: ["Backplane"],
            swiftSettings: [
                // Activates the `#if BACKPLANE_MACROS` end-to-end macro test
                // when the suite is run with `--traits Macros`.
                .define("BACKPLANE_MACROS", .when(traits: ["Macros"])),
            ]
        ),
        // Unit tests for the BackplaneMacros plugin's derivation logic.
        // Swift Testing only — no XCTest / SwiftSyntaxMacrosTestSupport.
        // All source is gated behind `#if BACKPLANE_MACROS`, so with the
        // trait off this target compiles to nothing and pulls no
        // swift-syntax — plain `swift test` never builds the macro toolchain.
        .testTarget(
            name: "BackplaneMacrosTests",
            dependencies: [
                .target(name: "BackplaneMacros", condition: .when(traits: ["Macros"])),
            ],
            swiftSettings: [
                .define("BACKPLANE_MACROS", .when(traits: ["Macros"])),
            ]
        ),
        .testTarget(
            name: "BackplanePostgresTests",
            dependencies: [
                "BackplanePostgres",
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            swiftSettings: [
                .define("BACKPLANE_POSTGRES", .when(traits: ["Postgres"])),
            ]
        ),
        .testTarget(
            name: "BackplaneOTelTests",
            dependencies: [
                "BackplaneOTel",
            ],
            swiftSettings: [
                .define("BACKPLANE_OTEL", .when(traits: ["OTel"])),
            ]
        ),
        .testTarget(
            name: "BackplaneGCPTests",
            dependencies: [
                "BackplaneGCP",
            ],
            swiftSettings: [
                .define("BACKPLANE_GCP", .when(traits: ["GCP"])),
            ]
        ),
        .testTarget(
            name: "BackplaneVaultTests",
            dependencies: [
                "BackplaneVault",
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            swiftSettings: [
                .define("BACKPLANE_VAULT_KEYFILE", .when(traits: ["KeyfileEncryption"])),
            ]
        ),
    ]
)
