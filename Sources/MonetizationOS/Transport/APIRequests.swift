import Foundation

/// Builds every request the SDK sends, so no call site can forget a header.
struct APIRequests: Sendable {
    let apiBaseURL: String
    let publicKey: String
    let userAgent: String
    let timeout: TimeInterval

    init(apiBaseURL: String, publicKey: String, userAgent: String, timeout: TimeInterval) {
        var base = apiBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        self.apiBaseURL = base
        self.publicKey = publicKey
        self.userAgent = userAgent
        self.timeout = timeout
    }

    var commonHeaders: [String: String] {
        [
            "Content-Type": "application/json",
            "User-Agent": userAgent,
            "X-MOS-Mobile-Version": "ios/\(MOSVersion)",
        ]
    }

    /// A MonetizationOS API call, authenticated with `Authorization: Bearer <pk>`.
    func api(_ path: String, body: JSONValue) -> HTTPRequest? {
        guard let url = Self.absoluteURL(apiBaseURL + path) else { return nil }
        var headers = commonHeaders
        headers["Authorization"] = "Bearer \(publicKey)"
        return HTTPRequest(url: url, headers: headers, body: body.encoded(), timeout: timeout)
    }

    /// Foundation accepts relative strings such as `"api"`; only an absolute URL can be sent.
    static func absoluteURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// `pk_<a>_<b>_<secret>` gives `<a>_<b>`; the secret may itself contain underscores.
    static func environment(fromPublicKey key: String) -> String? {
        let parts = key.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "pk", !parts[1].isEmpty, !parts[2].isEmpty,
              !parts[3...].joined(separator: "_").isEmpty
        else { return nil }
        return "\(parts[1])_\(parts[2])"
    }
}

/// Classifies responses identically for every endpoint.
package enum APIResponse {
    static func failure(from error: any Error) -> Failure {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return Failure(reason: .timeout, message: "The request timed out")
        }
        return Failure(reason: .requestFailed, message: "The request failed: \(error.localizedDescription)")
    }

    /// The JSON body of a 2xx response that is not an error envelope; a failure otherwise. A body
    /// with `status: "error"` is an API error even on a 200. `allowEmpty` reads an empty 2xx body
    /// as JSON `null`.
    static func interpret(_ response: HTTPResponse, allowEmpty: Bool = false) -> Result<JSONValue, Failure> {
        let status = response.status
        let isSuccess = (200..<300).contains(status)
        if allowEmpty, isSuccess, response.body.isEmpty { return .success(.null) }
        guard let json = JSONValue.parse(response.body) else {
            return .failure(isSuccess
                ? Failure(reason: .invalidJSON, status: status, message: "The response body is not JSON")
                : statusFailure(status: status, envelope: nil))
        }
        if json["status"]?.stringValue == "error" { return .failure(statusFailure(status: status, envelope: json)) }
        guard isSuccess else { return .failure(statusFailure(status: status, envelope: nil)) }
        return .success(json)
    }

    static func invalidResponse(status: Int) -> Failure {
        Failure(reason: .invalidResponse, status: status, message: "The response is not a recognisable success shape")
    }

    /// The failure for a non-2xx response, reading its error envelope when there is one.
    package static func failure(status: Int, json: JSONValue?) -> Failure {
        statusFailure(status: status, envelope: json?["status"]?.stringValue == "error" ? json : nil)
    }

    private static func statusFailure(status: Int, envelope: JSONValue?) -> Failure {
        // An envelope without a `statusCode` takes the HTTP status; no envelope leaves it nil.
        let statusCode = envelope.map { $0["statusCode"]?.intValue ?? status }
        let message = envelope?["message"]?.stringValue ?? "HTTP \(status)"
        let code = statusCode ?? status
        let reason: Failure.Reason =
            if code == 429 || status == 429 { .rateLimited }
            else if code == 401 || status == 401 { .unauthorized }
            else if envelope != nil { .apiError }
            else { .httpError }
        return Failure(reason: reason, status: status, statusCode: statusCode, message: message)
    }
}
