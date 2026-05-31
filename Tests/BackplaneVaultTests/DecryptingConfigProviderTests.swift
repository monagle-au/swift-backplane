//
//  DecryptingConfigProviderTests.swift
//  swift-backplane
//

import Testing
import Foundation
import Configuration
@testable import BackplaneVault

@Suite("DecryptingConfigProvider")
struct DecryptingConfigProviderTests {
    let encryption = MockEncryption()

    /// Create a DecryptingConfigProvider wrapping a MutableInMemoryProvider.
    private func makeProvider(
        values: [AbsoluteConfigKey: ConfigValue] = [:]
    ) -> (DecryptingConfigProvider<MutableInMemoryProvider>, MutableInMemoryProvider) {
        let mutable = MutableInMemoryProvider(name: "test", initialValues: values)
        let decrypting = DecryptingConfigProvider(upstream: mutable, encryption: encryption)
        return (decrypting, mutable)
    }

    @Test("Non-secret values pass through unchanged")
    func nonSecretPassthrough() throws {
        let key = AbsoluteConfigKey(["greeting"])
        let (provider, _) = makeProvider(values: [
            key: ConfigValue(.string("hello"), isSecret: false)
        ])

        let result = try provider.value(forKey: key, type: .string)
        #expect(result.value?.content == .string("hello"))
    }

    @Test("Secret encrypted values are decrypted on read")
    func secretDecryption() throws {
        let key = AbsoluteConfigKey(["apiKey"])
        let encrypted = "mock-encrypted:my-secret"
        let (provider, _) = makeProvider(values: [
            key: ConfigValue(.string(encrypted), isSecret: true)
        ])

        let result = try provider.value(forKey: key, type: .string)
        #expect(result.value?.content == .string("my-secret"))
        #expect(result.value?.isSecret == true)
    }

    @Test("Secret non-encrypted values pass through unchanged")
    func secretNonEncryptedPassthrough() throws {
        let key = AbsoluteConfigKey(["plain"])
        let (provider, _) = makeProvider(values: [
            key: ConfigValue(.string("not-encrypted"), isSecret: true)
        ])

        let result = try provider.value(forKey: key, type: .string)
        #expect(result.value?.content == .string("not-encrypted"))
    }

    @Test("Snapshot decrypts secret values")
    func snapshotDecryption() throws {
        let key = AbsoluteConfigKey(["secret"])
        let encrypted = "mock-encrypted:hidden"
        let (provider, _) = makeProvider(values: [
            key: ConfigValue(.string(encrypted), isSecret: true)
        ])

        let snapshot = provider.snapshot()
        let result = try snapshot.value(forKey: key, type: .string)
        #expect(result.value?.content == .string("hidden"))
        #expect(result.value?.isSecret == true)
    }

    @Test("Non-string secret values pass through unchanged")
    func nonStringSecretPassthrough() throws {
        let key = AbsoluteConfigKey(["count"])
        let (provider, _) = makeProvider(values: [
            key: ConfigValue(.int(42), isSecret: true)
        ])

        let result = try provider.value(forKey: key, type: .int)
        #expect(result.value?.content == .int(42))
    }

    @Test("Provider name includes upstream name")
    func providerName() {
        let (provider, _) = makeProvider()
        #expect(provider.providerName.contains("Decrypting"))
        #expect(provider.providerName.contains("test"))
    }
}
