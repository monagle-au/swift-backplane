//
//  PassthroughEncryptionTests.swift
//  swift-backplane
//

import Testing
import BackplaneVault

@Suite("PassthroughEncryption")
struct PassthroughEncryptionTests {
    let encryption = PassthroughEncryption()

    @Test("encrypt returns input unchanged")
    func encryptIdentity() throws {
        let result = try encryption.encrypt("hello")
        #expect(result == "hello")
    }

    @Test("decrypt returns input unchanged")
    func decryptIdentity() throws {
        let result = try encryption.decrypt("hello")
        #expect(result == "hello")
    }

    @Test("isEncrypted always returns false")
    func isEncryptedAlwaysFalse() {
        #expect(!encryption.isEncrypted("hello"))
        #expect(!encryption.isEncrypted("backplane-vault:v1:abc"))
        #expect(!encryption.isEncrypted(""))
    }
}
