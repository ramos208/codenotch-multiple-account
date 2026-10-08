import XCTest
@testable import Codenotch

@MainActor
final class AccountProfileManagerTests: XCTestCase {
    func testManagedCodexProfileIsOutsideDefaultHome() throws {
        try withRoot { root, manager in
            let profile = try manager.create(provider: .codex, name: "Work")
            XCTAssertEqual(profile.id, "codex-managed-work")
            XCTAssertEqual(profile.directory.path, root.appendingPathComponent("codex/work").path)
            XCTAssertFalse(profile.directory.path.hasPrefix(
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
            ))
        }
    }

    func testMultipleAccountsHaveIndependentDirectories() throws {
        try withRoot { _, manager in
            let work = try manager.create(provider: .codex, name: "Work")
            let client = try manager.create(provider: .codex, name: "Client")
            XCTAssertNotEqual(work.id, client.id)
            XCTAssertNotEqual(work.directory, client.directory)
        }
    }

    func testRemainingCLIAccountsHaveIndependentProfileRoots() throws {
        try withRoot { root, manager in
            for provider in [ManagedAccountProvider.cursor, .grok, .kimi] {
                let personal = try manager.create(provider: provider, name: "Personal")
                let work = try manager.create(provider: provider, name: "Work")
                XCTAssertNotEqual(personal.id, work.id)
                XCTAssertEqual(personal.directory.deletingLastPathComponent(),
                               root.appendingPathComponent(provider.rawValue))
                XCTAssertNotEqual(personal.directory, work.directory)
            }
        }
    }

    func testCancelRemovesPartialIsolatedCLIProfile() throws {
        try withRoot { _, manager in
            let profile = try manager.create(provider: .cursor, name: "Partial")
            try FileManager.default.createDirectory(
                at: profile.directory.appendingPathComponent(".cursor"),
                withIntermediateDirectories: true)
            manager.cancel(profile)
            XCTAssertFalse(FileManager.default.fileExists(atPath: profile.directory.path))
        }
    }

    func testManagedCodexAccountsCanBeListedAndRemoved() throws {
        try withRoot { _, manager in
            let work = try manager.create(provider: .codex, name: "Work")
            XCTAssertTrue(FileManager.default.createFile(
                atPath: work.directory.appendingPathComponent("auth.json").path,
                contents: Data("{}".utf8)
            ))

            XCTAssertEqual(manager.managedCodexProfiles.map(\.id), ["codex-managed-work"])
            try manager.removeCodex(work)
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.directory.path))
            XCTAssertTrue(manager.managedCodexProfiles.isEmpty)
        }
    }

    func testDuplicateManagedCodexEmailIsRejectedEvenWithDifferentNames() throws {
        try withRoot { _, manager in
            let personal = try manager.create(provider: .codex, name: "Personal")
            let work = try manager.create(provider: .codex, name: "Work")
            try writeCodexAuth(email: "Same@Example.com", to: personal.directory)
            XCTAssertNoThrow(try manager.validateUniqueIdentity(personal))
            try writeCodexAuth(email: " same@example.com ", to: work.directory)
            XCTAssertThrowsError(try manager.validateUniqueIdentity(work)) { error in
                XCTAssertEqual(
                    error as? AccountProfileManager.ProfileError,
                    .emailAlreadyAdded("OpenAI / Codex", "same@example.com")
                )
            }
        }
    }

    func testDuplicateDoesNotOverwriteAccount() throws {
        try withRoot { _, manager in
            let profile = try manager.create(provider: .codex, name: "Work")
            let marker = profile.directory.appendingPathComponent("keep")
            XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: Data("safe".utf8)))
            XCTAssertThrowsError(try manager.create(provider: .codex, name: "Work"))
            XCTAssertEqual(try Data(contentsOf: marker), Data("safe".utf8))
        }
    }

    func testCancelRemovesOnlyEmptyUnauthenticatedDirectory() throws {
        try withRoot { _, manager in
            let empty = try manager.create(provider: .codex, name: "Empty")
            manager.cancel(empty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: empty.directory.path))

            let used = try manager.create(provider: .codex, name: "Used")
            _ = FileManager.default.createFile(
                atPath: used.directory.appendingPathComponent("other-data").path,
                contents: Data()
            )
            manager.cancel(used)
            XCTAssertTrue(FileManager.default.fileExists(atPath: used.directory.path))
        }
    }

    func testClaudeUsesItsOwnIsolatedDirectory() throws {
        try withRoot { _, manager in
            XCTAssertTrue(manager.supportsDirectLogin(.claude))
            let profile = try manager.create(provider: .claude, name: "Company")
            XCTAssertEqual(profile.id, "claude-managed-company")
            XCTAssertTrue(profile.directory.path.hasSuffix("/claude/company"))
        }
    }

    func testAntigravityAvailabilityFollowsOfficialOAuthConfiguration() throws {
        try withRoot { _, manager in
            XCTAssertEqual(manager.supportsDirectLogin(.antigravity),
                           AntigravityOAuthConfiguration.resolved() != nil)
            if AntigravityOAuthConfiguration.resolved() == nil {
                XCTAssertThrowsError(try manager.create(provider: .antigravity, name: "Work"))
            }
        }
    }

    func testAntigravityOAuthArtifactParsingUsesMatchingClientValues() {
        let clientID = "123-a.apps." + "googleusercontent.com"
        let clientSecret = "GOC" + "SPX-" + String(repeating: "a", count: 28)
        let artifact = Data("""
        ignored \(clientID) \(clientSecret)
        """.utf8)
        let client = AntigravityOAuthConfiguration.parse(artifact)
        XCTAssertEqual(client?.id, clientID)
        XCTAssertEqual(client?.secret, clientSecret)
    }

    func testAntigravityOAuthTextParsingAnchorsToCloudCodeClient() {
        let wrongID = "111-wrong.apps." + "googleusercontent.com"
        let rightID = "222-right.apps." + "googleusercontent.com"
        let wrongSecret = "GOC" + "SPX-" + String(repeating: "w", count: 28)
        let rightSecret = "GOC" + "SPX-" + String(repeating: "r", count: 28)
        let artifact = Data("""
        unrelated \(wrongID) \(wrongSecret)
        vs/platform/cloudCode/common/oauthClient.js
        bundled \(rightID) \(rightSecret)
        """.utf8)
        let client = AntigravityOAuthConfiguration.parse(artifact)
        XCTAssertEqual(client?.id, rightID)
        XCTAssertEqual(client?.secret, rightSecret)
    }

    func testAntigravityCallbackIsKeptWhenBrowserReturnsBeforeWaitBegins() async throws {
        let server = AntigravityOAuthLoopback(state: "expected")
        server.completeForTesting(.init(code: "authorization-code", state: "expected", error: nil))
        let callback = try await server.callback(timeout: 1)
        XCTAssertEqual(callback.code, "authorization-code")
        XCTAssertEqual(callback.state, "expected")
    }

    func testSlugGeneration() {
        XCTAssertEqual(AccountProfileManager.slug(for: "My Company"), "my-company")
        XCTAssertEqual(AccountProfileManager.slug(for: "Client #1"), "client-1")
        XCTAssertNil(AccountProfileManager.slug(for: "---"))
    }

    private func withRoot(_ body: (URL, AccountProfileManager) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountProfileManagerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, AccountProfileManager(
            root: root,
            executableOverrides: [
                .codex: URL(fileURLWithPath: "/usr/bin/true"),
                .claude: URL(fileURLWithPath: "/usr/bin/true"),
                .cursor: URL(fileURLWithPath: "/usr/bin/true"),
                .grok: URL(fileURLWithPath: "/usr/bin/true"),
                .kimi: URL(fileURLWithPath: "/usr/bin/true"),
            ]
        ))
    }

    private func writeCodexAuth(email: String, to directory: URL) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["email": email])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let auth: [String: Any] = [
            "tokens": [
                "id_token": "header.\(payload).signature",
                "access_token": "access",
                "account_id": UUID().uuidString,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: directory.appendingPathComponent("auth.json"))
    }
}
