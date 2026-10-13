import Foundation

/// The text shown to a person for an error that stopped an analysis or fetch.
///
/// Every message is built from the error's type, case, and typed fields such
/// as counts, status codes, and dates. Text an error carries is never shown:
/// not its localized description, not its `String(describing:)` rendering, and
/// not its user info. Foundation network errors record the failing request URL,
/// and Nightscout access tokens travel in that URL's query. Network errors are
/// classified by domain and code, searching nested underlying errors, and
/// described without any URL. See ADR 0010.
public enum ErrorMessage {
    public static func describe(_ error: any Error) -> String {
        switch error {
        case let error as NightscoutError:
            return describe(error)
        case let error as TuningPipeline.PipelineError:
            return describe(error)
        case is CancellationError:
            return "The analysis was cancelled."
        default:
            if let failure = NetworkFailure(error) {
                return failure.message
            }
            return "An unexpected error occurred (\(diagnosticLabel(error)))."
        }
    }

    private static func describe(_ error: NightscoutError) -> String {
        switch error {
        case .unauthorized:
            return "Not authorized. Check your access token."
        case .invalidURL:
            return "That doesn't look like a valid Nightscout URL. Use an HTTPS address; plain HTTP is allowed only for localhost."
        case .invalidResponse:
            return "Nightscout returned a non-HTTP response."
        case .disallowedRedirect:
            return "Nightscout redirected to a different scheme, host, or port, so the request was stopped. Enter the site's final address."
        case let .httpStatus(code):
            return "Nightscout returned HTTP \(code)."
        case .decoding:
            // The detail describes the decoder's failure, which can quote the response.
            return "Nightscout returned data that LoopTune could not read. No recommendation was made."
        case let .partialDecoding(path, skipped):
            return "Nightscout returned \(skipped) malformed record\(skipped == 1 ? "" : "s") from \(requestPath(path)). No recommendation was made."
        }
    }

    private static func describe(_ error: TuningPipeline.PipelineError) -> String {
        switch error {
        case .noProfile:
            return "No profile found on this Nightscout site."
        case .noGlucose:
            return "Not enough glucose data in the selected window."
        case let .insufficientUsableData(minimum, actual):
            // Evidence is counted in five-minute intervals of CGM time.
            return "Only \(actual * 5) minutes of usable data remained; at least \(minimum * 5) are required. No recommendation was made."
        case .invalidAnalysisWindow:
            return "The selected analysis window is invalid."
        case let .invalidInput(field):
            return "The \(field) data is invalid, so no recommendation was made."
        case let .incompleteRecords(collection, start, end):
            return "Nightscout has more \(collection) between \(start.formatted()) and \(end.formatted()) than could be retrieved. No recommendation was made."
        case let .incompleteProfileHistory(requiredFrom):
            return "Nightscout's profile history does not show the settings active at \(requiredFrom.formatted()). No recommendation was made."
        case .unsupportedCarbAbsorption:
            return error.errorDescription ?? "A carb entry has an unsupported absorption time. No recommendation was made."
        }
    }

    /// The path of a request, without a scheme, host, user information, query,
    /// or fragment. The client passes a fixed API path, but the case is public.
    static func requestPath(_ path: String) -> String {
        let bare = URLComponents(string: path)?.percentEncodedPath ?? ""
        return bare.isEmpty ? "a Nightscout response" : bare
    }

    /// Names an unclassified error without using any text it carries: the
    /// domain and code of an NSError from a known system domain, otherwise
    /// the error's type.
    static func diagnosticLabel(_ error: any Error) -> String {
        let nsError = error as NSError
        if Swift.type(of: error) is NSError.Type || error is any CustomNSError {
            return systemDomains.contains(nsError.domain)
                ? "\(nsError.domain) \(nsError.code)"
                : "error \(nsError.code)"
        }
        return String(reflecting: Swift.type(of: error))
    }

    private static let systemDomains: Set<String> = [
        NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain, NSOSStatusErrorDomain,
        NetworkFailure.cfNetworkDomain,
    ]
}

/// A network failure recognized from an error's domain and code, or from those
/// of an error nested under `NSUnderlyingErrorKey`. The outermost specific
/// classification wins; a generic code such as `NSURLErrorUnknown` defers to
/// the errors beneath it.
enum NetworkFailure: Equatable {
    case offline
    case cannotConnect
    case hostNotFound
    case secureConnection
    case timedOut
    case tooManyRedirects
    case unreadableResponse
    case unauthorized
    case invalidURL
    case cancelled
    case other(code: Int)

    static let cfNetworkDomain = kCFErrorDomainCFNetwork as String

    /// Underlying errors can nest; stop at a fixed depth in case one cycles.
    private static let maximumDepth = 8

    init?(_ error: any Error) {
        var generic: NetworkFailure?
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < Self.maximumDepth {
            if let failure = Self.classify(domain: nsError.domain, code: nsError.code) {
                guard case .other = failure else {
                    self = failure
                    return
                }
                generic = generic ?? failure
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        guard let generic else { return nil }
        self = generic
    }

    private static func classify(domain: String, code: Int) -> NetworkFailure? {
        switch domain {
        case NSURLErrorDomain, cfNetworkDomain:
            // CFNetwork reports URL loading failures with the same codes.
            return classifyURLError(code: code)
        case NSPOSIXErrorDomain:
            return classifyPOSIX(code: code)
        case NSOSStatusErrorDomain:
            // Secure Transport and TLS statuses: errSSLProtocol (-9800) through -9899.
            return (-9899)...(-9800) ~= code ? .secureConnection : nil
        default:
            return nil
        }
    }

    private static func classifyURLError(code: Int) -> NetworkFailure? {
        switch URLError.Code(rawValue: code) {
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return .offline
        case .cannotConnectToHost, .networkConnectionLost:
            return .cannotConnect
        case .cannotFindHost, .dnsLookupFailed:
            return .hostNotFound
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return .secureConnection
        case .timedOut:
            return .timedOut
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            return .tooManyRedirects
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData,
             .cannotDecodeContentData, .zeroByteResource, .dataLengthExceedsMaximum:
            return .unreadableResponse
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return .unauthorized
        case .badURL, .unsupportedURL:
            return .invalidURL
        case .cancelled:
            return .cancelled
        default:
            return .other(code: code)
        }
    }

    private static func classifyPOSIX(code: Int) -> NetworkFailure? {
        switch POSIXErrorCode(rawValue: Int32(truncatingIfNeeded: code)) {
        case .ECONNREFUSED, .ECONNRESET, .ECONNABORTED, .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH, .ENETDOWN:
            return .cannotConnect
        case .ETIMEDOUT:
            return .timedOut
        default:
            return nil
        }
    }

    var message: String {
        switch self {
        case .offline:
            return "This computer appears to be offline. Check the network connection and try again."
        case .cannotConnect:
            return "Could not connect to the Nightscout site. Check the address and that the site is running."
        case .hostNotFound:
            return "The Nightscout site's host name could not be found. Check the address."
        case .secureConnection:
            return "A secure connection to the Nightscout site could not be established. Check that the site's HTTPS certificate is valid."
        case .timedOut:
            return "The Nightscout site did not respond in time. Try again later."
        case .tooManyRedirects:
            return "Nightscout redirected too many times, so the request was stopped. Enter the site's final address."
        case .unreadableResponse:
            return "Nightscout sent a response that could not be read."
        case .unauthorized:
            return ErrorMessage.describe(NightscoutError.unauthorized)
        case .invalidURL:
            return ErrorMessage.describe(NightscoutError.invalidURL)
        case .cancelled:
            return "The request to Nightscout was cancelled."
        case let .other(code):
            return "A network error occurred while contacting Nightscout (URL error \(code))."
        }
    }
}
