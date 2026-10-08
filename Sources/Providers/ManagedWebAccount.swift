import Foundation

struct ManagedWebAccount: Codable, Equatable, Identifiable {
    let id: UUID
    let provider: String
    var name: String
    var directory: URL

    var providerID: String { "\(provider)-managed-\(id.uuidString.lowercased())" }
}

struct ManagedWebAccountStore {
    let root: URL
    let fileManager: FileManager

    init(root: URL = AccountProfileManager.managedRoot(), fileManager: FileManager = .default) {
        self.root = root.appendingPathComponent("web", isDirectory: true)
        self.fileManager = fileManager
    }

    func create(provider: String, name: String) throws -> ManagedWebAccount {
        let id = UUID()
        let directory = root.appendingPathComponent(provider, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let account = ManagedWebAccount(id: id, provider: provider, name: name, directory: directory)
        try save(account)
        return account
    }

    func save(_ account: ManagedWebAccount) throws {
        try fileManager.createDirectory(at: account.directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(account).write(
            to: account.directory.appendingPathComponent("account.json"), options: .atomic)
    }

    func accounts(provider: String? = nil) -> [ManagedWebAccount] {
        let providerRoots: [URL]
        if let provider {
            providerRoots = [root.appendingPathComponent(provider, isDirectory: true)]
        } else {
            providerRoots = (try? fileManager.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        }
        return providerRoots.flatMap { providerRoot in
            ((try? fileManager.contentsOfDirectory(at: providerRoot,
                includingPropertiesForKeys: [.isDirectoryKey])) ?? []).compactMap { directory in
                let url = directory.appendingPathComponent("account.json")
                guard let data = try? Data(contentsOf: url),
                      var account = try? JSONDecoder().decode(ManagedWebAccount.self, from: data),
                      UserDefaults.standard.bool(forKey: "\(account.providerID).signedIn")
                else { return nil }
                account.directory = directory
                return account
            }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func remove(_ account: ManagedWebAccount) throws {
        UserDefaults.standard.removeObject(forKey: "\(account.providerID).signedIn")
        UserDefaults.standard.removeObject(forKey: "\(account.providerID).authFingerprint")
        if fileManager.fileExists(atPath: account.directory.path) {
            try fileManager.removeItem(at: account.directory)
        }
    }
}
