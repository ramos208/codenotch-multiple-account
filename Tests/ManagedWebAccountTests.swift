import XCTest
@testable import Codenotch

final class ManagedWebAccountTests: XCTestCase {
    func testAccountsHaveIndependentStableProviderIDs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-web-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedWebAccountStore(root: root, fileManager: .default)
        let first = try store.create(provider: "deepseek", name: "Personal")
        let second = try store.create(provider: "deepseek", name: "Work")
        defer {
            UserDefaults.standard.removeObject(forKey: "\(first.providerID).signedIn")
            UserDefaults.standard.removeObject(forKey: "\(second.providerID).signedIn")
        }

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.providerID, second.providerID)
        XCTAssertTrue(store.accounts(provider: "deepseek").isEmpty)

        UserDefaults.standard.set(true, forKey: "\(first.providerID).signedIn")
        UserDefaults.standard.set(true, forKey: "\(second.providerID).signedIn")
        XCTAssertEqual(Set(store.accounts(provider: "deepseek").map(\.providerID)),
                       Set([first.providerID, second.providerID]))
    }

    func testRemovingOneAccountDoesNotRemoveAnother() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-web-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedWebAccountStore(root: root, fileManager: .default)
        let first = try store.create(provider: "qianwenai", name: "One")
        let second = try store.create(provider: "qianwenai", name: "Two")
        UserDefaults.standard.set(true, forKey: "\(first.providerID).signedIn")
        UserDefaults.standard.set(true, forKey: "\(second.providerID).signedIn")
        defer { UserDefaults.standard.removeObject(forKey: "\(second.providerID).signedIn") }

        try store.remove(first)

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory.path))
        XCTAssertEqual(store.accounts(provider: "qianwenai").map(\.providerID), [second.providerID])
    }
}
