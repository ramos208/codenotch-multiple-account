import Foundation

/// Token from `~/.kimi-code/credentials/kimi-code.json`.
///
/// Kimi Code CLI signs in through auth.kimi.com and writes the OAuth session
/// here — one file per managed provider, and `kimi-code` is the Kimi Code
/// account itself. Codenotch only reads it: the access token lives fifteen
/// minutes (`expires_in: 900`) and refreshing is the CLI's job, the same
/// bargain as Grok's — writing a new one would race the CLI for the file.
/// `KIMI_CODE_HOME` moves the whole data root, so the path honours it.
struct KimiCredentials {
    static let oauthTokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static var authURL: URL {
        let override = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]
            .flatMap { value -> String? in value.isEmpty ? nil : value }
        let root = override.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kimi-code")
        return root.appendingPathComponent("credentials/kimi-code.json")
    }

    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date

    var isExpired: Bool { expiresAt <= Date() }

    static func account(from url: URL = authURL) -> ProviderAccount? {
        guard (try? load(from: url)) != nil else { return nil }
        return ProviderAccount(
            label: nil,   // the token carries no address
            plan: nil,
            source: "Kimi Code",
            manageURL: URL(string: "https://www.kimi.com/code/console")
        )
    }

    static func load(from url: URL = authURL) throws -> KimiCredentials {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String, !token.isEmpty
        else { throw UsageProviderError.needsAuth }

        // `expires_at` is epoch seconds. A file without one is not a session
        // to trust with a request that cannot succeed.
        guard let expires = (root["expires_at"] as? NSNumber)?.doubleValue, expires > 0
        else { throw UsageProviderError.needsAuth }

        return KimiCredentials(accessToken: token,
                               refreshToken: root["refresh_token"] as? String,
                               expiresAt: Date(timeIntervalSince1970: expires))
    }

    static func live(from url: URL = authURL, session: URLSession = .shared) async throws -> KimiCredentials {
        let current = try load(from: url)
        guard current.isExpired else { return current }
        guard let refresh = current.refreshToken, !refresh.isEmpty else {
            throw UsageProviderError.credentialExpired
        }
        var request = URLRequest(url: oauthTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        request.httpBody = form([
            ("client_id", clientID), ("grant_type", "refresh_token"), ("refresh_token", refresh),
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              var updated = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = updated["access_token"] as? String, !token.isEmpty else {
            throw status == 401 || status == 403
                ? UsageProviderError.credentialExpired
                : UsageProviderError.badResponse(status: status)
        }
        let lifetime = (updated["expires_in"] as? NSNumber)?.doubleValue ?? 900
        updated["expires_at"] = Date().addingTimeInterval(lifetime).timeIntervalSince1970
        if updated["refresh_token"] == nil { updated["refresh_token"] = refresh }
        let encoded = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
        try encoded.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try load(from: url)
    }

    private static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&").data(using: .utf8)!
    }
}
