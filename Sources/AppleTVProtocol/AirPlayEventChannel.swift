import Foundation
import Network
import CryptoKit
import AppleTVLogging

/// Handles the AirPlay event channel — a HAP-encrypted TCP connection that the
/// ATV opens *toward* us (client connects TO the ATV's eventPort) for sending
/// RTSP `POST /command` requests with device capability plists.
///
/// We must respond with `RTSP/1.0 200 OK` to each incoming request; failure to
/// respond causes the ATV to withhold all MRP now-playing pushes (it sends only
/// SET_CONNECTION_STATE and nothing more on the data channel).
///
/// Reference: pyatv `EventChannel` in `pyatv/protocols/airplay/channels.py`,
/// which calls `send_and_receive` to acknowledge each command.
public final class AirPlayEventChannel: @unchecked Sendable {

    private let connection: NWConnection
    private let session:    HAPSession
    private let queue:      DispatchQueue

    private var plainBuffer = Data()
    private let sep         = Data("\r\n\r\n".utf8)

    init(connection: NWConnection, session: HAPSession) {
        self.connection = connection
        self.session    = session
        self.queue      = DispatchQueue(label: "AirPlayEventChannel")
    }

    func start() { receiveLoop() }

    func close() { connection.cancel() }

    // MARK: - Private

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let plain = try self.session.feed(data)
                    if !plain.isEmpty { self.processPlain(plain) }
                } catch {
                    Log.pairing.fail("EventChannel: decrypt error: \(error)")
                    return
                }
            }
            guard err == nil, !isComplete else { return }
            self.receiveLoop()
        }
    }

    private func processPlain(_ data: Data) {
        plainBuffer.append(data)

        // Parse complete RTSP requests out of the buffer.
        while let hdrEnd = plainBuffer.range(of: sep) {
            let headerData = plainBuffer[plainBuffer.startIndex..<hdrEnd.lowerBound]
            let bodyStart  = hdrEnd.upperBound
            guard let headerStr = String(data: headerData, encoding: .utf8) else {
                plainBuffer = Data()
                return
            }
            let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard !lines.isEmpty else { plainBuffer = Data(); return }

            // Parse Content-Length header.
            var contentLength = 0
            for line in lines {
                if line.lowercased().hasPrefix("content-length:") {
                    contentLength = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let available = plainBuffer.endIndex - bodyStart
            guard available >= contentLength else { break }  // wait for more data

            let bodyEnd = bodyStart + contentLength
            // Extract CSeq for the reply.
            var cseq = "0"
            for line in lines {
                if line.lowercased().hasPrefix("cseq:") {
                    cseq = String(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                }
            }

            let statusLine = String(lines.first ?? "?")
            Log.pairing.report("EventChannel: rx \(statusLine) (body=\(contentLength)B)")

            // Consume from buffer.
            plainBuffer = Data(plainBuffer[bodyEnd...])

            // Send RTSP/1.0 200 OK reply.
            sendOK(cseq: cseq)
        }
    }

    private func sendOK(cseq: String) {
        let reply = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nAudio-Latency: 0\r\nContent-Length: 0\r\n\r\n"
        guard let encrypted = try? session.encrypt(Data(reply.utf8)) else { return }
        connection.send(content: encrypted, completion: .contentProcessed { err in
            if let err { Log.pairing.fail("EventChannel: send error: \(err)") }
        })
    }
}
