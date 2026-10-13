import Testing
import Foundation
@testable import LoopTuneKit

private let token = "sec04-synthetic-token-5b1e"
private let failingURLString = "https://audit-user:audit-password@site.example.com/api/v1/entries/sgv.json?count=1500&token=\(token)&api_secret=\(token)"

/// Errors shaped like Foundation's network errors, carrying a credential in
/// every field Foundation fills: the failing URL, its string, the localized
/// description, and a nested underlying error. No request is sent.
private func networkError(
    domain: String = NSURLErrorDomain,
    code: Int,
    underlying: NSError? = nil
) -> NSError {
    var userInfo: [String: Any] = [
        NSURLErrorFailingURLErrorKey: URL(string: failingURLString)!,
        NSURLErrorFailingURLStringErrorKey: failingURLString,
        NSLocalizedDescriptionKey: "The request to \(failingURLString) failed.",
    ]
    userInfo[NSUnderlyingErrorKey] = underlying
    return NSError(domain: domain, code: code, userInfo: userInfo)
}

private func exposesCredential(_ message: String) -> Bool {
    message.contains(token) || message.contains("audit-") || message.contains("token=")
}

@Suite("User-facing error messages")
struct ErrorMessageTests {
    @Test("network failures are described by kind without their URL", arguments: [
        (URLError.Code.cannotConnectToHost, "Could not connect to the Nightscout site"),
        (.networkConnectionLost, "Could not connect to the Nightscout site"),
        (.notConnectedToInternet, "appears to be offline"),
        (.cannotFindHost, "host name could not be found"),
        (.dnsLookupFailed, "host name could not be found"),
        (.secureConnectionFailed, "secure connection"),
        (.serverCertificateUntrusted, "secure connection"),
        (.serverCertificateHasBadDate, "secure connection"),
        (.serverCertificateHasUnknownRoot, "secure connection"),
        (.timedOut, "did not respond in time"),
        (.httpTooManyRedirects, "redirected too many times"),
        (.cannotParseResponse, "could not be read"),
    ])
    func networkFailures(code: URLError.Code, expected: String) {
        let nsError = networkError(code: code.rawValue)
        let urlError = URLError(code, userInfo: nsError.userInfo)
        #expect("\(nsError)".contains(token))
        for error in [nsError as Error, urlError] {
            let message = ErrorMessage.describe(error)
            #expect(message.contains(expected))
            #expect(!exposesCredential(message))
        }
    }

    @Test("connection, DNS, TLS, and timeout failures stay distinguishable")
    func distinctKinds() {
        let codes: [URLError.Code] = [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .secureConnectionFailed, .timedOut]
        let messages = Set(codes.map { ErrorMessage.describe(URLError($0)) })
        #expect(messages.count == codes.count)
    }

    @Test("a network failure nested under another error is classified and redacted")
    func nestedUnderlyingErrors() {
        let timeout = networkError(code: URLError.timedOut.rawValue)
        let wrapped = networkError(domain: "LoopTuneTests.Wrapper", code: 1, underlying: timeout)
        #expect(ErrorMessage.describe(wrapped) == NetworkFailure.timedOut.message)

        // A generic URL error defers to the specific failure beneath it.
        let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
        let unknownOverRefused = networkError(code: NSURLErrorUnknown, underlying: networkError(domain: NetworkFailure.cfNetworkDomain, code: NSURLErrorUnknown, underlying: refused))
        #expect(ErrorMessage.describe(unknownOverRefused) == NetworkFailure.cannotConnect.message)

        let untrustedRoot = NSError(domain: NSOSStatusErrorDomain, code: -9813)
        let unknownOverTLS = networkError(code: NSURLErrorUnknown, underlying: untrustedRoot)
        #expect(ErrorMessage.describe(unknownOverTLS) == NetworkFailure.secureConnection.message)

        let unclassified = networkError(code: NSURLErrorUnknown, underlying: networkError(domain: "LoopTuneTests.Other", code: 2))
        #expect(ErrorMessage.describe(unclassified) == "A network error occurred while contacting Nightscout (URL error -1).")

        for error in [wrapped, unknownOverRefused, unknownOverTLS, unclassified] {
            #expect(!exposesCredential(ErrorMessage.describe(error)))
        }
    }

    @Test("a refused redirect has a message naming the fix")
    func disallowedRedirect() {
        #expect(ErrorMessage.describe(NightscoutError.disallowedRedirect)
            == "Nightscout redirected to a different scheme, host, or port, so the request was stopped. Enter the site's final address.")
    }

    @Test("malformed records name the request path and nothing else of its URL")
    func partialDecoding() {
        #expect(ErrorMessage.describe(NightscoutError.partialDecoding(path: "/api/v1/entries/sgv.json", skipped: 2))
            == "Nightscout returned 2 malformed records from /api/v1/entries/sgv.json. No recommendation was made.")
        let hostile = ErrorMessage.describe(NightscoutError.partialDecoding(path: failingURLString, skipped: 1))
        #expect(hostile == "Nightscout returned 1 malformed record from /api/v1/entries/sgv.json. No recommendation was made.")
    }

    @Test("text carried by an error is never shown")
    func carriedTextIsDropped() {
        struct LeakyError: LocalizedError, CustomStringConvertible {
            var errorDescription: String? { "failed: \(failingURLString)" }
            var description: String { failingURLString }
        }
        let leaky = ErrorMessage.describe(LeakyError())
        #expect(leaky.hasPrefix("An unexpected error occurred ("))
        #expect(leaky.contains("LeakyError"))

        let customDomain = NSError(domain: "custom.\(token)", code: 7, userInfo: [NSLocalizedDescriptionKey: failingURLString])
        #expect(ErrorMessage.describe(customDomain) == "An unexpected error occurred (error 7).")
        #expect(ErrorMessage.describe(CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: failingURLString]))
            == "An unexpected error occurred (NSCocoaErrorDomain 257).")

        let decoding = ErrorMessage.describe(NightscoutError.decoding("value \(token) at \(failingURLString)"))
        #expect(decoding == "Nightscout returned data that LoopTune could not read. No recommendation was made.")

        for message in [leaky, decoding] {
            #expect(!exposesCredential(message))
        }
    }
}
