import CryptoKit
import Foundation

struct ManagedSecretAccount: Codable, Equatable, Identifiable {
    let id: UUID
    let provider: String
    var name: String
    var metadata: [String: String]
    var directory: URL

    var providerID: String { "\(provider)-managed-\(id.uuidString.lowercased())" }
}

struct ManagedSecretAccountStore {
    static let keychainService = "com.vinz.codenotch.managed-provider-credential"
    let root: URL
    let fileManager: FileManager

    init(root: URL = AccountProfileManager.managedRoot(), fileManager: FileManager = .default) {
        self.root = root.appendingPathComponent("secrets", isDirectory: true)
        self.fileManager = fileManager
    }

    func create(provider: String, name: String, secret: String,
                metadata: [String: String] = [:]) throws -> ManagedSecretAccount {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountProfileManager.ProfileError.invalidCredential }
        let fingerprint = Self.fingerprint(trimmed)
        guard !accounts(provider: provider).contains(where: {
            $0.metadata["credentialFingerprint"] == fingerprint
        }) else { throw AccountProfileManager.ProfileError.credentialAlreadyAdded(provider) }

        let id = UUID()
        let directory = root.appendingPathComponent(provider, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        var savedMetadata = metadata
        savedMetadata["credentialFingerprint"] = fingerprint
        let account = ManagedSecretAccount(id: id, provider: provider, name: name,
                                           metadata: savedMetadata, directory: directory)
        guard KeychainItem.store(service: Self.keychainService,
                                 account: account.providerID, value: trimmed) else {
            try? fileManager.removeItem(at: directory)
            throw AccountProfileManager.ProfileError.cannotCreate("The credential could not be saved in Keychain.")
        }
        do { try save(account) }
        catch {
            _ = KeychainItem.delete(service: Self.keychainService, account: account.providerID)
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return account
    }

    func credential(_ account: ManagedSecretAccount) -> String? {
        KeychainItem.read(service: Self.keychainService, account: account.providerID)
    }

    func accounts(provider: String? = nil) -> [ManagedSecretAccount] {
        let roots = provider.map { [root.appendingPathComponent($0, isDirectory: true)] }
            ?? ((try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
        return roots.flatMap { providerRoot in
            ((try? fileManager.contentsOfDirectory(at: providerRoot, includingPropertiesForKeys: nil)) ?? [])
                .compactMap { directory in
                    guard let data = try? Data(contentsOf: directory.appendingPathComponent("account.json")),
                          var account = try? JSONDecoder().decode(ManagedSecretAccount.self, from: data),
                          KeychainItem.modifiedAt(service: Self.keychainService,
                                                  account: account.providerID) != nil else { return nil }
                    account.directory = directory
                    return account
                }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func remove(_ account: ManagedSecretAccount) throws {
        _ = KeychainItem.delete(service: Self.keychainService, account: account.providerID)
        if fileManager.fileExists(atPath: account.directory.path) { try fileManager.removeItem(at: account.directory) }
    }

    private func save(_ account: ManagedSecretAccount) throws {
        try JSONEncoder().encode(account).write(
            to: account.directory.appendingPathComponent("account.json"), options: .atomic)
    }

    private static func fingerprint(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
