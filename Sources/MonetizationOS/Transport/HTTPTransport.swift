import Foundation
import os

public struct HTTPRequest: Sendable, Equatable {
    /// `GET`, `POST`, `PUT`, `DELETE` or `PATCH`.
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data
    /// Seconds, end to end; a transport reports running past it as `URLError(.timedOut)`.
    public let timeout: TimeInterval

    public init(method: String = "POST", url: URL, headers: [String: String], body: Data, timeout: TimeInterval) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    func withTimeout(_ timeout: TimeInterval) -> HTTPRequest {
        HTTPRequest(method: method, url: url, headers: headers, body: body, timeout: timeout)
    }
}

/// Printing, `dump()` and the debugger show the body's size and redact credential and identity header
/// values: the body carries `userJwt`, and a transport that logs its requests must not leak it.
extension HTTPRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Lowercased.
    static let redactedHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "x-mos-key", "x-mos-user-jwt", "x-mos-anonymous-identifier",
    ]

    private var redactedHeaders: [String: String] {
        headers.reduce(into: [:]) { redacted, header in
            redacted[header.key] = Self.redactedHeaderNames.contains(header.key.lowercased()) ? "<redacted>" : header.value
        }
    }

    private var redactedBody: String { "<\(body.count) bytes redacted>" }

    public var description: String {
        let headers = redactedHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        return "HTTPRequest(\(method) \(url.absoluteString), headers: [\(headers)], body: \(redactedBody), timeout: \(timeout))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["method": method, "url": url, "headers": redactedHeaders, "body": redactedBody, "timeout": timeout],
            displayStyle: .struct
        )
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    /// As the transport received them; the SDK lowercases names where it exposes them.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Sends one request with `request.method`. Throw `URLError(.timedOut)` for a timeout and any
/// other error for a failed request; the SDK never retries either.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Never follows redirects: a 3xx is returned as the response.
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    /// An ephemeral session (no cookies, no URL cache). Its resource timeout stays at the
    /// default: a request cannot raise it, so it would cut an explicit longer `timeout` short.
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    /// Bounded end to end by `request.timeout`: URLSession's own timeouts reset on every packet.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body.isEmpty ? nil : request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let session = session
        let finalRequest = urlRequest
        return try await Deadline.run(seconds: request.timeout) {
            let (data, response) = try await session.data(for: finalRequest, delegate: RedirectRefusal.shared)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var headers: [String: String] = [:]
            for case let (name as String, value) in http.allHeaderFields {
                headers[name] = "\(value)"
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        }
    }
}

/// Hands a 3xx back as the response, so the key, a JWT or a POST body never reach another host.
/// Set per task, so it also applies to a session the host passes in.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectRefusal()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

enum Deadline {
    /// Returns the operation's outcome, or throws `URLError(.timedOut)` once `seconds` pass,
    /// without waiting for an operation that ignores cancellation.
    static func run<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>(initialState: nil)
        let finish: @Sendable (Result<T, any Error>) -> Void = { result in
            pending.withLock { continuation in
                defer { continuation = nil }
                return continuation
            }?.resume(with: result)
        }
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        defer {
            work?.cancel()
            timer?.cancel()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.withLock { $0 = continuation }
                work = Task {
                    do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
                }
                timer = Task {
                    try? await Task.sleep(for: .milliseconds(Duration.saturatingMilliseconds(seconds: seconds)))
                    finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }
}

extension Duration {
    /// Clamped to `Int64`, so a huge configured duration means "forever" instead of trapping.
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1000)
        if overflow { return seconds < 0 ? .min : .max }
        let (total, sumOverflow) = whole.addingReportingOverflow(attoseconds / 1_000_000_000_000_000)
        return sumOverflow ? (whole < 0 ? .min : .max) : total
    }

    var seconds: TimeInterval { Double(milliseconds) / 1000 }

    static func saturatingMilliseconds(seconds: TimeInterval) -> Int64 {
        let milliseconds = (seconds * 1000).rounded(.down)
        guard milliseconds.isFinite else { return milliseconds > 0 ? .max : 0 }
        if milliseconds >= Double(Int64.max) { return .max }
        return max(0, Int64(milliseconds))
    }
}
