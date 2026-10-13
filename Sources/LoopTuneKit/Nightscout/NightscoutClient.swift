import Foundation
import os

/// Abstraction over the network so the client can be exercised with stubbed
/// responses in tests.
public protocol NightscoutTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default transport backed by `URLSession`.
///
/// Every hop must satisfy the transport policy: HTTPS, or plain HTTP to a
/// loopback host. Redirects are followed only within the origin of the
/// original request; any other redirect is refused before the new request is
/// sent, so credentials never reach another site, and the call fails with
/// `NightscoutError.disallowedRedirect`. Certificate validation is the
/// session's default. See ADR 0006.
public struct URLSessionTransport: NightscoutTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url,
              let origin = SiteOrigin(url: url),
              TransportPolicy.permits(url) else {
            throw NightscoutError.invalidURL
        }
        let redirects = RedirectGuard(origin: origin)
        let (data, response) = try await session.data(for: request, delegate: redirects)
        guard !redirects.rejected else {
            throw NightscoutError.disallowedRedirect
        }
        guard let http = response as? HTTPURLResponse else {
            throw NightscoutError.invalidResponse
        }
        return (data, http)
    }
}

/// Per-task delegate that applies `TransportPolicy.permitsRedirect` to each
/// redirect. Refusing a redirect makes the session return the redirect
/// response itself, so the refusal is recorded for the transport to report.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: SiteOrigin
    private let refused = OSAllocatedUnfairLock(initialState: false)

    init(origin: SiteOrigin) {
        self.origin = origin
    }

    var rejected: Bool {
        refused.withLock { $0 }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, TransportPolicy.permitsRedirect(to: url, from: origin) else {
            refused.withLock { $0 = true }
            return nil
        }
        return request
    }
}

public enum NightscoutError: Error, Equatable {
    case invalidURL
    case invalidResponse
    /// A redirect left the request's origin or the transport policy.
    case disallowedRedirect
    case unauthorized
    case httpStatus(Int)
    case decoding(String)
    case partialDecoding(path: String, skipped: Int)
}

extension NightscoutError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Nightscout URL. Use HTTPS (plain HTTP is allowed only for localhost)."
        case .invalidResponse:
            return "Nightscout returned a non-HTTP response."
        case .disallowedRedirect:
            return "Nightscout redirected to a different scheme, host, or port, so the request was stopped. Enter the site's final address."
        case .unauthorized:
            return "Nightscout rejected the supplied credentials."
        case .httpStatus(let code):
            return "Nightscout returned HTTP \(code)."
        case .decoding(let detail):
            return "Nightscout JSON could not be decoded: \(detail)"
        case .partialDecoding(let path, let skipped):
            return "Nightscout returned \(skipped) malformed record\(skipped == 1 ? "" : "s") from \(path)."
        }
    }
}

/// A read-only client for a Nightscout site.
public struct NightscoutClient: Sendable {
    public let baseURL: URL
    /// The site identity used to keep data from different sites apart.
    public let origin: SiteOrigin
    public let credentials: NightscoutCredentials
    private let transport: NightscoutTransport

    /// Reduce a user-entered URL to its canonical origin URL: scheme, host,
    /// and a non-default port. Pasted paths and queries (users routinely paste
    /// `.../api/v1/...` or `?token=`) and URL user information are removed, so
    /// no request carries them. Credentials travel only in `credentials`.
    public init(rawURLString: String, credentials: NightscoutCredentials = .none, transport: NightscoutTransport = URLSessionTransport()) throws {
        guard let origin = Self.normalizedOrigin(rawURLString) else {
            throw NightscoutError.invalidURL
        }
        self.baseURL = origin.url
        self.origin = origin
        self.credentials = credentials
        self.transport = transport
    }

    public init(baseURL: URL, credentials: NightscoutCredentials = .none, transport: NightscoutTransport = URLSessionTransport()) throws {
        try self.init(rawURLString: baseURL.absoluteString, credentials: credentials, transport: transport)
    }

    /// The origin of a user-entered URL, if the transport policy permits it.
    /// The policy is checked on the host as entered, because canonicalizing
    /// can turn a spelling the loopback rule rejects, such as `[::0.0.0.1]`,
    /// into one it accepts.
    static func normalizedOrigin(_ raw: String) -> SiteOrigin? {
        guard let entered = SiteOrigin.url(fromUserInput: raw),
              TransportPolicy.permitsSite(entered),
              let origin = SiteOrigin(url: entered) else {
            return nil
        }
        return origin
    }

    static func normalizeBaseURL(_ raw: String) -> URL? {
        normalizedOrigin(raw)?.url
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

    /// Decode a JSON array element-by-element so partial corruption can be
    /// reported. Silently omitting glucose, doses, or settings could otherwise
    /// produce a plausible-looking recommendation from incomplete evidence.
    private func fetchArray<Element: Decodable>(_ type: Element.Type, path: String, queryItems: [URLQueryItem]) async throws -> [Element] {
        let data = try await fetchData(path: path, queryItems: queryItems)
        do {
            let decoded = try JSONDecoder().decode(LenientArray<Element>.self, from: data)
            guard decoded.skippedCount == 0 else {
                throw NightscoutError.partialDecoding(path: path, skipped: decoded.skippedCount)
            }
            return decoded.elements
        } catch let error as NightscoutError {
            throw error
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

    /// Steps per second the entry range filter can express (milliseconds).
    static let entriesRangeStepsPerSecond: Double = 1000
    /// Steps per second the treatment range filter can express: `iso(_:)`
    /// formats whole seconds.
    static let treatmentsRangeStepsPerSecond: Double = 1

    /// CGM entries in `[start, end]`. `date` is UTC epoch milliseconds.
    public func fetchEntries(from start: Date, to end: Date, count: Int = 1500) async throws -> [NSEntry] {
        let items = [
            URLQueryItem(name: "find[date][$gte]", value: Self.epochMilliseconds(start)),
            URLQueryItem(name: "find[date][$lte]", value: Self.epochMilliseconds(end)),
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

    /// Rounded rather than truncated, so a bound computed on the millisecond
    /// grid is not moved one step down by floating-point error.
    static func epochMilliseconds(_ date: Date) -> String {
        String(Int((date.timeIntervalSince1970 * 1000).rounded()))
    }
}
