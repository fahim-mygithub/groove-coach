import Foundation

/// Lightweight Supabase client using plain `URLSession` for auth and storage.
///
/// Avoids external SDK dependencies so the CocoaPods build remains clean and deterministic.
/// Base URL and anon key are loaded at runtime from Info.plist (`SUPABASE_URL`, `SUPABASE_ANON_KEY`),
/// falling back to safe placeholder defaults when not configured.
@MainActor
public final class SupabaseClient: ObservableObject {
    public static let shared = SupabaseClient()

    @Published public private(set) var currentSession: SupabaseSession?
    @Published public private(set) var isBusy: Bool = false

    public var isAuthenticated: Bool {
        currentSession != nil
    }

    public let baseURL: URL
    public let anonKey: String
    private let urlSession: URLSession

    private static let sessionDefaultsKey = "GrooveCoach.SupabaseSession"

    public init(
        baseURL: URL? = nil,
        anonKey: String? = nil,
        urlSession: URLSession = .shared
    ) {
        let plistURLString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
        let plistAnonKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String

        let resolvedURL: URL
        if let baseURL {
            resolvedURL = baseURL
        } else if let plistURLString, !plistURLString.isEmpty, let parsed = URL(string: plistURLString) {
            resolvedURL = parsed
        } else {
            resolvedURL = URL(string: "https://placeholder.supabase.co")!
        }

        let resolvedKey: String
        if let anonKey {
            resolvedKey = anonKey
        } else if let plistAnonKey, !plistAnonKey.isEmpty {
            resolvedKey = plistAnonKey
        } else {
            resolvedKey = "placeholder-anon-key"
        }

        self.baseURL = resolvedURL
        self.anonKey = resolvedKey
        self.urlSession = urlSession

        restoreSession()
    }

    // MARK: - Auth: Email OTP

    /// Send a 6-digit magic OTP code to the learner's email address.
    public func sendEmailOTP(email: String) async throws {
        isBusy = true
        defer { isBusy = false }

        let endpoint = baseURL.appendingPathComponent("auth/v1/otp")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "create_user": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        try checkResponse(response, data: data)
    }

    /// Verify the 6-digit OTP code sent to the email address.
    @discardableResult
    public func verifyEmailOTP(email: String, token: String) async throws -> SupabaseSession {
        isBusy = true
        defer { isBusy = false }

        let endpoint = baseURL.appendingPathComponent("auth/v1/verify")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "type": "email",
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "token": token.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        try checkResponse(response, data: data)

        let decoder = JSONDecoder()
        let session = try decoder.decode(SupabaseSession.self, from: data)
        saveSession(session)
        return session
    }

    // MARK: - Auth: Email + Password

    /// Sign in using email and password (POST auth/v1/token?grant_type=password).
    @discardableResult
    public func signInWithPassword(email: String, password: String) async throws -> SupabaseSession {
        isBusy = true
        defer { isBusy = false }

        var components = URLComponents(url: baseURL.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        guard let endpoint = components?.url else {
            throw SupabaseError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        try checkResponse(response, data: data)

        let decoder = JSONDecoder()
        let session = try decoder.decode(SupabaseSession.self, from: data)
        saveSession(session)
        return session
    }

    /// Sign up a new user using email and password (POST auth/v1/signup).
    @discardableResult
    public func signUp(email: String, password: String) async throws -> SupabaseSession {
        isBusy = true
        defer { isBusy = false }

        let endpoint = baseURL.appendingPathComponent("auth/v1/signup")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        try checkResponse(response, data: data)

        let decoder = JSONDecoder()
        guard let session = try? decoder.decode(SupabaseSession.self, from: data),
              !session.access_token.isEmpty else {
            throw SupabaseError.missingAccessToken("No access token returned from sign up. Email confirmation may be required.")
        }
        saveSession(session)
        return session
    }

    /// Refresh the session tokens using the stored refresh_token.
    @discardableResult
    public func refreshToken() async throws -> SupabaseSession {
        guard let current = currentSession, !current.refresh_token.isEmpty else {
            throw SupabaseError.notAuthenticated
        }

        isBusy = true
        defer { isBusy = false }

        var components = URLComponents(url: baseURL.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let endpoint = components?.url else {
            throw SupabaseError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "refresh_token": current.refresh_token
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        try checkResponse(response, data: data)

        let decoder = JSONDecoder()
        let session = try decoder.decode(SupabaseSession.self, from: data)
        saveSession(session)
        return session
    }

    /// Sign out the current user and discard cached session tokens.
    public func signOut() {
        currentSession = nil
        UserDefaults.standard.removeObject(forKey: Self.sessionDefaultsKey)
    }

    // MARK: - Catalog REST Select

    /// Query the `catalog` view from Postgres (`GET /rest/v1/catalog?select=*`).
    public func selectCatalog() async throws -> [CatalogItem] {
        isBusy = true
        defer { isBusy = false }

        var components = URLComponents(url: baseURL.appendingPathComponent("rest/v1/catalog"), resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "select", value: "*")]
        guard let endpoint = components?.url else {
            throw SupabaseError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        let bearerToken = currentSession?.access_token ?? anonKey
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        try checkResponse(response, data: data)

        let decoder = JSONDecoder()
        return try decoder.decode([CatalogItem].self, from: data)
    }

    // MARK: - Storage GET

    /// Download an object from Supabase Storage (e.g. `lesson-packages` bucket) directly to a local destination URL.
    public func downloadStorageObject(
        bucket: String,
        path: String,
        destinationURL: URL
    ) async throws {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Check authenticated vs public storage endpoint.
        let storageEndpoint: URL
        if currentSession != nil {
            storageEndpoint = baseURL.appendingPathComponent("storage/v1/object/authenticated/\(bucket)/\(cleanPath)")
        } else {
            storageEndpoint = baseURL.appendingPathComponent("storage/v1/object/\(bucket)/\(cleanPath)")
        }

        var request = URLRequest(url: storageEndpoint)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        let bearerToken = currentSession?.access_token ?? anonKey
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

        let (tempURL, response) = try await urlSession.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError(NSError(domain: "SupabaseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = (try? String(contentsOf: tempURL)) ?? "HTTP \(httpResponse.statusCode)"
            throw SupabaseError.requestFailed(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }

    /// Fetch raw data of a storage object.
    public func fetchStorageData(bucket: String, path: String) async throws -> Data {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let storageEndpoint: URL
        if currentSession != nil {
            storageEndpoint = baseURL.appendingPathComponent("storage/v1/object/authenticated/\(bucket)/\(cleanPath)")
        } else {
            storageEndpoint = baseURL.appendingPathComponent("storage/v1/object/\(bucket)/\(cleanPath)")
        }

        var request = URLRequest(url: storageEndpoint)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        let bearerToken = currentSession?.access_token ?? anonKey
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        try checkResponse(response, data: data)
        return data
    }

    // MARK: - Internal Helpers

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError(NSError(domain: "SupabaseClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message: String
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorDesc = (json["msg"] as? String) ?? (json["error_description"] as? String) ?? (json["message"] as? String) {
                message = errorDesc
            } else {
                message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            }
            throw SupabaseError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func saveSession(_ session: SupabaseSession) {
        currentSession = session
        if let encoded = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(encoded, forKey: Self.sessionDefaultsKey)
        }
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionDefaultsKey),
              let session = try? JSONDecoder().decode(SupabaseSession.self, from: data) else {
            return
        }
        currentSession = session
    }
}

// MARK: - Models & Errors

public struct SupabaseSession: Codable, Equatable {
    public let access_token: String
    public let token_type: String
    public let expires_in: Int
    public let refresh_token: String
    public let user: SupabaseUser?

    public init(
        access_token: String,
        token_type: String = "bearer",
        expires_in: Int = 3600,
        refresh_token: String,
        user: SupabaseUser? = nil
    ) {
        self.access_token = access_token
        self.token_type = token_type
        self.expires_in = expires_in
        self.refresh_token = refresh_token
        self.user = user
    }
}

public struct SupabaseUser: Codable, Equatable {
    public let id: String
    public let email: String?

    public init(id: String, email: String?) {
        self.id = id
        self.email = email
    }
}

public enum SupabaseError: LocalizedError {
    case invalidURL
    case requestFailed(statusCode: Int, message: String)
    case notAuthenticated
    case networkError(Error)
    case missingAccessToken(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Supabase URL."
        case .requestFailed(let code, let msg):
            return "Supabase error (\(code)): \(msg)"
        case .notAuthenticated:
            return "Not authenticated with Supabase."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .missingAccessToken(let msg):
            return msg
        }
    }
}
