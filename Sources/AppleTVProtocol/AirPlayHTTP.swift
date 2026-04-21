import Foundation
import Network
import AppleTVLogging

/// Minimal HTTP/1.1 client over a single long-lived TCP connection. AirPlay's
/// `/pair-setup`, `/pair-verify` and later `/setup`, `/feedback` endpoints
/// speak plain HTTP/1.1 on port 7000. After pair-verify we switch the same
/// socket to encrypted framing — so this client is *just* the pre-encryption
/// transport, and callers take ownership of the underlying NWConnection once
/// we're done POSTing TLV8 payloads.
///
/// Design notes:
/// - Single in-flight request at a time. AirPlay's pair flow is strictly
///   request/response so this is fine.
/// - We keep the connection alive across requests ("Connection: keep-alive")
///   because pair-setup and pair-verify share state on the server side.
/// - Response parsing is deliberately minimal — we need status code, headers,
///   and raw body bytes. Nothing more.
public final class AirPlayHTTP: @unchecked Sendable {

    public enum HTTPError: Error, CustomStringConvertible {
        case connectionFailed(String)
        case timeout
        case malformedResponse(String)
        case badStatus(Int, String)

        public var description: String {
            switch self {
            case .connectionFailed(let m): return "connection failed: \(m)"
            case .timeout:                 return "timeout waiting for response"
            case .malformedResponse(let m):return "malformed response: \(m)"
            case .badStatus(let c, let m): return "HTTP \(c): \(m)"
            }
        }
    }

    public struct Response: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
    }

    private let connection: NWConnection
    private let host: String
    private let port: UInt16
    private let queue: DispatchQueue
    private let bufferLock = NSLock()
    private var readBuffer = Data()
    private let bufferCond = NSCondition()
    private var receiveError: Error?
    private var receiveClosed = false
    private var isReady = false
    private let readyGroup = DispatchGroup()
    /// Set by `detach()` — after this the receive loop stops re-registering
    /// and the new owner of the NWConnection takes over.
    private var detached = false

    private func trace(_ msg: String) {
        Log.pairing.report("AirPlayHTTP: \(msg)")
        if verbose { FileHandle.standardError.write(Data("    [http] \(msg)\n".utf8)) }
    }

    /// When true, mirror every log line to stderr so CLI users can see it live.
    public var verbose: Bool = false

    public init(host: String, port: UInt16) {
        self.host  = host
        self.port  = port
        self.queue = DispatchQueue(label: "AirPlayHTTP.\(host):\(port)")
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        self.connection = NWConnection(to: endpoint, using: .tcp)
    }

    /// Expose the underlying connection so Phase 2 can take it over once
    /// pair-verify has derived session keys.
    public var underlyingConnection: NWConnection { connection }

    /// Opens the TCP connection. Must be called once before `post`. Blocking.
    public func connect(timeoutSeconds: TimeInterval = 5) throws {
        readyGroup.enter()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if !self.isReady {
                    self.isReady = true
                    self.trace("connected \(self.host):\(self.port)")
                    self.receiveLoop()
                    self.readyGroup.leave()
                }
            case .failed(let err):
                self.trace("connection failed: \(err)")
                if !self.isReady { self.isReady = true; self.readyGroup.leave() }
            case .waiting(let err):
                self.trace("waiting: \(err)")
            case .cancelled:
                self.trace("cancelled")
            case .preparing:
                self.trace("preparing")
            case .setup:
                self.trace("setup")
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)

        let result = readyGroup.wait(timeout: .now() + timeoutSeconds)
        guard result == .success, isReady, connection.state == .ready else {
            connection.cancel()
            throw HTTPError.connectionFailed("not ready after \(timeoutSeconds)s — state=\(connection.state)")
        }
    }

    /// Closes the TCP connection. Only call if Phase 2 is not taking it over.
    public func close() { connection.cancel() }

    /// Hand the underlying NWConnection off to a post-pair-verify encrypted
    /// transport. After this, the receive loop no longer re-registers and
    /// any in-flight receive callback is a no-op, so the new owner can
    /// register its own receive immediately.
    ///
    /// Caller must ensure no un-consumed response data is left in the buffer.
    public func detach() -> NWConnection {
        bufferCond.lock()
        detached = true
        readBuffer = Data()
        bufferCond.unlock()
        return connection
    }

    // MARK: - Request

    /// POST raw bytes to `path` with the given headers. Returns status + body.
    /// Synchronous (blocks the calling thread) — AirPlay pair flow has no
    /// concurrent requests so this is appropriate.
    public func post(_ path: String,
                     body: Data,
                     headers: [String: String] = [:],
                     timeoutSeconds: TimeInterval = 10) throws -> Response {
        var req = "POST \(path) HTTP/1.1\r\n"
        req    += "Host: \(host)\r\n"
        req    += "Content-Length: \(body.count)\r\n"
        for (k, v) in headers { req += "\(k): \(v)\r\n" }
        req    += "\r\n"

        var frame = Data(req.utf8)
        frame.append(body)

        self.trace("→ POST \(path) (\(body.count)B body)")

        let sendGroup = DispatchGroup()
        sendGroup.enter()
        var sendError: Error?
        connection.send(content: frame, completion: .contentProcessed { err in
            sendError = err
            sendGroup.leave()
        })
        if sendGroup.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            throw HTTPError.timeout
        }
        if let sendError { throw HTTPError.connectionFailed("send: \(sendError)") }

        return try readResponse(timeoutSeconds: timeoutSeconds)
    }

    // MARK: - Private: read loop

    /// Receive bytes in the background into `readBuffer`. `readResponse` peels
    /// a complete HTTP/1.1 message off of it.
    ///
    /// The NWConnection receive callback already fires on `self.queue`, so we
    /// append directly — no extra dispatch hop. We signal `bufferCond` after
    /// each append so `readResponse` can wake instead of busy-waiting.
    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if self.detached { return }   // ownership handed off; drop.
            if let data, !data.isEmpty {
                self.bufferCond.lock()
                self.readBuffer.append(data)
                self.bufferCond.broadcast()
                self.bufferCond.unlock()
                self.trace("rx \(data.count)B (buffered=\(self.readBuffer.count))")
            }
            if let err {
                self.trace("receive error: \(err)")
                self.bufferCond.lock()
                self.receiveError = err
                self.receiveClosed = true
                self.bufferCond.broadcast()
                self.bufferCond.unlock()
                return
            }
            if isComplete {
                self.bufferCond.lock()
                self.receiveClosed = true
                self.bufferCond.broadcast()
                self.bufferCond.unlock()
                return
            }
            self.receiveLoop()
        }
    }

    private func readResponse(timeoutSeconds: TimeInterval) throws -> Response {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let headerSeparator = Data("\r\n\r\n".utf8)

        bufferCond.lock()
        defer { bufferCond.unlock() }

        while true {
            // Try to parse a complete response out of the current buffer.
            if let hdrEnd = readBuffer.range(of: headerSeparator) {
                let headerData = readBuffer[..<hdrEnd.lowerBound]
                let bodyStart  = hdrEnd.upperBound
                guard let headerStr = String(data: headerData, encoding: .utf8) else {
                    throw HTTPError.malformedResponse("non-UTF8 headers")
                }
                var lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
                guard !lines.isEmpty else { throw HTTPError.malformedResponse("no status line") }
                let statusLine = String(lines.removeFirst())
                let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count >= 2, let status = Int(parts[1]) else {
                    throw HTTPError.malformedResponse("bad status line: \(statusLine)")
                }
                var headers: [String: String] = [:]
                for line in lines {
                    if let colon = line.firstIndex(of: ":") {
                        let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                        let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        headers[k.lowercased()] = v
                    }
                }
                if verbose {
                    trace("← \(statusLine)")
                    for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
                        trace("    \(k): \(v)")
                    }
                }
                if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                    throw HTTPError.malformedResponse("chunked transfer-encoding not supported")
                }
                // IMPORTANT: Data.range(of:) and subscripts use ABSOLUTE
                // indices relative to the buffer's startIndex (which may be
                // non-zero after previous removeFirst). So use endIndex-based
                // math, not count, and never use removeFirst on readBuffer.
                let available = readBuffer.endIndex - bodyStart
                if verbose {
                    trace("    (bodyStart=\(bodyStart) available=\(available) buffered=\(readBuffer.count) startIdx=\(readBuffer.startIndex) endIdx=\(readBuffer.endIndex))")
                }
                if let clStr = headers["content-length"], let contentLength = Int(clStr) {
                    if available >= contentLength {
                        let bodyEnd = bodyStart + contentLength
                        let body    = Data(readBuffer[bodyStart..<bodyEnd])
                        // Normalize startIndex to 0 by rebuilding Data from the tail.
                        readBuffer = Data(readBuffer[bodyEnd...])
                        let result = Response(status: status, headers: headers, body: body)
                        trace("← \(status) (\(contentLength)B body)")
                        if verbose {
                            let hex = body.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
                            trace("    body[0..\(min(64, contentLength))]: \(hex)")
                        }
                        return result
                    }
                } else {
                    // No Content-Length. Treat as empty body (AirPlay's
                    // /pair-pin-start typically responds with just headers).
                    let result = Response(status: status, headers: headers, body: Data())
                    readBuffer = Data(readBuffer[bodyStart...])
                    trace("← \(status) (no content-length, treating as empty)")
                    return result
                }
            }

            if let err = receiveError {
                throw HTTPError.connectionFailed("receive: \(err)")
            }
            if receiveClosed && readBuffer.isEmpty {
                throw HTTPError.connectionFailed("connection closed before response")
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw HTTPError.timeout
            }
            // Wait for receiveLoop to broadcast more bytes, or timeout.
            _ = bufferCond.wait(until: Date().addingTimeInterval(remaining))
        }
    }
}
