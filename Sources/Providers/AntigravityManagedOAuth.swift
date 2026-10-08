import AppKit
import Darwin
import Foundation
import Network

struct AntigravityManagedAccount: Codable, Equatable {
    let id: UUID
    var name: String
    var email: String?
    var directory: URL

    enum CodingKeys: String, CodingKey { case id, name, email }

    init(id: UUID, name: String, email: String?, directory: URL) {
        self.id = id; self.name = name; self.email = email; self.directory = directory
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        email = try values.decodeIfPresent(String.self, forKey: .email)
        directory = URL(fileURLWithPath: "")
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(email, forKey: .email)
    }
}

struct AntigravityManagedAccountStore {
    let root: URL
    let fileManager: FileManager
    init(root: URL = AccountProfileManager.managedRoot(), fileManager: FileManager = .default) {
        self.root = root.appendingPathComponent("antigravity", isDirectory: true)
        self.fileManager = fileManager
    }

    func create(name: String) throws -> AntigravityManagedAccount {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let account = AntigravityManagedAccount(id: id, name: name, email: nil, directory: directory)
        try save(account)
        return account
    }

    func save(_ account: AntigravityManagedAccount) throws {
        try fileManager.createDirectory(at: account.directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(account)
        try data.write(to: account.directory.appendingPathComponent("account.json"), options: .atomic)
    }

    func accounts() -> [AntigravityManagedAccount] {
        let urls = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { directory in
            let url = directory.appendingPathComponent("account.json")
            guard let data = try? Data(contentsOf: url),
                  var account = try? JSONDecoder().decode(AntigravityManagedAccount.self, from: data),
                  AntigravityManagedCredentialsStore.exists(accountID: account.id)
            else { return nil }
            account.directory = directory
            return account
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func updateIdentity(id: UUID, email: String?) throws {
        let directory = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        let url = directory.appendingPathComponent("account.json")
        var account = try JSONDecoder().decode(AntigravityManagedAccount.self, from: Data(contentsOf: url))
        account.directory = directory
        account.email = email
        try save(account)
    }

    func remove(id: UUID) throws {
        _ = AntigravityManagedCredentialsStore.delete(accountID: id)
        let directory = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    }
}

struct AntigravityOAuthCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiryMilliseconds: Double
    var idToken: String?
    var email: String?
    var projectID: String?
    var clientID: String
    var clientSecret: String
    var expiryDate: Date { Date(timeIntervalSince1970: expiryMilliseconds / 1000) }
}

enum AntigravityManagedCredentialsStore {
    private static let service = "com.vinz.codenotch.antigravity-oauth"
    static func exists(accountID: UUID) -> Bool {
        KeychainItem.modifiedAt(service: service, account: accountID.uuidString.lowercased()) != nil
    }
    static func load(accountID: UUID) -> AntigravityOAuthCredentials? {
        guard let value = KeychainItem.read(service: service, account: accountID.uuidString.lowercased()),
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data)
    }
    @discardableResult static func save(_ value: AntigravityOAuthCredentials, accountID: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return false }
        return KeychainItem.store(service: service, account: accountID.uuidString.lowercased(), value: text)
    }
    @discardableResult static func delete(accountID: UUID) -> Bool {
        KeychainItem.delete(service: service, account: accountID.uuidString.lowercased())
    }
}

struct AntigravityOAuthClient { let id: String; let secret: String }

enum AntigravityOAuthConfiguration {
    static let authorizationURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
    static let scopes = ["https://www.googleapis.com/auth/cloud-platform", "https://www.googleapis.com/auth/userinfo.email"]
    private static let installedClient: AntigravityOAuthClient? = discoverInstalled()

    static func resolved(fileManager: FileManager = .default) -> AntigravityOAuthClient? {
        if let id = ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_ID"]?.trimmedNonEmpty,
           let secret = ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]?.trimmedNonEmpty {
            return .init(id: id, secret: secret)
        }
        return installedClient
    }

    private static func discoverInstalled(fileManager: FileManager = .default) -> AntigravityOAuthClient? {
        let roots = [URL(fileURLWithPath: "/Applications"), fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let relative = [
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos",
            "Contents/Resources/app/out/main.js", "Contents/Resources/bin/language_server",
            "Contents/Resources/bin/language_server_macos", "Contents/MacOS/Gemini"
        ]
        var bundles: [URL] = []
        for root in roots {
            bundles.append(root.appendingPathComponent("Antigravity.app"))
            let apps = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            bundles += apps.filter { ["com.google.antigravity", "com.google.antigravity-ide", "com.google.GeminiMacOS"].contains(Bundle(url: $0)?.bundleIdentifier) }
        }
        for artifact in bundles.flatMap({ bundle in relative.map { bundle.appendingPathComponent($0) } }) {
            guard let data = try? Data(contentsOf: artifact, options: .mappedIfSafe), let client = parse(data) else { continue }
            return client
        }
        return nil
    }

    static func parse(_ data: Data) -> AntigravityOAuthClient? {
        // Electron's main.js contains several Google OAuth clients. Anchor the
        // search to Antigravity's own Cloud Code module so an unrelated client
        // ID is never paired with its secret. This is the format used by the
        // current Antigravity application; the byte scan below remains the
        // fallback for native or non-UTF-8 artifacts.
        if let content = String(data: data, encoding: .utf8),
           let client = parseInstalledText(content) {
            return client
        }

        let suffix = Data(".apps.googleusercontent.com".utf8)
        var ids: [String] = []
        var range = data.startIndex..<data.endIndex
        while let found = data.range(of: suffix, in: range) {
            var start = found.lowerBound
            while start > data.startIndex {
                let byte = data[data.index(before: start)]
                guard isOAuthByte(byte) else { break }
                start = data.index(before: start)
            }
            if let value = String(data: data[start..<found.upperBound], encoding: .ascii),
               value.range(of: #"^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#,
                           options: .regularExpression) != nil, !ids.contains(value) { ids.append(value) }
            range = found.upperBound..<data.endIndex
        }
        let prefix = Data("GOCSPX-".utf8)
        var secrets: [String] = []; range = data.startIndex..<data.endIndex
        while let found = data.range(of: prefix, in: range) {
            let end = found.lowerBound + 35
            if end <= data.endIndex, data[found.lowerBound..<end].allSatisfy(isOAuthByte),
               let value = String(data: data[found.lowerBound..<end], encoding: .ascii), !secrets.contains(value) {
                secrets.append(value)
            }
            range = found.upperBound..<data.endIndex
        }
        guard !ids.isEmpty, !secrets.isEmpty else { return nil }
        if secrets.count == 1 && ids.count > 1 { return .init(id: ids.last!, secret: secrets[0]) }
        return .init(id: ids[0], secret: secrets.count == ids.count && secrets.count > 1 ? secrets.last! : secrets[0])
    }

    static func parseInstalledText(_ content: String) -> AntigravityOAuthClient? {
        let marker = "vs/platform/cloudCode/common/oauthClient.js"
        let searchStart = content.range(of: marker)?.lowerBound ?? content.startIndex
        let searchEnd = content.index(searchStart, offsetBy: 4000, limitedBy: content.endIndex) ?? content.endIndex
        let haystack = String(content[searchStart..<searchEnd])
        guard let id = firstMatch(#"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#, in: haystack),
              let secret = firstMatch(#"GOCSPX-[A-Za-z0-9_-]{28}"#, in: haystack) else { return nil }
        return .init(id: id, secret: secret)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func isOAuthByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) || byte == 45 || byte == 95
    }
}

enum AntigravityOAuthLogin {
    enum LoginError: LocalizedError {
        case unavailable, invalidCallback, stateMismatch, denied(String), token(String), keychain
        var errorDescription: String? {
            switch self {
            case .unavailable: "Antigravity OAuth configuration was not found. Install Antigravity.app first."
            case .invalidCallback: "Google did not return a valid authorization code."
            case .stateMismatch: "Google login state did not match."
            case .denied(let message), .token(let message): message
            case .keychain: "The Antigravity account could not be saved securely in Keychain."
            }
        }
    }

    static func authenticate(account: AntigravityManagedAccount) async throws -> String? {
        guard let client = AntigravityOAuthConfiguration.resolved() else { throw LoginError.unavailable }
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = AntigravityOAuthLoopback(state: state)
        let redirect = try await server.start()
        defer { server.stop() }
        var components = URLComponents(url: AntigravityOAuthConfiguration.authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: client.id), .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: AntigravityOAuthConfiguration.scopes.joined(separator: " ")),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "select_account consent"), .init(name: "state", value: state)
        ]
        guard let url = components.url, await MainActor.run(body: { NSWorkspace.shared.open(url) }) else { throw LoginError.invalidCallback }
        let callback = try await server.callback(timeout: 120)
        if let error = callback.error { throw LoginError.denied(error) }
        guard callback.state == state else { throw LoginError.stateMismatch }
        guard let code = callback.code else { throw LoginError.invalidCallback }
        let token = try await exchange(code: code, redirect: redirect, client: client)
        let email = await fetchEmail(accessToken: token.accessToken)
        let credentials = AntigravityOAuthCredentials(accessToken: token.accessToken, refreshToken: token.refreshToken,
            expiryMilliseconds: Date().addingTimeInterval(TimeInterval(token.expiresIn)).timeIntervalSince1970 * 1000,
            idToken: token.idToken, email: email, projectID: nil, clientID: client.id, clientSecret: client.secret)
        guard AntigravityManagedCredentialsStore.save(credentials, accountID: account.id) else { throw LoginError.keychain }
        try AntigravityManagedAccountStore(root: account.directory.deletingLastPathComponent().deletingLastPathComponent()).updateIdentity(id: account.id, email: email)
        return email
    }

    private struct Token: Decodable {
        let accessToken: String; let refreshToken: String?; let expiresIn: Int; let idToken: String?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", idToken = "id_token" }
    }
    private static func exchange(code: String, redirect: URL, client: AntigravityOAuthClient) async throws -> Token {
        var request = URLRequest(url: AntigravityOAuthConfiguration.tokenURL); request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["code": code, "client_id": client.id, "client_secret": client.secret,
                                 "redirect_uri": redirect.absoluteString, "grant_type": "authorization_code"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LoginError.token(String(data: data, encoding: .utf8) ?? "Google token exchange failed.") }
        return try JSONDecoder().decode(Token.self, from: data)
    }
    private static func fetchEmail(accessToken: String) async -> String? {
        var request = URLRequest(url: AntigravityOAuthConfiguration.userInfoURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["email"] as? String
    }
    static func form(_ values: [String: String]) -> Data? {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "+&=")
        return values.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
    }
}

enum AntigravityManagedOAuth {
    static func validCredentials(accountID: UUID, session: URLSession = .shared) async throws -> AntigravityOAuthCredentials {
        guard var credentials = AntigravityManagedCredentialsStore.load(accountID: accountID) else {
            throw UsageProviderError.needsAuth
        }
        guard credentials.expiryDate.timeIntervalSinceNow <= 60 else { return credentials }
        guard let refresh = credentials.refreshToken?.trimmedNonEmpty else { throw UsageProviderError.credentialExpired }
        var request = URLRequest(url: AntigravityOAuthConfiguration.tokenURL); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = AntigravityOAuthLogin.form(["client_id": credentials.clientID,
            "client_secret": credentials.clientSecret, "refresh_token": refresh, "grant_type": "refresh_token"])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else { throw UsageProviderError.credentialExpired }
        credentials.accessToken = token
        let expires = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        credentials.expiryMilliseconds = Date().addingTimeInterval(expires).timeIntervalSince1970 * 1000
        if let idToken = json["id_token"] as? String { credentials.idToken = idToken }
        guard AntigravityManagedCredentialsStore.save(credentials, accountID: accountID) else {
            throw UsageProviderError.accessDenied
        }
        return credentials
    }
}

struct AntigravityOAuthCallback { let code: String?; let state: String?; let error: String? }

final class AntigravityOAuthLoopback: @unchecked Sendable {
    private let expectedState: String; private let queue = DispatchQueue(label: "codenotch.antigravity.oauth")
    private let lock = NSLock()
    private var listener: NWListener?; private var continuation: CheckedContinuation<AntigravityOAuthCallback, Error>?
    private var pendingResult: Result<AntigravityOAuthCallback, Error>?
    private var completed = false
    init(state: String) { expectedState = state }
    func start() async throws -> URL {
        let listener = try NWListener(using: .tcp, on: .any); self.listener = listener
        listener.newConnectionHandler = { [weak self] in self?.handle($0) }
        return try await withCheckedThrowingContinuation { ready in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    ready.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/callback")!)
                case .failed(let error): ready.resume(throwing: error)
                default: break
                }
            }; listener.start(queue: queue)
        }
    }
    func callback(timeout: TimeInterval) async throws -> AntigravityOAuthCallback {
        try await withThrowingTaskGroup(of: AntigravityOAuthCallback.self) { group in
            group.addTask { try await self.waitForCallback() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                let error = URLError(.timedOut)
                self.finish(.failure(error))
                throw error
            }
            defer { group.cancelAll() }; return try await group.next()!
        }
    }
    func stop() { listener?.cancel(); listener = nil }
    func completeForTesting(_ callback: AntigravityOAuthCallback) { finish(.success(callback)) }
    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let line = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first,
                  let target = line.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://127.0.0.1\(target)") else { return }
            let value: (String) -> String? = { name in components.queryItems?.first { $0.name == name }?.value }
            let callback = AntigravityOAuthCallback(code: value("code"), state: value("state"), error: value("error"))
            let ok = callback.code != nil && callback.error == nil && callback.state == expectedState
            let body = Data("<html><body style='font-family:-apple-system;text-align:center;padding:40px'><h1>\(ok ? "Account connected" : "Login failed")</h1><p>You can close this window and return to Codenotch.</p></body></html>".utf8)
            let header = Data("HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
            self.finish(.success(callback))
        }
    }

    private func waitForCallback() async throws -> AntigravityOAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                continuation.resume(with: pendingResult)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func finish(_ result: Result<AntigravityOAuthCallback, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

extension String { fileprivate var trimmedNonEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value } }
