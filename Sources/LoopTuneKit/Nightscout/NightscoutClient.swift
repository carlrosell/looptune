import Foundation

/// Abstraction over the network so the client can be exercised with stubbed
/// responses in tests.
public protocol NightscoutTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default transport backed by `URLSession`.
public struct URLSessionTransport: NightscoutTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NightscoutError.invalidResponse
        }
        return (data, http)
    }
}

public enum NightscoutError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case unauthorized
    case httpStatus(Int)
    case decoding(String)
}

/// A read-only client for a Nightscout site.
public struct NightscoutClient: Sendable {
    public let baseURL: URL
    public let credentials: NightscoutCredentials
    private let transport: NightscoutTransport

    /// Normalize a user-entered URL down to scheme + host (+ port), stripping any
    /// pasted path/query (users routinely paste `.../api/v1/...` or `?token=`).
    public init(rawURLString: String, credentials: NightscoutCredentials = .none, transport: NightscoutTransport = URLSessionTransport()) throws {
        guard let normalized = Self.normalizeBaseURL(rawURLString) else {
            throw NightscoutError.invalidURL
        }
        self.baseURL = normalized
        self.credentials = credentials
        self.transport = transport
    }

    public init(baseURL: URL, credentials: NightscoutCredentials = .none, transport: NightscoutTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
    }

    static func normalizeBaseURL(_ raw: String) -> URL? {
        var string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        if !string.contains("://") {
            string = "https://" + string
        }
        guard var components = URLComponents(string: string), let host = components.host, !host.isEmpty else {
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        if components.scheme == nil { components.scheme = "https" }
        return components.url
    }

    // MARK: - Request building

    func makeRequest(path: String, queryItems: [URLQueryItem]) -> URLRequest? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = path
        var items = queryItems
        if let token = credentials.tokenQueryValue {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret = credentials.apiSecretHeader {
            request.setValue(secret, forHTTPHeaderField: "api-secret")
        }
        return request
    }

    private func fetchData(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        guard let request = makeRequest(path: path, queryItems: queryItems) else {
            throw NightscoutError.invalidURL
        }
        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw NightscoutError.unauthorized
        default:
            throw NightscoutError.httpStatus(response.statusCode)
        }
    }

    private func fetch<T: Decodable>(_ type: T.Type, path: String, queryItems: [URLQueryItem]) async throws -> T {
        let data = try await fetchData(path: path, queryItems: queryItems)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NightscoutError.decoding(String(describing: error))
        }
    }

    /// Decode a JSON array, skipping individual malformed elements.
    private func fetchArray<Element: Decodable>(_ type: Element.Type, path: String, queryItems: [URLQueryItem]) async throws -> [Element] {
        let data = try await fetchData(path: path, queryItems: queryItems)
        do {
            return try JSONDecoder().decode(LenientArray<Element>.self, from: data).elements
        } catch {
            throw NightscoutError.decoding(String(describing: error))
        }
    }

    // MARK: - Endpoints

    /// Probe authorization. Returns `true` if the site accepts our credentials.
    public func checkAuthorized() async -> Bool {
        guard let request = makeRequest(path: "/api/v1/experiments/test", queryItems: []) else { return false }
        guard let (_, response) = try? await transport.data(for: request) else { return false }
        return (200..<300).contains(response.statusCode)
    }

    /// Server status (units, version).
    public func fetchStatus() async throws -> NSStatus {
        try await fetch(NSStatus.self, path: "/api/v1/status.json", queryItems: [])
    }

    /// CGM entries in `[start, end]`. `date` is UTC epoch milliseconds.
    public func fetchEntries(from start: Date, to end: Date, count: Int = 1500) async throws -> [NSEntry] {
        let items = [
            URLQueryItem(name: "find[date][$gte]", value: String(Int(start.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "find[date][$lte]", value: String(Int(end.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "count", value: String(count)),
        ]
        return try await fetchArray(NSEntry.self, path: "/api/v1/entries/sgv.json", queryItems: items)
    }

    /// Treatments in `[start, end]`, filtered by `created_at`.
    public func fetchTreatments(from start: Date, to end: Date, count: Int = 1500) async throws -> [NSTreatment] {
        let items = [
            URLQueryItem(name: "find[created_at][$gte]", value: Self.iso(start)),
            URLQueryItem(name: "find[created_at][$lte]", value: Self.iso(end)),
            URLQueryItem(name: "count", value: String(count)),
        ]
        return try await fetchArray(NSTreatment.self, path: "/api/v1/treatments.json", queryItems: items)
    }

    /// The profile-document history (newest first).
    public func fetchProfiles(count: Int = 20) async throws -> [NSProfileDocument] {
        let items = [URLQueryItem(name: "count", value: String(count))]
        return try await fetchArray(NSProfileDocument.self, path: "/api/v1/profile.json", queryItems: items)
    }

    // ISO8601DateFormatter is documented thread-safe for formatting.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}
