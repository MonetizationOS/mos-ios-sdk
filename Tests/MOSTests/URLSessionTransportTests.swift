import Foundation
import os
import Testing
@testable import MonetizationOS

/// Answers every request with `response` and records what it received, standing in for the
/// server behind a real `URLSession`.
final class StubURLProtocol: URLProtocol {
    struct Received: Sendable {
        let method: String?
        let url: URL?
        let headers: [String: String]
        let body: Data
    }

    static let state = OSAllocatedUnfairLock<(received: [Received], response: HTTPResponse)>(
        initialState: ([], HTTPResponse(status: 200, body: Data()))
    )

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let received = Received(
            method: request.httpMethod,
            url: request.url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request)
        )
        let response = Self.state.withLock { state in
            state.received.append(received)
            return state.response
        }
        let headers = ["Content-Type": "application/json"].merging(response.headers) { _, new in new }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves the body into a stream before a protocol sees it.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite("URLSession transport", .serialized)
struct URLSessionTransportTests {
    private func makeMOS(publicKey: String) throws -> MOS {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return try MOS(config: MOSConfig(
            publicKey: publicKey,
            surface: "app-paywall",
            app: MOSConfig.App(name: "Herald", version: "2.1"),
            apiBaseURL: "https://api.example.test",
            identity: MOSConfig.Identity(store: InMemoryIdentityStore(anonymousIdentifier: "mos-anon-v1-abc")),
            transport: URLSessionTransport(session: URLSession(configuration: configuration))
        ).with(cache: InMemoryDecisionCacheStore(), queue: InMemoryMeteringQueueStore()))
    }

    private func respond(_ response: HTTPResponse) -> [StubURLProtocol.Received] {
        StubURLProtocol.state.withLock { state in
            defer { state = ([], response) }
            return state.received
        }
    }

    @Test("a real URLSession request carries exactly the contract headers")
    func decisionHeadersOverURLSession() async throws {
        _ = respond(.fixture("decision-success-minimal.json"))
        let mos = try makeMOS(publicKey: "pk_test_env1_secret")
        let result = await mos.decide(resource: Resource(id: "article/1"))
        await mos.waitForBackgroundFlush()
        #expect(result.source == .network)
        #expect(result.decision?.eventID == "55555555-5555-4555-8555-555555555555")

        let received = try #require(respond(HTTPResponse(status: 200, body: Data())).first)
        #expect(received.method == "POST")
        #expect(received.url?.absoluteString == "https://api.example.test/api/v1/surface-decisions")
        let userAgent = await mos.userAgent
        // Exactly the contract headers, plus the Content-Length URLSession adds on the wire.
        #expect(received.headers == [
            "Authorization": "Bearer pk_test_env1_secret",
            "Content-Type": "application/json",
            "User-Agent": userAgent,
            "X-MOS-Mobile-Version": "ios/\(MOSVersion)",
            "Content-Length": "\(received.body.count)",
        ], "\(received.headers)")
        #expect(userAgent.hasPrefix("Herald/2.1 ("))
        #expect(userAgent.hasSuffix(") MOS-iOS/\(MOSVersion)"))
        #expect(JSONValue.parse(received.body)?["identity"] == ["anonymousIdentifier": "mos-anon-v1-abc"])
    }

    @Test("an org endpoint over URLSession sends X-MOS-Key and no Authorization")
    func endpointHeadersOverURLSession() async throws {
        _ = respond(.json(["ok": true]))
        let mos = try makeMOS(publicKey: "pk_live_abc_secret")
        let result = await mos.callEndpoint(path: "registration", body: ["a": 1], namespace: "install_1")
        guard case .response(let response) = result else {
            Issue.record("expected a response, got \(result)")
            return
        }
        #expect(response.status == 200)
        #expect(response.json == ["ok": true])

        let received = try #require(respond(HTTPResponse(status: 200, body: Data())).first)
        #expect(received.url?.absoluteString == "https://api.example.test/api/v1/envs/live_abc/namespaces/install_1/endpoints/registration")
        #expect(received.headers["X-MOS-Key"] == "Bearer pk_live_abc_secret")
        #expect(received.headers["Authorization"] == nil)
        #expect(JSONValue.parse(received.body) == ["a": 1])
    }

    @Test("real transport: a PUT with a query string, a response header and a 404 body")
    func endpointPutOverURLSession() async throws {
        _ = respond(HTTPResponse(status: 404, headers: ["X-Request-ID": "req-1"], body: Fixtures.data("error-404.json")))
        let mos = try makeMOS(publicKey: "pk_live_abc_secret")
        let result = await mos.app(namespace: "orders_1").call(
            path: "orders/42", method: .put, body: ["state": "refunded"], query: ["b": "2", "a": "x y"]
        )
        guard case .response(let response) = result else {
            Issue.record("expected a response, got \(result)")
            return
        }
        #expect(response.status == 404)
        #expect(!response.isSuccess)
        #expect(response.headers["x-request-id"] == "req-1")
        #expect(response.json?["statusCode"] == 404)
        #expect(response.body == Fixtures.data("error-404.json"))

        let received = try #require(respond(HTTPResponse(status: 200, body: Data())).first)
        #expect(received.method == "PUT")
        #expect(received.url?.absoluteString == "https://api.example.test/api/v1/envs/live_abc/namespaces/orders_1/endpoints/orders/42?a=x%20y&b=2")
        #expect(received.headers["Content-Type"] == "application/json")
        #expect(JSONValue.parse(received.body) == ["state": "refunded"])
    }
}

/// A loopback TCP listener that never accepts: the kernel completes the handshake from its
/// backlog, so the client connects and then hears nothing.
final class SilentServer: Sendable {
    let descriptor: Int32
    let port: UInt16

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        self.descriptor = descriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && listen(descriptor, 8) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard descriptor >= 0, bound else {
            close(descriptor)
            throw URLError(.cannotConnectToHost)
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(descriptor) }
}

/// A loopback HTTP server that answers every request with a 307 to another origin (`localhost`
/// instead of `127.0.0.1`, the same listener), and records each request line it reads.
final class RedirectServer: Sendable {
    let listener: SilentServer
    private let requestLines = OSAllocatedUnfairLock(initialState: [String]())

    var port: UInt16 { listener.port }
    var received: [String] { requestLines.withLock { $0 } }

    init() throws {
        listener = try SilentServer()
        let descriptor = listener.descriptor
        let response = Data((
            "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://localhost:\(listener.port)/elsewhere\r\n"
                + "Content-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        ).utf8)
        let requestLines = requestLines
        Thread.detachNewThread {
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                let request = Self.readRequest(client)
                requestLines.withLock { $0.append(request.split(separator: "\r\n").first.map(String.init) ?? "") }
                _ = response.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }
    }

    /// Reads the head and a `Content-Length` body, so the reply never races the client's upload.
    private static func readRequest(_ client: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            if let headEnd = data.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: data[..<headEnd.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if data.count - headEnd.upperBound >= length { return head }
            }
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { return String(decoding: data, as: UTF8.self) }
            data.append(buffer, count: count)
        }
    }
}

@Suite("URLSession transport timeout")
struct URLSessionTimeoutTests {
    private func makeMOS(_ server: SilentServer, requestTimeout: Duration) throws -> MOS {
        try MOS(config: MOSConfig(
            publicKey: TestKeys.publicKey,
            surface: "app-paywall",
            app: MOSConfig.App(name: "Herald", version: "2.1"),
            apiBaseURL: "http://127.0.0.1:\(server.port)",
            identity: MOSConfig.Identity(store: InMemoryIdentityStore(anonymousIdentifier: "mos-anon-v1-abc")),
            requestTimeout: requestTimeout
        ).with(cache: InMemoryDecisionCacheStore(), queue: InMemoryMeteringQueueStore()))
    }

    @Test("end-to-end timeout honoured by the real transport: a server that accepts and never answers yields timeout within about requestTimeout")
    func silentServerTimesOut() async throws {
        let server = try SilentServer()
        let mos = try makeMOS(server, requestTimeout: .seconds(1))
        let started = ContinuousClock.now
        let result = await mos.decide(resource: Resource(id: "article/1"))
        let elapsed = ContinuousClock.now - started
        #expect(result.failure?.reason == .timeout, "\(String(describing: result.failure))")
        #expect(elapsed >= .milliseconds(900))
        #expect(elapsed < .seconds(3), "\(elapsed)")
        withExtendedLifetime(server) {}
    }

    @Test("real transport: a redirect comes back as the response; the key, a JWT and the body never follow it")
    func redirectNotFollowed() async throws {
        let server = try RedirectServer()
        let mos = try makeMOS(server.listener, requestTimeout: .seconds(5))
        await mos.identify(userJWT: Tokens.jwt(sub: "user_42"))

        let result = await mos.callEndpoint(path: "orders", body: ["a": 1])
        guard case .response(let response) = result else {
            Issue.record("expected a response, got \(result)")
            return
        }
        #expect(response.status == 307)
        #expect(response.headers["location"] == "http://localhost:\(server.port)/elsewhere")
        #expect(server.received == ["POST /api/v1/envs/test_env1/endpoints/orders HTTP/1.1"])

        // A decision answered with a redirect fails here instead of being posted, JWT and all, to the new origin.
        let decision = await mos.decide(resource: Resource(id: "article/1"))
        #expect(decision.failure != nil)
        #expect(server.received.count == 2)
        #expect(server.received.last == "POST /api/v1/surface-decisions HTTP/1.1")
    }

    @Test("an explicit callEndpoint timeout longer than requestTimeout is honoured by the real transport")
    func explicitTimeoutOutlivesRequestTimeout() async throws {
        let server = try SilentServer()
        let mos = try makeMOS(server, requestTimeout: .milliseconds(300))
        let started = ContinuousClock.now
        let result = await mos.callEndpoint(path: "orders/sync", timeout: .milliseconds(1200))
        let elapsed = ContinuousClock.now - started
        #expect(result == .failed(Failure(reason: .timeout, message: "The request timed out")))
        #expect(elapsed >= .milliseconds(1100), "\(elapsed)")
        withExtendedLifetime(server) {}
    }
}
