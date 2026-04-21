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

    /// Strong reference to the pre-pair-verify HTTP client. Its receive loop
    /// is the one actually reading bytes off the wire (it was armed during
    /// pair-verify and we detached into it via sink forwarding). If we don't
    /// hold it here, `AirPlayHTTP` deallocates when `openHTTP` returns, its
    /// `[weak self]` receive callback fires with nil self when data arrives,
    /// and the sink never runs — the ATV's SETUP response was silently
    /// dropped for this exact reason for four rounds of debugging.
    private var httpKeepalive: AnyObject?
    public func retainHTTP(_ http: AnyObject) { httpKeepalive = http }

    /// Diagnostic override: when false, requests are sent plaintext and
    /// inbound bytes are passed through un-decrypted. This exists because
    /// pyatv's wire trace shows the RTSP control channel stays PLAINTEXT
    /// after pair-verify — only the separate event/data channels use HAP
    /// encryption. Flipping this to false confirms that hypothesis without
    /// a full refactor.
    public static var encryptionEnabled = true

    /// When true, every send / receive / decrypt step is mirrored to stderr
    /// so CLI debugging can see the wire activity that os_log hides.
    public static var verbose = true

    private func trace(_ s: @autoclosure () -> String) {
        if Self.verbose {
            FileHandle.standardError.write(Data("[rtsp \(host)] \(s())\n".utf8))
        }
    }

    // Plaintext receive buffer — `feed` appends, `readResponse` drains.
    private let bufferCond   = NSCondition()
    private var plainBuffer  = Data()
    private var receiveError: Error?
    private var receiveClosed = false

    /// First request uses CSeq=0 (matches pyatv); we post-increment.
    private var cseq = -1

    /// Per-session identifiers sent as RTSP headers. pyatv sends all three
    /// on every request after pair-verify; some tvOS builds silently drop
    /// requests missing them. Notably pyatv uses the SAME 16-char hex value
    /// for DACP-ID and Client-Instance — using a UUID for Client-Instance
    /// appears to be rejected by tvOS 18.
    private let dacpID         = String(format: "%016llX", UInt64.random(in: 1..<UInt64.max))
    private let activeRemote   = "\(UInt32.random(in: 1..<UInt32.max))"
    private var clientInstance: String { dacpID }

    /// Lazily-resolved local IP of the NWConnection. pyatv puts the CLIENT's
    /// IP in the RTSP URI (`rtsp://<local-ip>/<id>`); tvOS 18 silently drops
    /// requests whose URI uses the server's IP or a hostname/UUID path.
    public private(set) lazy var localIP: String = {
        if let endpoint = connection.currentPath?.localEndpoint,
           case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let addr): return "\(addr)"
            case .ipv6(let addr): return "\(addr)"
            case .name(let n, _): return n
            @unknown default:     return "0.0.0.0"
            }
        }
        return "0.0.0.0"
    }()

    /// Random 32-bit session ID — part of the RTSP URI, matches pyatv's format.
    public let sessionID: UInt32 = UInt32.random(in: 1..<UInt32.max)

    /// The fully-formed RTSP URI every request must use.
    public var rtspURI: String { "rtsp://\(localIP)/\(sessionID)" }

    public init(connection: NWConnection, session: HAPSession, host: String) {
        self.connection = connection
        self.session    = session
        self.host       = host
        self.queue      = DispatchQueue(label: "EncryptedAirPlayRTSP.\(host)")
    }

    /// No-op kept for source compatibility. Inbound bytes now arrive via
    /// `handle(data:err:isComplete:)`, which `AirPlayHTTP.detach(sink:)`
    /// installs as the forwarding sink. Calling `connection.receive` here
    /// would race with the in-flight receive AirPlayHTTP already queued.
    public func start() { /* intentionally empty */ }

    public func close() { connection.cancel() }

    /// Called by the AirPlayHTTP detach sink for every receive callback after
    /// pair-verify handoff. Decrypts inbound ciphertext into `plainBuffer`
    /// and signals `bufferCond` so `readResponse` can wake.
    public func handle(data: Data?, err: Error?, isComplete: Bool) {
        if let data, !data.isEmpty {
            trace("rx \(data.count)B from wire")
            if Self.encryptionEnabled {
                do {
                    let plain = try session.feed(data)
                    if !plain.isEmpty {
                        trace("rx decrypted \(plain.count)B plaintext")
                        bufferCond.lock()
                        plainBuffer.append(plain)
                        bufferCond.broadcast()
                        bufferCond.unlock()
                    } else {
                        trace("rx decrypted 0B (partial frame, waiting for more)")
                    }
                } catch {
                    trace("rx decrypt ERROR: \(error)")
                    Log.pairing.fail("RTSP: decrypt error: \(error)")
                    bufferCond.lock()
                    receiveError = error
                    receiveClosed = true
                    bufferCond.broadcast()
                    bufferCond.unlock()
                    return
                }
            } else {
                trace("rx (plaintext pass-through) \(data.count)B")
                bufferCond.lock()
                plainBuffer.append(data)
                bufferCond.broadcast()
                bufferCond.unlock()
            }
        }
        if let err {
            trace("rx socket ERROR: \(err)")
            Log.pairing.fail("RTSP: receive error: \(err)")
            bufferCond.lock()
            receiveError = err
            receiveClosed = true
            bufferCond.broadcast()
            bufferCond.unlock()
            return
        }
        if isComplete {
            trace("rx socket EOF")
            bufferCond.lock()
            receiveClosed = true
            bufferCond.broadcast()
            bufferCond.unlock()
        }
    }

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
        req    += "User-Agent: AirPlay/550.10\r\n"
        req    += "DACP-ID: \(dacpID)\r\n"
        req    += "Active-Remote: \(activeRemote)\r\n"
        req    += "Client-Instance: \(clientInstance)\r\n"
        // Only emit Content-Length for non-empty bodies. tvOS 18 returns 500
        // Internal Server Error to RECORD if Content-Length: 0 is present —
        // pyatv omits the header entirely for empty-body requests and the
        // ATV accepts that. Confirmed by wire-diff: identical request except
        // for this header, ours 500, pyatv's 200.
        if !body.isEmpty {
            req += "Content-Length: \(body.count)\r\n"
        }
        for (k, v) in headers { req += "\(k): \(v)\r\n" }
        req    += "\r\n"
        var frame = Data(req.utf8)
        frame.append(body)

        Log.pairing.report("RTSP: → \(method) \(uri) (body=\(body.count)B, cseq=\(cseq))")

        trace("tx plaintext \(frame.count)B:\n\(String(data: Data(req.utf8), encoding: .utf8) ?? "<non-utf8>")")
        let onWire: Data
        if Self.encryptionEnabled {
            do { onWire = try session.encrypt(frame) }
            catch { throw RTSPError.framing(error as! HAPSession.FramingError) }
            trace("tx encrypted \(onWire.count)B on wire")
        } else {
            onWire = frame
            trace("tx PLAINTEXT (encryption disabled) \(onWire.count)B on wire")
        }
        let encrypted = onWire

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
