import XCTest
@testable import Codenotch

final class ManagedSecretAccountTests: XCTestCase {
    func testSecretsAreIndependentAndDuplicateCredentialIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-secret-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedSecretAccountStore(root: root, fileManager: .default)
        let first = try store.create(provider: "ollama", name: "One", secret: "key-one")
        let second = try store.create(provider: "ollama", name: "Two", secret: "key-two")
        defer {
            try? store.remove(first)
            try? store.remove(second)
        }

        XCTAssertEqual(store.credential(first), "key-one")
        XCTAssertEqual(store.credential(second), "key-two")
        XCTAssertNotEqual(first.providerID, second.providerID)
        XCTAssertThrowsError(try store.create(provider: "ollama", name: "Duplicate", secret: "key-one"))
    }

    func testRemovalDeletesOnlySelectedCredential() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-secret-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedSecretAccountStore(root: root, fileManager: .default)
        let first = try store.create(provider: "apify", name: "One", secret: "token-one")
        let second = try store.create(provider: "apify", name: "Two", secret: "token-two")
        defer { try? store.remove(second) }

        try store.remove(first)

        XCTAssertNil(store.credential(first))
        XCTAssertEqual(store.credential(second), "token-two")
        XCTAssertEqual(store.accounts(provider: "apify").map(\.providerID), [second.providerID])
    }
}
