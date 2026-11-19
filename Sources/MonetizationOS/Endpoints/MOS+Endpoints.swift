import Foundation

extension MOS {
    static let sdkOwnedEndpointHeaders: Set<String> = [
        "x-mos-key", "user-agent", "x-mos-mobile-version", "content-type", "content-length",
        "x-mos-user-jwt", "x-mos-anonymous-identifier",
    ]

    /// A handle bound to one app namespace.
    public nonisolated func app(namespace: String) -> AppClient {
        AppClient(namespace: namespace, mos: self)
    }

    /// Plain HTTP to `{apiBaseURL}/api/v1/envs/{env}[/namespaces/{namespace}]/endpoints/{path}`
    /// with `X-MOS-Key`. Any HTTP response is `.response`; never retried, coalesced or cached.
    /// No identity is sent. `timeout` defaults to the full `requestTimeout`, even in fail-fast.
    public func callEndpoint(
        path: String,
        method: EndpointMethod = .post,
        body: JSONValue? = nil,
        query: [String: String]? = nil,
        headers: [String: String]? = nil,
        namespace: String? = nil,
        timeout: Duration? = nil
    ) async -> EndpointResult {
        let trimmed = path.hasPrefix("/") ? path.dropFirst() : Substring(path)
        return await callEndpoint(
            segments: trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init), loggedPath: path,
            method: method, body: body, query: query, headers: headers, namespace: namespace, timeout: timeout
        )
    }

    /// `callEndpoint(path:)` with the path as segments, each percent-encoded whole, so a value
    /// holding `/` stays one segment (`"a/b"` is sent as `a%2Fb`).
    public func callEndpoint(
        pathSegments: [String],
        method: EndpointMethod = .post,
        body: JSONValue? = nil,
        query: [String: String]? = nil,
        headers: [String: String]? = nil,
        namespace: String? = nil,
        timeout: Duration? = nil
    ) async -> EndpointResult {
        await callEndpoint(
            segments: pathSegments, loggedPath: pathSegments.map(EndpointURL.encode).joined(separator: "/"),
            method: method, body: body, query: query, headers: headers, namespace: namespace, timeout: timeout
        )
    }

    private func callEndpoint(
        segments: [String], loggedPath: String, method: EndpointMethod, body: JSONValue?, query: [String: String]?,
        headers: [String: String]?, namespace: String?, timeout: Duration?
    ) async -> EndpointResult {
        var context: [String: JSONValue] = [
            "namespace": namespace.map(JSONValue.string) ?? .null, "path": .string(loggedPath), "method": .string(method.rawValue),
        ]
        let result: EndpointResult
        switch endpointRequest(segments: segments, method: method, body: body, query: query, headers: headers, namespace: namespace) {
        case .failure(let failure):
            result = .failed(failure)
        case .success(let request):
            // Cut short, a call the server ran would be reported as a timeout.
            switch await send(request, timeout: timeout ?? config.requestTimeout) {
            case .failure(let failure): result = .failed(failure)
            case .success(let http): result = .response(EndpointResponse(status: http.status, headers: http.headers, body: http.body))
            }
        }

        switch result {
        case .response(let response):
            context["status"] = .int(response.status)
            if response.isSuccess {
                log(.info, "endpoint:success", "The endpoint answered \(response.status).", context)
            } else {
                log(.warn, "endpoint:error", "The endpoint answered \(response.status).", context)
            }
        case .failed(let failure):
            context["reason"] = .string(failure.reason.rawValue)
            log(.warn, "endpoint:error", "The endpoint call failed (\(failure.reason.rawValue)).", context)
        }
        return result
    }

    private func endpointRequest(
        segments: [String], method: EndpointMethod, body: JSONValue?, query: [String: String]?,
        headers hostHeaders: [String: String]?, namespace: String?
    ) -> Result<HTTPRequest, Failure> {
        guard let environment else {
            return .failure(Failure(reason: .notConfigured, message: "The public key does not name an environment (pk_<env>_<id>_<secret>)."))
        }
        guard let url = EndpointURL.make(base: requests.apiBaseURL, env: environment, namespace: namespace, segments: segments, query: query) else {
            return .failure(Failure(reason: .requestFailed, message: "The endpoint URL is not valid (an empty, '.' or '..' segment, or a bad base URL)."))
        }
        // The JDK turns a GET with a body into a POST, so both platforms refuse it.
        if body != nil, !method.allowsBody {
            return .failure(Failure(reason: .requestFailed, message: "\(method.rawValue) requests cannot carry a body."))
        }

        var headers = requests.commonHeaders
        headers["Content-Type"] = nil
        headers["X-MOS-Key"] = "Bearer \(requests.publicKey)"
        headers["Accept"] = "application/json"
        if body != nil { headers["Content-Type"] = "application/json" }
        for name in (hostHeaders ?? [:]).keys.sorted() {
            if Self.sdkOwnedEndpointHeaders.contains(name.lowercased()) {
                log(.warn, "endpoint:header-ignored", "The SDK owns this header; the host value was dropped.", ["name": .string(name)])
                continue
            }
            for existing in headers.keys where existing.lowercased() == name.lowercased() { headers[existing] = nil }
            headers[name] = hostHeaders?[name]
        }
        return .success(HTTPRequest(method: method.rawValue, url: url, headers: headers, body: body?.encoded() ?? Data(), timeout: 0))
    }
}
