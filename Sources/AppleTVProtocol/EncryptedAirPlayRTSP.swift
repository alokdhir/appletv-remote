import Foundation
import Network
import AppleTVLogging

/// RTSP-over-ChaCha20-Poly1305 transport for AirPlay 2 post-pair-verify.
///
/// Inputs: an NWConnection that's already pair-verified (detached from
/// `AirPlayHTTP`), plus a `HAPSession` keyed from the pair-verify shared
/// secret. Provides a single synchronous RTSP request/response primitive
/// plus `detach()` so the next phase (event / data channels) can reuse
/// the same socket — though for AirPlay 2 the event and data channels
/// open *new* TCP sockets to `eventPort`/`dataPort`, so typically this
/// socket stays pinned to RTSP control + keepalive.
///
/// Wire details (mirrors pyatv):
/// - Request:  `METHOD URI RTSP/1.0\r\n` + headers + `\r\n\r\n` + body
/// - Response: `RTSP/1.0 STATUS REASON\r\n` + headers + `\r\n\r\n` + body
/// - Body is almost always `application/x-apple-binary-plist`.
/// - All bytes pass through HAPSession framing — `send` auto-splits
///   plaintexts over the 1024B per-frame limit; `feed` reassembles.
public final class EncryptedAirPlayRTSP: @unchecked Sendable {

    public enum RTSPError: Error, CustomStringConvertible {
        case timeout
        case sendFailed(String)
        case malformedResponse(String)
        case framing(HAPSession.FramingError)
        case closed(String)

        public var description: String {
            switch self {
            case .timeout:                 return "timeout waiting for RTSP response"
            case .sendFailed(let m):       return "RTSP send failed: \(m)"
            case .malformedResponse(let m):return "malformed RTSP response: \(m)"
            case .framing(let e):          return "framing: \(e)"
            case .closed(let m):           return "connection closed: \(m)"
            }
        }
    }

    public struct Response: Sendable {
        public let status:  Int
        public let reason:  String
        public let headers: [String: String]
        public let body:    Data
    }

    private let connection: NWConnection
    private let session:    HAPSession
    private let queue:      DispatchQueue
    private let host:       String

    // Plaintext receive buffer — `feed` appends, `readResponse` drains.
    private let bufferCond   = NSCondition()
    private var plainBuffer  = Data()
    private var receiveError: Error?
    private var receiveClosed = false

    private var cseq = 0

    public init(connection: NWConnection, session: HAPSession, host: String) {
        self.connection = connection
        self.session    = session
        self.host       = host
        self.queue      = DispatchQueue(label: "EncryptedAirPlayRTSP.\(host)")
    }

    /// Start the receive loop. Must be called once before any `request(...)`.
    public func start() {
        receiveLoop()
    }

    public func close() { connection.cancel() }

    // MARK: - Request

    /// Send an RTSP request and block until the response arrives.
    public func request(method:   String,
                        uri:      String,
                        headers:  [String: String] = [:],
                        body:     Data = Data(),
                        timeoutSeconds: TimeInterval = 10) throws -> Response {
        cseq += 1
        var req = "\(method) \(uri) RTSP/1.0\r\n"
        req    += "CSeq: \(cseq)\r\n"
        req    += "User-Agent: AirPlay/320.20\r\n"
        req    += "Content-Length: \(body.count)\r\n"
        for (k, v) in headers { req += "\(k): \(v)\r\n" }
        req    += "\r\n"
        var frame = Data(req.utf8)
        frame.append(body)

        Log.pairing.report("RTSP: → \(method) \(uri) (body=\(body.count)B, cseq=\(cseq))")

        let encrypted: Data
        do { encrypted = try session.encrypt(frame) }
        catch { throw RTSPError.framing(error as! HAPSession.FramingError) }

        let sendGroup = DispatchGroup()
        sendGroup.enter()
        var sendError: Error?
        connection.send(content: encrypted, completion: .contentProcessed { err in
            sendError = err
            sendGroup.leave()
        })
        if sendGroup.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            throw RTSPError.timeout
        }
        if let e = sendError { throw RTSPError.sendFailed("\(e)") }

        return try readResponse(timeoutSeconds: timeoutSeconds)
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let plain = try self.session.feed(data)
                    if !plain.isEmpty {
                        self.bufferCond.lock()
                        self.plainBuffer.append(plain)
                        self.bufferCond.broadcast()
                        self.bufferCond.unlock()
                    }
                } catch {
                    Log.pairing.fail("RTSP: decrypt error: \(error)")
                    self.bufferCond.lock()
                    self.receiveError = error
                    self.receiveClosed = true
                    self.bufferCond.broadcast()
                    self.bufferCond.unlock()
                    return
                }
            }
            if let err {
                Log.pairing.fail("RTSP: receive error: \(err)")
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

    // MARK: - Response parsing

    private func readResponse(timeoutSeconds: TimeInterval) throws -> Response {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let sep = Data("\r\n\r\n".utf8)

        bufferCond.lock()
        defer { bufferCond.unlock() }

        while true {
            if let hdrEnd = plainBuffer.range(of: sep) {
                let headerData = plainBuffer[plainBuffer.startIndex..<hdrEnd.lowerBound]
                let bodyStart  = hdrEnd.upperBound
                guard let headerStr = String(data: headerData, encoding: .utf8) else {
                    throw RTSPError.malformedResponse("non-UTF8 headers")
                }
                var lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
                guard !lines.isEmpty else { throw RTSPError.malformedResponse("empty headers") }
                let statusLine = String(lines.removeFirst())
                // RTSP/1.0 200 OK
                let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count >= 3,
                      parts[0].hasPrefix("RTSP/"),
                      let status = Int(parts[1]) else {
                    throw RTSPError.malformedResponse("bad status line: \(statusLine)")
                }
                let reason = String(parts[2])
                var headers: [String: String] = [:]
                for line in lines {
                    if let colon = line.firstIndex(of: ":") {
                        let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                        let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        headers[k.lowercased()] = v
                    }
                }
                let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
                let available = plainBuffer.endIndex - bodyStart
                if available >= contentLength {
                    let bodyEnd = bodyStart + contentLength
                    let body = Data(plainBuffer[bodyStart..<bodyEnd])
                    plainBuffer = Data(plainBuffer[bodyEnd...])
                    Log.pairing.report("RTSP: ← \(status) \(reason) (body=\(contentLength)B)")
                    return Response(status: status, reason: reason, headers: headers, body: body)
                }
            }
            if let err = receiveError { throw RTSPError.closed("\(err)") }
            if receiveClosed && plainBuffer.isEmpty {
                throw RTSPError.closed("closed before full response")
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw RTSPError.timeout }
            _ = bufferCond.wait(until: Date().addingTimeInterval(remaining))
        }
    }
}
