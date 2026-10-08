import Foundation

enum ManagedAccountProvider: String, CaseIterable, Identifiable {
    case codex, claude, antigravity, cursor, grok, kimi, kiro, deepseek, qianwenai, minimax, ollama, apify, glm, amp, kilo, opencode, copilot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: "OpenAI / Codex"
        case .claude: "Anthropic / Claude"
        case .antigravity: "Antigravity"
        case .cursor: "Cursor"
        case .grok: "Grok"
        case .kimi: "Kimi"
        case .kiro: "Kiro"
        case .deepseek: "DeepSeek"
        case .qianwenai: "QianwenAI"
        case .minimax: "MiniMax"
        case .ollama: "Ollama Cloud"
        case .apify: "Apify"
        case .glm: "GLM / Z.ai"
        case .amp: "Amp"
        case .kilo: "Kilo"
        case .opencode: "OpenCode"
        case .copilot: "GitHub Copilot"
        }
    }
    var subtitle: String {
        self == .kiro ? "Multi-account setup coming soon" : "Add another account"
    }
    var unsupportedExplanation: String {
        switch self {
        case .kiro: "Multi-account setup coming soon. Kiro does not document a supported isolated profile directory."
        case .codex, .claude, .antigravity, .cursor, .grok, .kimi, .deepseek, .qianwenai, .minimax, .ollama, .apify, .glm, .amp, .kilo, .opencode, .copilot: ""
        }
    }
}

/// Provider-specific facts behind the shared background authentication flow.
/// Implementations use only supported client isolation variables and verify
/// success from the credential source consumed by the matching usage fetcher.
private protocol ManagedAccountAuthenticator {
    var provider: ManagedAccountProvider { get }
    var arguments: [String] { get }
    var environmentKey: String { get }
    var executableCandidates: [String] { get }
    func profileID(slug: String) -> String
    func isAuthenticated(directory: URL) -> Bool
}

private struct CodexAccountAuthenticator: ManagedAccountAuthenticator {
    let provider = ManagedAccountProvider.codex
    let arguments = ["-c", "cli_auth_credentials_store=\"file\"", "login"]
    let environmentKey = "CODEX_HOME"
    var executableCandidates: [String] {
        [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
        ]
    }
    func profileID(slug: String) -> String { "codex-managed-\(slug)" }
    func isAuthenticated(directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path)
    }
}

private struct ClaudeAccountAuthenticator: ManagedAccountAuthenticator {
    let provider = ManagedAccountProvider.claude
    let arguments = ["auth", "login"]
    let environmentKey = "CLAUDE_CONFIG_DIR"
    var executableCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
        ]
    }
    func profileID(slug: String) -> String { "claude-managed-\(slug)" }
    func isAuthenticated(directory: URL) -> Bool {
        ClaudeProfile.hasKeychainCredential(
            ClaudeProfile(slug: "managed-\(directory.lastPathComponent)", configDirectory: directory)
        )
    }
}

private struct CursorAccountAuthenticator: ManagedAccountAuthenticator {
    let provider = ManagedAccountProvider.cursor
    let arguments = ["login"]
    // The manager also sets CURSOR_CONFIG_DIR and file credential storage.
    // HOME is the important boundary: Cursor's file credential store writes
    // ~/.cursor/auth.json, so every managed account receives a different file.
    let environmentKey = "HOME"
    var executableCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local/bin/cursor-agent").path,
            "/opt/homebrew/bin/cursor-agent", "/usr/local/bin/cursor-agent",
        ]
    }
    func profileID(slug: String) -> String { "cursor-managed-\(slug)" }
    func isAuthenticated(directory: URL) -> Bool {
        CursorCredentials.managedAccount(in: directory) != nil
            && CursorCredentials.managedAuthURL(in: directory).isFileURL
            && FileManager.default.fileExists(atPath: CursorCredentials.managedAuthURL(in: directory).path)
    }
}

private struct GrokAccountAuthenticator: ManagedAccountAuthenticator {
    let provider = ManagedAccountProvider.grok
    // Bypass the CLI's interactive method picker. OAuth opens the official
    // xAI browser flow directly and can complete while the helper stays hidden.
    let arguments = ["login", "--oauth"]
    let environmentKey = "GROK_HOME"
    var executableCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".grok/bin/grok").path,
                home.appendingPathComponent(".local/bin/grok").path,
                "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
    }
    func profileID(slug: String) -> String { "grok-managed-\(slug)" }
    func isAuthenticated(directory: URL) -> Bool {
        (try? GrokCredentials.load(from: directory.appendingPathComponent("auth.json"))) != nil
    }
}

private struct KimiAccountAuthenticator: ManagedAccountAuthenticator {
    let provider = ManagedAccountProvider.kimi
    let arguments = ["login"]
    let environmentKey = "KIMI_CODE_HOME"
    var executableCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".kimi-code/bin/kimi").path,
                home.appendingPathComponent(".local/bin/kimi").path,
                "/opt/homebrew/bin/kimi", "/usr/local/bin/kimi"]
    }
    func profileID(slug: String) -> String { "kimi-managed-\(slug)" }
    func isAuthenticated(directory: URL) -> Bool {
        (try? KimiCredentials.load(from: directory.appendingPathComponent("credentials/kimi-code.json"))) != nil
    }
}

/// Owns provider authentication processes for Codenotch-managed accounts.
/// Child processes receive isolated environments and never touch default
/// profiles. No command is run through a shell, Terminal, or provider GUI.
@MainActor
final class AccountProfileManager: ObservableObject {
    typealias Provider = ManagedAccountProvider

    enum AuthenticationState: Equatable {
        case idle, starting, waitingForBrowser, success
        case failed(String)
    }

    struct CreatedProfile: Equatable {
        let provider: Provider
        let id: String
        let name: String
        let slug: String
        let directory: URL
    }

    enum ProfileError: LocalizedError, Equatable {
        case invalidName, invalidCredential, credentialAlreadyAdded(String)
        case alreadyExists(String), emailAlreadyAdded(String, String)
        case clientUnavailable(String), unsupported(String), cannotCreate(String)
        var errorDescription: String? {
            switch self {
            case .invalidName: "Enter a name containing at least one letter or number."
            case .invalidCredential: "Enter a valid credential."
            case .credentialAlreadyAdded(let provider): "This \(provider) credential is already added."
            case .alreadyExists(let name): "An account named \"\(name)\" already exists."
            case .emailAlreadyAdded(let provider, let email):
                "\(email) is already added as a managed \(provider) account."
            case .clientUnavailable(let name): "\(name)'s authentication client could not be found."
            case .unsupported(let explanation): explanation
            case .cannotCreate(let reason): "The isolated account could not be created: \(reason)"
            }
        }
    }

    @Published private(set) var states: [String: AuthenticationState] = [:]
    private let fileManager: FileManager
    private let root: URL
    private let profilesChanged: () -> Void
    private let authenticators: [Provider: any ManagedAccountAuthenticator]
    private let executableOverrides: [Provider: URL]
    private var processes: [String: Process] = [:]
    private var oauthTasks: [String: Task<Void, Never>] = [:]
    private var webAuthenticators: [String: WebSessionProvider] = [:]
    private var newlyCreatedProfiles: Set<String> = []

    init(fileManager: FileManager = .default,
         root: URL = AccountProfileManager.managedRoot(),
         executableOverrides: [Provider: URL] = [:],
         profilesChanged: @escaping () -> Void = {}) {
        self.fileManager = fileManager
        self.root = root
        self.executableOverrides = executableOverrides
        self.profilesChanged = profilesChanged
        let implementations: [any ManagedAccountAuthenticator] = [
            CodexAccountAuthenticator(), ClaudeAccountAuthenticator(), CursorAccountAuthenticator(),
            GrokAccountAuthenticator(), KimiAccountAuthenticator(),
        ]
        self.authenticators = Dictionary(uniqueKeysWithValues: implementations.map { ($0.provider, $0) })
    }

    nonisolated static func managedRoot(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Codenotch/Accounts", isDirectory: true)
    }

    func supportsDirectLogin(_ provider: Provider) -> Bool {
        if requiresCredentialEntry(provider) { return true }
        if provider == .deepseek || provider == .qianwenai || provider == .minimax { return true }
        if provider == .antigravity { return AntigravityOAuthConfiguration.resolved() != nil }
        guard let authenticator = authenticators[provider] else { return false }
        return executable(for: authenticator) != nil
    }

    func requiresCredentialEntry(_ provider: Provider) -> Bool {
        provider == .ollama || provider == .apify || provider == .glm || provider == .amp || provider == .kilo || provider == .opencode || provider == .copilot
    }

    func unavailableExplanation(for provider: Provider) -> String {
        if provider == .antigravity {
            return AntigravityOAuthConfiguration.resolved() == nil
                ? "Antigravity.app is required so Codenotch can reuse its official Google OAuth configuration."
                : ""
        }
        guard let authenticator = authenticators[provider] else { return provider.unsupportedExplanation }
        return executable(for: authenticator) == nil
            ? "\(provider.title)'s authentication client is not installed on this Mac."
            : ""
    }

    static func slug(for name: String) -> String? {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        let parts = folded.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }
        let slug = parts.map(String.init).filter { !$0.isEmpty }.joined(separator: "-")
        return slug.isEmpty ? nil : slug
    }

    /// Creates an internal profile without asking the user to invent a label.
    /// The random slug is storage identity only; after authentication the UI
    /// derives a human label from the signed-in email.
    func create(provider: Provider) throws -> CreatedProfile {
        try create(provider: provider,
                   name: "account-\(UUID().uuidString.lowercased())")
    }

    func suggestedDisplayName(for profile: CreatedProfile,
                              existingNames: [String]) -> String {
        let email = authenticatedEmail(for: profile)
        let localPart = email?.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "Account"
        let firstPiece = localPart
            .split(whereSeparator: { !$0.isLetter })
            .first.map(String.init)
        let firstName = (firstPiece?.isEmpty == false ? firstPiece! : "Account")
            .prefix(1).uppercased() + (firstPiece?.dropFirst().lowercased() ?? "")
        let providerName: String
        switch profile.provider {
        case .codex: providerName = "Codex"
        case .claude: providerName = "Claude"
        case .antigravity: providerName = "Antigravity"
        case .cursor: providerName = "Cursor"
        case .grok: providerName = "Grok"
        case .kimi: providerName = "Kimi"
        case .kiro: providerName = "Kiro"
        case .deepseek: providerName = "DeepSeek"
        case .qianwenai: providerName = "QianwenAI"
        case .minimax: providerName = "MiniMax"
        case .ollama: providerName = "Ollama"
        case .apify: providerName = "Apify"
        case .glm: providerName = "GLM"
        case .amp: providerName = "Amp"
        case .kilo: providerName = "Kilo"
        case .opencode: providerName = "OpenCode"
        case .copilot: providerName = "Copilot"
        }
        let base = "\(firstName) \(providerName)"
        let occupied = Set(existingNames.map { $0.lowercased() })
        guard occupied.contains(base.lowercased()) else { return base }
        var number = 2
        while occupied.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    func create(provider: Provider, name: String) throws -> CreatedProfile {
        if provider == .deepseek || provider == .qianwenai || provider == .minimax {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.slug(for: trimmed) != nil else { throw ProfileError.invalidName }
            do {
                let account = try ManagedWebAccountStore(root: root, fileManager: fileManager)
                    .create(provider: provider.rawValue, name: trimmed)
                let profile = CreatedProfile(provider: provider, id: account.providerID,
                    name: trimmed, slug: account.id.uuidString.lowercased(), directory: account.directory)
                states[profile.id] = .idle
                newlyCreatedProfiles.insert(profile.id)
                return profile
            } catch { throw ProfileError.cannotCreate(error.localizedDescription) }
        }
        if provider == .antigravity {
            guard AntigravityOAuthConfiguration.resolved() != nil else {
                throw ProfileError.clientUnavailable(provider.title)
            }
            guard Self.slug(for: name) != nil else { throw ProfileError.invalidName }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !AntigravityManagedAccountStore(root: root, fileManager: fileManager).accounts()
                .contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                throw ProfileError.alreadyExists(trimmed)
            }
            do {
                let account = try AntigravityManagedAccountStore(root: root, fileManager: fileManager).create(name: trimmed)
                let id = "antigravity-managed-\(account.id.uuidString.lowercased())"
                states[id] = .idle
                newlyCreatedProfiles.insert(id)
                return CreatedProfile(provider: provider, id: id, name: trimmed,
                                      slug: account.id.uuidString.lowercased(), directory: account.directory)
            } catch let error as ProfileError { throw error }
            catch { throw ProfileError.cannotCreate(error.localizedDescription) }
        }
        guard let authenticator = authenticators[provider] else {
            throw ProfileError.unsupported(provider.unsupportedExplanation)
        }
        guard executable(for: authenticator) != nil else {
            throw ProfileError.clientUnavailable(provider.title)
        }
        guard let slug = Self.slug(for: name) else { throw ProfileError.invalidName }
        let directory = root.appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw ProfileError.alreadyExists(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            throw ProfileError.cannotCreate(error.localizedDescription)
        }
        let profile = CreatedProfile(provider: provider, id: authenticator.profileID(slug: slug),
                                     name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     slug: slug, directory: directory)
        states[profile.id] = .idle
        newlyCreatedProfiles.insert(profile.id)
        return profile
    }

    func create(provider: Provider, credential: String,
                metadata: [String: String] = [:]) throws -> CreatedProfile {
        guard requiresCredentialEntry(provider) else {
            throw ProfileError.unsupported(provider.title)
        }
        let generated = "account-\(UUID().uuidString.lowercased())"
        let account = try ManagedSecretAccountStore(root: root, fileManager: fileManager)
            .create(provider: provider.rawValue, name: generated, secret: credential, metadata: metadata)
        let profile = CreatedProfile(provider: provider, id: account.providerID, name: generated,
            slug: account.id.uuidString.lowercased(), directory: account.directory)
        states[profile.id] = .success
        newlyCreatedProfiles.insert(profile.id)
        profilesChanged()
        return profile
    }

    func authenticate(_ profile: CreatedProfile) {
        if profile.provider == .deepseek || profile.provider == .qianwenai || profile.provider == .minimax {
            authenticateWeb(profile)
            return
        }
        if profile.provider == .antigravity {
            authenticateAntigravity(profile)
            return
        }
        guard let authenticator = authenticators[profile.provider],
              let executable = executable(for: authenticator) else {
            states[profile.id] = .failed(unavailableExplanation(for: profile.provider))
            return
        }
        cancelProcess(profile.id)
        states[profile.id] = .starting
        let process = Process()
        process.executableURL = executable
        process.arguments = authenticator.arguments
        var environment = ProcessInfo.processInfo.environment
        environment[authenticator.environmentKey] = profile.directory.path
        if profile.provider == .cursor {
            environment["CURSOR_CONFIG_DIR"] = profile.directory
                .appendingPathComponent(".cursor", isDirectory: true).path
            environment["AGENT_CLI_CREDENTIAL_STORE"] = "file"
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.processes[profile.id] === process else { return }
                self.processes.removeValue(forKey: profile.id)
                if process.terminationStatus == 0 && self.isAuthenticated(profile) {
                    do {
                        try self.validateUniqueIdentity(profile)
                        self.newlyCreatedProfiles.remove(profile.id)
                        self.states[profile.id] = .success
                        self.profilesChanged()
                    } catch {
                        self.discardNewDuplicate(profile)
                        self.states[profile.id] = .failed(error.localizedDescription)
                    }
                } else if self.states[profile.id] != .idle {
                    self.states[profile.id] = .failed("Authentication did not complete. Try again.")
                }
            }
        }
        do {
            try process.run()
            processes[profile.id] = process
            states[profile.id] = .waitingForBrowser
        } catch {
            states[profile.id] = .failed(error.localizedDescription)
        }
    }

    func isAuthenticated(_ profile: CreatedProfile) -> Bool {
        if profile.provider == .deepseek || profile.provider == .qianwenai || profile.provider == .minimax {
            return UserDefaults.standard.bool(forKey: "\(profile.id).signedIn")
        }
        if profile.provider == .antigravity, let id = UUID(uuidString: profile.slug) {
            return AntigravityManagedCredentialsStore.exists(accountID: id)
        }
        return authenticators[profile.provider]?.isAuthenticated(directory: profile.directory) == true
    }

    func cancel(_ profile: CreatedProfile) {
        let wasNew = newlyCreatedProfiles.contains(profile.id)
        oauthTasks.removeValue(forKey: profile.id)?.cancel()
        webAuthenticators.removeValue(forKey: profile.id)
        cancelProcess(profile.id)
        newlyCreatedProfiles.remove(profile.id)
        states[profile.id] = .idle
        if profile.provider == .deepseek || profile.provider == .qianwenai || profile.provider == .minimax {
            if !isAuthenticated(profile),
               let account = ManagedWebAccountStore(root: root, fileManager: fileManager)
                .accounts(provider: profile.provider.rawValue)
                .first(where: { $0.providerID == profile.id }) {
                try? ManagedWebAccountStore(root: root, fileManager: fileManager).remove(account)
            } else if !isAuthenticated(profile), fileManager.fileExists(atPath: profile.directory.path) {
                try? fileManager.removeItem(at: profile.directory)
            }
            return
        }
        if profile.provider == .antigravity, let id = UUID(uuidString: profile.slug),
           !isAuthenticated(profile) {
            try? AntigravityManagedAccountStore(root: root, fileManager: fileManager).remove(id: id)
            return
        }
        if wasNew, (profile.provider == .cursor || profile.provider == .grok || profile.provider == .kimi),
           !isAuthenticated(profile), fileManager.fileExists(atPath: profile.directory.path) {
            try? fileManager.removeItem(at: profile.directory)
            return
        }
        guard !isAuthenticated(profile),
              let contents = try? fileManager.contentsOfDirectory(atPath: profile.directory.path),
              contents.isEmpty else { return }
        try? fileManager.removeItem(at: profile.directory)
    }

    func reload() { profilesChanged() }

    /// Rejects a second managed login for the same provider identity. Account
    /// names are only labels; the authenticated email is the durable identity.
    func validateUniqueIdentity(_ profile: CreatedProfile) throws {
        guard let email = authenticatedEmail(for: profile)?.normalizedAccountEmail else { return }
        let duplicate: Bool
        switch profile.provider {
        case .codex:
            duplicate = managedCodexProfiles.contains { candidate in
                candidate.id != profile.id &&
                    authenticatedEmail(for: candidate)?.normalizedAccountEmail == email
            }
        case .claude:
            let profiles = ClaudeProfile.discoverManaged(
                fileManager: fileManager,
                root: root.appendingPathComponent("claude", isDirectory: true)
            )
            duplicate = profiles.contains { candidate in
                candidate.id != profile.id &&
                    candidate.signedInAddress()?.normalizedAccountEmail == email
            }
        case .cursor:
            duplicate = managedCursorProfiles.contains { candidate in
                candidate.id != profile.id &&
                    authenticatedEmail(for: candidate)?.normalizedAccountEmail == email
            }
        case .grok, .kimi:
            duplicate = managedCLIProfiles(profile.provider).contains { candidate in
                candidate.id != profile.id &&
                    authenticatedEmail(for: candidate)?.normalizedAccountEmail == email
            }
        case .antigravity:
            duplicate = managedAntigravityAccounts.contains { account in
                "antigravity-managed-\(account.id.uuidString.lowercased())" != profile.id &&
                    account.email?.normalizedAccountEmail == email
            }
        case .kiro, .deepseek, .qianwenai, .minimax, .ollama, .apify, .glm, .amp, .kilo, .opencode, .copilot:
            duplicate = false // These sites expose a session fingerprint, not an email address.
        }
        if duplicate { throw ProfileError.emailAlreadyAdded(profile.provider.title, email) }
    }

    var managedAntigravityAccounts: [AntigravityManagedAccount] {
        AntigravityManagedAccountStore(root: root, fileManager: fileManager).accounts()
    }

    func managedWebAccounts(_ provider: Provider) -> [ManagedWebAccount] {
        ManagedWebAccountStore(root: root, fileManager: fileManager).accounts(provider: provider.rawValue)
    }

    func managedSecretAccounts(_ provider: Provider) -> [ManagedSecretAccount] {
        ManagedSecretAccountStore(root: root, fileManager: fileManager).accounts(provider: provider.rawValue)
    }

    func remove(_ account: ManagedSecretAccount) throws {
        try ManagedSecretAccountStore(root: root, fileManager: fileManager).remove(account)
        states.removeValue(forKey: account.providerID)
        profilesChanged()
    }

    func remove(_ account: ManagedWebAccount) throws {
        webAuthenticators.removeValue(forKey: account.providerID)
        try ManagedWebAccountStore(root: root, fileManager: fileManager).remove(account)
        states.removeValue(forKey: account.providerID)
        profilesChanged()
    }

    private func authenticateWeb(_ profile: CreatedProfile) {
        guard let uuid = UUID(uuidString: profile.slug) else {
            states[profile.id] = .failed("The browser account identifier is invalid.")
            return
        }
        let site: WebSessionProvider.Site = switch profile.provider {
        case .deepseek: Sites.deepSeek
        case .qianwenai: Sites.qianwen
        case .minimax: Sites.minimax(region: Preferences.storedMinimaxRegion())
        default: Sites.deepSeek
        }
        let provider = WebSessionProvider(site: site, accountID: uuid, displayName: profile.name)
        webAuthenticators[profile.id] = provider
        states[profile.id] = .waitingForBrowser
        provider.onAuthenticated = { [weak self, weak provider] in
            guard let self, let provider else { return }
            if let fingerprint = provider.authenticationFingerprint {
                let duplicate = ManagedWebAccountStore(root: self.root, fileManager: self.fileManager)
                    .accounts(provider: profile.provider.rawValue)
                    .contains { candidate in
                        candidate.providerID != profile.id &&
                        UserDefaults.standard.string(forKey: "\(candidate.providerID).authFingerprint") == fingerprint
                    }
                if duplicate {
                    if let account = ManagedWebAccountStore(root: self.root, fileManager: self.fileManager)
                        .accounts(provider: profile.provider.rawValue)
                        .first(where: { $0.providerID == profile.id }) {
                        try? ManagedWebAccountStore(root: self.root, fileManager: self.fileManager).remove(account)
                    }
                    self.states[profile.id] = .failed("This \(profile.provider.title) account is already added.")
                    return
                }
            }
            self.states[profile.id] = .success
            self.newlyCreatedProfiles.remove(profile.id)
            self.profilesChanged()
        }
        provider.presentSignIn()
    }

    var managedCodexProfiles: [CreatedProfile] {
        CodexProfile.discoverManaged(
            fileManager: fileManager,
            root: root.appendingPathComponent("codex", isDirectory: true)
        ).compactMap { profile in
            guard profile.isManaged else { return nil }
            let slug = profile.configDirectory.lastPathComponent
            return CreatedProfile(provider: .codex,
                                  id: "codex-managed-\(slug)",
                                  name: slug.replacingOccurrences(of: "-", with: " ").capitalized,
                                  slug: slug,
                                  directory: profile.configDirectory)
        }
    }

    var managedClaudeProfiles: [CreatedProfile] {
        ClaudeProfile.discoverManaged(
            fileManager: fileManager,
            root: root.appendingPathComponent("claude", isDirectory: true)
        ).compactMap { profile in
            guard profile.isManaged,
                  let managedSlug = profile.slug?.removingPrefix("managed-"),
                  !managedSlug.isEmpty else { return nil }
            return CreatedProfile(provider: .claude,
                                  id: "claude-managed-\(managedSlug)",
                                  name: managedSlug.replacingOccurrences(of: "-", with: " ").capitalized,
                                  slug: managedSlug,
                                  directory: profile.configDirectory)
        }
    }

    var managedCursorProfiles: [CreatedProfile] {
        let cursorRoot = root.appendingPathComponent("cursor", isDirectory: true)
        return ((try? fileManager.contentsOfDirectory(at: cursorRoot,
                    includingPropertiesForKeys: [.isDirectoryKey])) ?? []).compactMap { directory in
            guard CursorCredentials.managedAccount(in: directory) != nil else { return nil }
            let slug = directory.lastPathComponent
            return CreatedProfile(provider: .cursor, id: "cursor-managed-\(slug)",
                name: slug.replacingOccurrences(of: "-", with: " ").capitalized,
                slug: slug, directory: directory)
        }
    }

    func managedCLIProfiles(_ provider: Provider) -> [CreatedProfile] {
        guard provider == .grok || provider == .kimi else { return [] }
        let providerRoot = root.appendingPathComponent(provider.rawValue, isDirectory: true)
        return ((try? fileManager.contentsOfDirectory(at: providerRoot,
                    includingPropertiesForKeys: [.isDirectoryKey])) ?? []).compactMap { directory in
            let slug = directory.lastPathComponent
            let id = "\(provider.rawValue)-managed-\(slug)"
            let profile = CreatedProfile(provider: provider, id: id,
                name: slug.replacingOccurrences(of: "-", with: " ").capitalized,
                slug: slug, directory: directory)
            return isAuthenticated(profile) ? profile : nil
        }
    }

    func reauthenticate(_ profile: CreatedProfile) {
        guard profile.provider == .codex || profile.provider == .claude || profile.provider == .cursor
                || profile.provider == .grok || profile.provider == .kimi else { return }
        authenticate(profile)
    }

    func removeCodex(_ profile: CreatedProfile) throws {
        guard profile.provider == .codex else { return }
        cancelProcess(profile.id)
        let codexRoot = root.appendingPathComponent("codex", isDirectory: true)
            .standardizedFileURL
        let directory = profile.directory.standardizedFileURL
        guard directory.deletingLastPathComponent() == codexRoot else {
            throw ProfileError.cannotCreate("The managed Codex profile path is invalid.")
        }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        states.removeValue(forKey: profile.id)
        profilesChanged()
    }

    func removeClaude(_ profile: CreatedProfile) throws {
        guard profile.provider == .claude else { return }
        cancelProcess(profile.id)
        let claudeRoot = root.appendingPathComponent("claude", isDirectory: true)
            .standardizedFileURL
        let directory = profile.directory.standardizedFileURL
        guard directory.deletingLastPathComponent() == claudeRoot else {
            throw ProfileError.cannotCreate("The managed Claude profile path is invalid.")
        }
        let claudeProfile = ClaudeProfile(slug: "managed-\(profile.slug)",
                                          configDirectory: directory)
        for service in claudeProfile.keychainServices {
            _ = KeychainItem.deleteAll(service: service)
        }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        states.removeValue(forKey: profile.id)
        profilesChanged()
    }

    func removeCursor(_ profile: CreatedProfile) throws {
        guard profile.provider == .cursor else { return }
        cancelProcess(profile.id)
        let cursorRoot = root.appendingPathComponent("cursor", isDirectory: true).standardizedFileURL
        let directory = profile.directory.standardizedFileURL
        guard directory.deletingLastPathComponent() == cursorRoot else {
            throw ProfileError.cannotCreate("The managed Cursor profile path is invalid.")
        }
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
        states.removeValue(forKey: profile.id)
        profilesChanged()
    }

    func removeCLIProfile(_ profile: CreatedProfile) throws {
        guard profile.provider == .grok || profile.provider == .kimi else { return }
        cancelProcess(profile.id)
        let expectedRoot = root.appendingPathComponent(profile.provider.rawValue, isDirectory: true).standardizedFileURL
        let directory = profile.directory.standardizedFileURL
        guard directory.deletingLastPathComponent() == expectedRoot else {
            throw ProfileError.cannotCreate("The managed profile path is invalid.")
        }
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
        states.removeValue(forKey: profile.id)
        profilesChanged()
    }

    func reauthenticate(_ account: AntigravityManagedAccount) {
        authenticate(CreatedProfile(provider: .antigravity,
                                    id: "antigravity-managed-\(account.id.uuidString.lowercased())",
                                    name: account.name,
                                    slug: account.id.uuidString.lowercased(),
                                    directory: account.directory))
    }

    func remove(_ account: AntigravityManagedAccount) throws {
        let profileID = "antigravity-managed-\(account.id.uuidString.lowercased())"
        oauthTasks.removeValue(forKey: profileID)?.cancel()
        try AntigravityManagedAccountStore(root: root, fileManager: fileManager).remove(id: account.id)
        states.removeValue(forKey: profileID)
        profilesChanged()
    }

    private func cancelProcess(_ id: String) {
        guard let process = processes.removeValue(forKey: id), process.isRunning else { return }
        process.terminate()
    }

    private func authenticateAntigravity(_ profile: CreatedProfile) {
        guard let id = UUID(uuidString: profile.slug) else {
            states[profile.id] = .failed("The Antigravity account identifier is invalid.")
            return
        }
        oauthTasks.removeValue(forKey: profile.id)?.cancel()
        states[profile.id] = .waitingForBrowser
        let account = AntigravityManagedAccount(id: id, name: profile.name, email: nil, directory: profile.directory)
        oauthTasks[profile.id] = Task { [weak self] in
            do {
                _ = try await AntigravityOAuthLogin.authenticate(account: account)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                do {
                    try self.validateUniqueIdentity(profile)
                    self.newlyCreatedProfiles.remove(profile.id)
                    self.states[profile.id] = .success
                    self.oauthTasks.removeValue(forKey: profile.id)
                    self.profilesChanged()
                } catch {
                    self.discardNewDuplicate(profile)
                    self.states[profile.id] = .failed(error.localizedDescription)
                    self.oauthTasks.removeValue(forKey: profile.id)
                }
            } catch is CancellationError {
                self?.states[profile.id] = .idle
            } catch {
                self?.states[profile.id] = .failed(error.localizedDescription)
                self?.oauthTasks.removeValue(forKey: profile.id)
            }
        }
    }

    private func executable(for authenticator: any ManagedAccountAuthenticator) -> URL? {
        if let override = executableOverrides[authenticator.provider] { return override }
        return authenticator.executableCandidates.first(where: fileManager.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    private func authenticatedEmail(for profile: CreatedProfile) -> String? {
        switch profile.provider {
        case .codex:
            CodexCredentials.account(from: profile.directory.appendingPathComponent("auth.json"))?.label
        case .claude:
            ClaudeProfile(slug: "managed-\(profile.slug)", configDirectory: profile.directory)
                .signedInAddress()
        case .cursor:
            CursorCredentials.managedAccount(in: profile.directory)?.label
        case .grok:
            GrokCredentials.account(from: profile.directory.appendingPathComponent("auth.json"))?.label
        case .kimi:
            KimiCredentials.account(from: profile.directory.appendingPathComponent("credentials/kimi-code.json"))?.label
        case .antigravity:
            UUID(uuidString: profile.slug)
                .flatMap(AntigravityManagedCredentialsStore.load(accountID:))?.email
        case .kiro, .deepseek, .qianwenai, .minimax, .ollama, .apify, .glm, .amp, .kilo, .opencode, .copilot:
            nil
        }
    }

    private func discardNewDuplicate(_ profile: CreatedProfile) {
        guard newlyCreatedProfiles.remove(profile.id) != nil else { return }
        if profile.provider == .antigravity, let id = UUID(uuidString: profile.slug) {
            try? AntigravityManagedAccountStore(root: root, fileManager: fileManager).remove(id: id)
        } else if fileManager.fileExists(atPath: profile.directory.path) {
            try? fileManager.removeItem(at: profile.directory)
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }

    var normalizedAccountEmail: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.contains("@") ? value : nil
    }
}
