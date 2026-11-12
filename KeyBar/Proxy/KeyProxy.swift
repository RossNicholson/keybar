import Foundation
import Network

/// A small HTTP proxy on this Mac (127.0.0.1 only) for AI APIs whose SDKs
/// take a base URL from the environment. A command using a proxied key gets
/// a placeholder instead of the key, and e.g. ANTHROPIC_BASE_URL pointing
/// here with a one-off token in the path. KeyBar adds the real key to each
/// request and passes it on to the service over HTTPS, so the command never
/// holds the key at all. A token works only while its command runs.
final class KeyProxy: @unchecked Sendable {
    /// Where a proxied key's requests go
    struct Route: Sendable, Equatable {
        /// The variable the SDK reads its base URL from
        let variable: String
        /// The service, e.g. https://api.anthropic.com
        let origin: String
        /// Added to the local base URL, for SDKs whose default base has a path
        let basePath: String
        /// The header the key goes in, and its value with KEY for the key
        let header: String
        let format: String
        let service: String
    }

    private static let routes: [String: Route] = [
        "Anthropic": Route(variable: "ANTHROPIC_BASE_URL", origin: "https://api.anthropic.com", basePath: "",
                           header: "x-api-key", format: "KEY", service: "Anthropic"),
        "OpenAI": Route(variable: "OPENAI_BASE_URL", origin: "https://api.openai.com", basePath: "/v1",
                        header: "Authorization", format: "Bearer KEY", service: "OpenAI"),
        "Groq": Route(variable: "GROQ_BASE_URL", origin: "https://api.groq.com", basePath: "",
                      header: "Authorization", format: "Bearer KEY", service: "Groq"),
    ]

    /// How a key could be proxied, or nil if it can't: API keys for the
    /// services above (not OAuth tokens, which work differently)
    static func route(for record: SecretRecord) -> Route? {
        guard !record.isFile, record.name.hasSuffix("_KEY"), !record.name.contains("OAUTH"),
              let service = record.service else { return nil }
        return routes[service.name]
    }

    /// Headers never passed on: hop-by-hop ones, ones URLSession sets itself,
    /// and any key the command sent (the placeholder)
    static let droppedRequestHeaders: Set<String> = [
        "host", "connection", "keep-alive", "proxy-connection", "proxy-authorization", "te", "trailer",
        "transfer-encoding", "upgrade", "content-length", "expect", "accept-encoding",
        "x-api-key", "authorization", "api-key",
    ]
    static let droppedResponseHeaders: Set<String> = [
        "connection", "keep-alive", "transfer-encoding", "content-length", "content-encoding", "trailer", "upgrade",
    ]

    /// The longest a token lasts, even if its command's end is never reported
    static let maxGrant: TimeInterval = 12 * 3600
    /// The biggest request body passed on
    static let maxBody = 64 * 1024 * 1024

    private struct Grant {
        var name: String
        var value: String
        var route: Route
        var runID: String
        var expires: Date
        var requests = 0
    }

    private let lock = NSLock()
    private var grants: [String: Grant] = [:]
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.rossnicholson.KeyBar.proxy")
    private(set) var port: UInt16?
    private(set) var lastError: String?

    /// Starts listening on a free port on 127.0.0.1, and waits until it is
    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    self?.port = listener?.port?.rawValue
                    ready.signal()
                case .failed(let error):
                    self?.lastError = error.localizedDescription
                    self?.port = nil
                    ready.signal()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                ProxyConnection(connection: connection, proxy: self).start(on: queue)
            }
            listener.start(queue: queue)
            self.listener = listener
            _ = ready.wait(timeout: .now() + 5)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    /// A base URL for one command to reach `route`'s service with `value`,
    /// or nil if the proxy isn't running
    func grant(name: String, value: String, route: Route, runID: String) -> String? {
        if listener == nil { start() }
        guard let port else { return nil }
        let token = Self.newToken()
        lock.withLock {
            grants = grants.filter { $0.value.expires > Date() }
            grants[token] = Grant(name: name, value: value, route: route, runID: runID, expires: Date().addingTimeInterval(Self.maxGrant))
        }
        return "http://127.0.0.1:\(port)/\(token)\(route.basePath)"
    }

    /// Ends the tokens of a command that finished. Returns how many requests
    /// went through them.
    @discardableResult
    func revoke(runID: String) -> Int {
        lock.withLock {
            let ended = grants.filter { $0.value.runID == runID }
            for token in ended.keys { grants[token] = nil }
            return ended.values.reduce(0) { $0 + $1.requests }
        }
    }

    var activeGrants: Int { lock.withLock { grants.values.filter { $0.expires > Date() }.count } }

    /// For a request path /TOKEN/rest: the upstream request's URL and the key
    /// header to add, or nil for a token that isn't (or is no longer) valid
    fileprivate func upstream(for path: String) -> (url: URL, header: String, value: String)? {
        let trimmed = path.drop { $0 == "/" }
        let token = String(trimmed.prefix { $0 != "/" && $0 != "?" })
        let rest = String(trimmed.dropFirst(token.count))
        return lock.withLock {
            guard var grant = grants[token], grant.expires > Date() else { return nil }
            grant.requests += 1
            grants[token] = grant
            // The origin is fixed: the path can't change where it goes
            guard let url = URL(string: grant.route.origin + (rest.hasPrefix("/") || rest.hasPrefix("?") || rest.isEmpty ? rest : "/" + rest)),
                  url.host == URL(string: grant.route.origin)?.host else { return nil }
            return (url, grant.route.header, grant.route.format.replacingOccurrences(of: "KEY", with: grant.value))
        }
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// No cookies or cache, and room for a long streamed reply
    fileprivate static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        return configuration
    }
}

/// One client connection: reads one HTTP/1.1 request, passes it on, streams
/// the reply back (chunked), then closes
private final class ProxyConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let proxy: KeyProxy
    private var buffer = Data()
    private var head: HTTPHead?
    private var body = Data()
    private var chunked: ChunkedDecoder?
    private var session: URLSession?
    private var queue: DispatchQueue?
    private var sentHead = false
    private var bodyless = false

    init(connection: NWConnection, proxy: KeyProxy) {
        self.connection = connection
        self.proxy = proxy
    }

    func start(on queue: DispatchQueue) {
        self.queue = queue
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if error != nil { return finish() }
            if process() { return }
            if complete { return finish() }
            receive()
        }
    }

    /// Returns true once the request is complete (or answered with an error)
    private func process() -> Bool {
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 64 * 1024 { fail(431, "The request's headers are too big.") ; return true }
                return false
            }
            guard let parsed = HTTPHead(Data(buffer[..<end.lowerBound])) else { fail(400, "KeyBar couldn't read the request."); return true }
            head = parsed
            buffer.removeSubrange(..<end.upperBound)
            if parsed.value("transfer-encoding")?.lowercased().contains("chunked") == true { chunked = ChunkedDecoder() }
            if parsed.value("expect")?.lowercased() == "100-continue" {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
        }
        guard let head else { return false }
        if var decoder = chunked {
            let done = decoder.feed(&buffer, into: &body)
            chunked = decoder
            if decoder.failed { fail(400, "KeyBar couldn't read the request's body."); return true }
            if body.count > KeyProxy.maxBody { fail(413, "The request is too big for KeyBar's proxy."); return true }
            guard done else { return false }
        } else {
            let length = Int(head.value("content-length") ?? "0") ?? 0
            if length > KeyProxy.maxBody { fail(413, "The request is too big for KeyBar's proxy."); return true }
            guard buffer.count >= length else { return false }
            body = Data(buffer.prefix(length))
        }
        forward(head)
        return true
    }

    private func forward(_ head: HTTPHead) {
        guard let upstream = proxy.upstream(for: head.target) else {
            fail(403, "This KeyBar proxy address has expired. It only works while the command KeyBar started for it is running.")
            return
        }
        var request = URLRequest(url: upstream.url)
        request.httpMethod = head.method
        for (name, value) in head.headers where !KeyProxy.droppedRequestHeaders.contains(name.lowercased()) {
            request.addValue(value, forHTTPHeaderField: name)
        }
        request.setValue(upstream.value, forHTTPHeaderField: upstream.header)
        if !body.isEmpty || !["GET", "HEAD"].contains(head.method) { request.httpBody = body }
        bodyless = head.method == "HEAD"
        let session = URLSession(configuration: KeyProxy.configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Pass redirects back rather than follow them with the key
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        bodyless = bodyless || http.statusCode == 204 || http.statusCode == 304 || (100..<200).contains(http.statusCode)
        var text = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized)\r\n"
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, !KeyProxy.droppedResponseHeaders.contains(name.lowercased()) else { continue }
            text += "\(name): \(value)\r\n"
        }
        text += bodyless ? "Connection: close\r\n\r\n" : "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        sentHead = true
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !bodyless, !data.isEmpty else { return }
        var chunk = Data(String(data.count, radix: 16).utf8)
        chunk.append(contentsOf: [0x0D, 0x0A])
        chunk.append(data)
        chunk.append(contentsOf: [0x0D, 0x0A])
        connection.send(content: chunk, completion: .contentProcessed { _ in })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error, !sentHead {
            fail(502, "KeyBar couldn't reach the service: \(error.localizedDescription)")
            return
        }
        let end = bodyless || error != nil ? Data() : Data("0\r\n\r\n".utf8)
        connection.send(content: end, completion: .contentProcessed { [self] _ in finish() })
    }

    // MARK: Replies

    private func fail(_ status: Int, _ message: String) {
        let body = (try? JSONSerialization.data(withJSONObject: [
            "type": "error", "error": ["type": "keybar_proxy_error", "message": message],
        ])) ?? Data()
        var reply = Data("HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        reply.append(body)
        connection.send(content: reply, completion: .contentProcessed { [self] _ in finish() })
    }

    private func finish() {
        connection.cancel()
        session?.invalidateAndCancel()
        session = nil
    }
}

/// An HTTP request's first line and headers
struct HTTPHead: Sendable {
    var method: String
    var target: String
    var headers: [(String, String)]

    init?(_ data: Data) {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else { return nil }
        method = String(parts[0])
        target = String(parts[1])
        headers = lines.dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
    }

    func value(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

/// Reads a chunked request body as it arrives
struct ChunkedDecoder: Sendable {
    private(set) var failed = false
    private var remaining: Int?

    /// Moves what it can from `buffer` into `body`. Returns true at the end.
    mutating func feed(_ buffer: inout Data, into body: inout Data) -> Bool {
        while true {
            if let size = remaining {
                guard buffer.count >= size + 2 else { return false }
                body.append(buffer.prefix(size))
                buffer.removeFirst(size + 2)
                remaining = nil
                continue
            }
            guard let line = buffer.range(of: Data("\r\n".utf8)) else { return false }
            let text = String(decoding: buffer[..<line.lowerBound], as: UTF8.self)
            guard let size = Int(text.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16) else {
                failed = true
                return true
            }
            buffer.removeSubrange(..<line.upperBound)
            if size == 0 {
                // Trailers, if any, end with a blank line
                if let end = buffer.range(of: Data("\r\n".utf8)) { buffer.removeSubrange(..<end.upperBound) }
                return true
            }
            remaining = size
        }
    }
}
