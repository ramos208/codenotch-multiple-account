import Foundation
import os

/// Reads Ollama cloud usage from `https://ollama.com/api/usage`, authenticating
/// with an API key the user provides in Settings or exports as
/// `OLLAMA_API_KEY`.
///
/// The only provider that owns its credential rather than borrowing one: the
/// key is stored in the login keychain under a service no other app uses, and
/// sign-out deletes it. Polling and error handling follow the same path every
/// other provider takes through `UsageStore`.
actor OllamaProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.ollama

    private let endpoint = URL(string: "https://ollama.com/api/usage")!
    private let session: URLSession
    private let loadKey: @Sendable () -> String?
    nonisolated private let keyIsPresent: @Sendable () -> Bool
    nonisolated private let deleteKey: @Sendable () -> Void

    init(id: String = "ollama", displayName: String = "Ollama",
         session: URLSession = .shared,
         loadKey: @escaping @Sendable () -> String? = { OllamaCredentials.load() },
         keyIsPresent: @escaping @Sendable () -> Bool = { OllamaCredentials.isPresent },
         deleteKey: @escaping @Sendable () -> Void = { _ = OllamaCredentials.delete() }) {
        self.id = id
        self.displayName = displayName
        self.session = session
        self.loadKey = loadKey
        self.keyIsPresent = keyIsPresent
        self.deleteKey = deleteKey
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Enter an Ollama API key below, or export OLLAMA_API_KEY in your shell."))
    }

    nonisolated func account() -> ProviderAccount? {
        guard keyIsPresent() else { return nil }
        return ProviderAccount(
            label: nil,
            plan: nil,
            source: "Ollama",
            manageURL: URL(string: "https://ollama.com/settings")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let key = loadKey() else { throw UsageProviderError.needsAuth }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        Log.usage.debug("ollama usage -> \(body.prefix(900), privacy: .private)")

        let result = try OllamaUsage.parse(body)
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: result.windows,
            headlineID: result.headlineID,
            weeklyID: "weekly"
        )
    }

    nonisolated func signOut() async {
        deleteKey()
    }

    nonisolated func forgetCachedCredential() {
        OllamaCredentials.forgetCached()
    }
}
