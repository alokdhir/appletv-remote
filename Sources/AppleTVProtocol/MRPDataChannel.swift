import Foundation
import Network
import CryptoKit
import AppleTVLogging

/// Encrypted data-stream channel to the Apple TV's MRP tunnel port.
///
/// After AirPlay RTSP SETUP #2 returns `dataPort`, a fresh TCP connection is
/// made to that port. It uses a dedicated HAPSession keyed with
/// `DataStream-Salt<seed>` / Output-Encryption-Key / Input-Encryption-Key —
/// distinct from the control channel keys.
///
/// Wire framing above the HAP ChaCha20 layer:
///
///   Each logical message is a 32-byte DataStreamMessage header followed by
///   a binary plist payload:
///
///     Offset  Size  Field
///       0       4   totalSize  (UInt32 BE) = 32 + payload.count
///       4      12   messageType ("sync\0\0\0\0\0\0\0\0" for client→ATV,
///                               "rply\0\0\0\0\0\0\0\0" for ATV→client)
///      16       4   command    ("comm" for MRP requests, "\0\0\0\0" in replies)
///      20       8   seqno      (UInt64 BE, increments per outgoing message)
///      28       4   padding    (0x00000000)
///
///   The plist payload encodes:
///     { "params": { "data": <varint-framed MRP protobuf bytes> } }
///
/// References:
///   pyatv/protocols/airplay/channels.py  (DataStreamChannel)
///   pyatv/auth/hap_channel.py            (AbstractHAPChannel)
public final class MRPDataChannel: @unchecked Sendable {

    public enum ChannelError: Error, CustomStringConvertible {
        case connectFailed(String)
        case sendFailed(String)
        case framingError(HAPSession.FramingError)
        case timeout
        case closed(String)

        public var description: String {
            switch self {
            case .connectFailed(let m):  return "data channel connect failed: \(m)"
            case .sendFailed(let m):     return "data channel send failed: \(m)"
            case .framingError(let e):   return "data channel framing: \(e)"
            case .timeout:               return "data channel timeout"
            case .closed(let m):         return "data channel closed: \(m)"
            }
        }
    }

    // MARK: - DataStreamMessage header (32 bytes, all big-endian)

    internal struct DataStreamHeader {
        static let length = 32
        let totalSize:   UInt32   // header + payload
        let messageType: (UInt8, UInt8, UInt8, UInt8,
                          UInt8, UInt8, UInt8, UInt8,
                          UInt8, UInt8, UInt8, UInt8)  // 12 bytes
        let command:     (UInt8, UInt8, UInt8, UInt8)  // 4 bytes
        let seqno:       UInt64
        let padding:     UInt32   // 0

        static let syncType: [UInt8] = [UInt8]("sync".utf8) + [UInt8](repeating: 0, count: 8)
        static let rplyType: [UInt8] = [UInt8]("rply".utf8) + [UInt8](repeating: 0, count: 8)
        static let commCmd:  [UInt8] = [UInt8]("comm".utf8)
        static let zeroCmd:  [UInt8] = [UInt8](repeating: 0, count: 4)

        func encode() -> Data {
            var d = Data()
            d.append(contentsOf: withUnsafeBytes(of: totalSize.bigEndian) { Array($0) })
            d.append(contentsOf: [
                messageType.0, messageType.1, messageType.2, messageType.3,
                messageType.4, messageType.5, messageType.6, messageType.7,
                messageType.8, messageType.9, messageType.10, messageType.11,
            ])
            d.append(contentsOf: [command.0, command.1, command.2, command.3])
            d.append(contentsOf: withUnsafeBytes(of: seqno.bigEndian) { Array($0) })
            d.append(contentsOf: withUnsafeBytes(of: padding.bigEndian) { Array($0) })
            return d
        }

        static func decode(_ data: Data) -> (header: DataStreamHeader, payload: Data)? {
            guard data.count >= length else { return nil }
            let b = data

            func u32(at off: Int) -> UInt32 {
                UInt32(b[b.index(b.startIndex, offsetBy: off)]) << 24 |
                UInt32(b[b.index(b.startIndex, offsetBy: off+1)]) << 16 |
                UInt32(b[b.index(b.startIndex, offsetBy: off+2)]) << 8 |
                UInt32(b[b.index(b.startIndex, offsetBy: off+3)])
            }
            func u64(at off: Int) -> UInt64 {
                (0..<8).reduce(UInt64(0)) { acc, i in
                    acc << 8 | UInt64(b[b.index(b.startIndex, offsetBy: off+i)])
                }
            }
            func byte(at off: Int) -> UInt8 { b[b.index(b.startIndex, offsetBy: off)] }

            let totalSize = u32(at: 0)
            let msgType: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (
                byte(at:4),byte(at:5),byte(at:6),byte(at:7),
                byte(at:8),byte(at:9),byte(at:10),byte(at:11),
                byte(at:12),byte(at:13),byte(at:14),byte(at:15)
            )
            let cmd: (UInt8,UInt8,UInt8,UInt8) = (byte(at:16),byte(at:17),byte(at:18),byte(at:19))
            let seqno   = u64(at: 20)
            let padding = u32(at: 28)

            let h = DataStreamHeader(totalSize: totalSize, messageType: msgType,
                                     command: cmd, seqno: seqno, padding: padding)
            let payloadLen = Int(totalSize) - length
            guard payloadLen >= 0, data.count >= Int(totalSize) else { return nil }
            let payload = Data(data[data.index(data.startIndex, offsetBy: length)..<data.index(data.startIndex, offsetBy: Int(totalSize))])
            return (h, payload)
        }
    }

    // MARK: - State

    private let connection: NWConnection
    private let session:    HAPSession
    private let queue:      DispatchQueue

    private let bufferCond   = NSCondition()
    private var plainBuffer  = Data()
    private var receiveError: Error?
    private var receiveClosed = false

    /// Initial seqno matches pyatv's DataStreamChannel: a random 33-bit value
    /// in `[0x1_0000_0000, 0x2_0000_0000)`. Some ATV firmware appears to reject
    /// sync requests whose seqno starts at 0.
    private var sendSeqno: UInt64 = UInt64.random(in: 0x1_0000_0000..<0x2_0000_0000)

    /// Called on the internal queue whenever a decoded MRP ProtocolMessage arrives.
    public var onMessage: ((Data) -> Void)?

    public init(connection: NWConnection, session: HAPSession) {
        self.connection = connection
        self.session    = session
        self.queue      = DispatchQueue(label: "MRPDataChannel")
    }

    /// Start the receive loop. Call once before sending anything.
    public func start() { receiveLoop() }

    public func close() { connection.cancel() }

    // MARK: - Send

    /// Send one or more varint-framed MRP protobuf messages wrapped in a
    /// DataStreamMessage → binary plist → HAP-encrypted TCP frame.
    public func send(_ mrpFrames: Data, timeoutSeconds: TimeInterval = 10) throws {
        let payload = encodePlist(mrpFrames: mrpFrames)
        sendSeqno += 1
        var hdr = Data()

        let totalSize = UInt32(DataStreamHeader.length + payload.count)
        hdr.append(contentsOf: withUnsafeBytes(of: totalSize.bigEndian) { Array($0) })
        hdr.append(contentsOf: DataStreamHeader.syncType)
        hdr.append(contentsOf: DataStreamHeader.commCmd)
        hdr.append(contentsOf: withUnsafeBytes(of: sendSeqno.bigEndian) { Array($0) })
        hdr.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Array($0) })
        hdr.append(payload)

        let encrypted: Data
        do { encrypted = try session.encrypt(hdr) }
        catch let e as HAPSession.FramingError { throw ChannelError.framingError(e) }
        catch { throw error }

        let g = DispatchGroup()
        g.enter()
        var sendErr: Error?
        connection.send(content: encrypted, completion: .contentProcessed { e in
            sendErr = e; g.leave()
        })
        guard g.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw ChannelError.timeout
        }
        if let e = sendErr { throw ChannelError.sendFailed("\(e)") }
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let plain = try self.session.feed(data)
                    if !plain.isEmpty {
                            self.processPlaintext(plain)
                    }
                } catch {
                    Log.pairing.fail("MRPDataChannel: decrypt error: \(error)")
                    self.bufferCond.lock()
                    self.receiveError = error
                    self.receiveClosed = true
                    self.bufferCond.broadcast()
                    self.bufferCond.unlock()
                    return
                }
            }
            if let err {
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

    private func processPlaintext(_ plain: Data) {
        bufferCond.lock()
        plainBuffer.append(plain)
        // Drain complete DataStreamMessages
        while plainBuffer.count >= DataStreamHeader.length {
            guard let (hdr, payload) = DataStreamHeader.decode(plainBuffer) else { break }
            let consumed = DataStreamHeader.length + payload.count
            plainBuffer = Data(plainBuffer[plainBuffer.index(plainBuffer.startIndex, offsetBy: consumed)...])
            bufferCond.unlock()
            handleIncoming(hdr: hdr, payload: payload)
            bufferCond.lock()
        }
        bufferCond.broadcast()
        bufferCond.unlock()
    }

    private func handleIncoming(hdr: DataStreamHeader, payload: Data) {
        let typBytes = [hdr.messageType.0, hdr.messageType.1, hdr.messageType.2, hdr.messageType.3]
        let isSync   = typBytes == DataStreamHeader.syncType.prefix(4).map { $0 }

        if isSync {
            // Send a reply to every sync from the ATV.
            sendReply(seqno: hdr.seqno)
        }

        // Decode the plist wrapper to extract MRP protobuf bytes.
        guard let mrpFrames = decodePlist(payload) else { return }
        // Each varint-framed MRP message in mrpFrames.
        var offset = 0
        while offset < mrpFrames.count {
            var o = offset
            guard let len = mrpFrames.readVarintFrom(offset: &o) else { break }
            let end = o + Int(len)
            guard end <= mrpFrames.count else { break }
            let msg = Data(mrpFrames[mrpFrames.index(mrpFrames.startIndex, offsetBy: o)..<mrpFrames.index(mrpFrames.startIndex, offsetBy: end)])
            offset = end
            let msgType = MRPDecoder.messageType(from: msg) ?? 0
            Log.pairing.report("MRPDataChannel: rx MRP type=\(msgType) (\(msg.count)B)")
            onMessage?(msg)
        }
    }

    private func sendReply(seqno: UInt64) {
        var hdr = Data()
        let totalSize = UInt32(DataStreamHeader.length)
        hdr.append(contentsOf: withUnsafeBytes(of: totalSize.bigEndian) { Array($0) })
        hdr.append(contentsOf: DataStreamHeader.rplyType)
        hdr.append(contentsOf: DataStreamHeader.zeroCmd)
        hdr.append(contentsOf: withUnsafeBytes(of: seqno.bigEndian) { Array($0) })
        hdr.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Array($0) })

        guard let encrypted = try? session.encrypt(hdr) else { return }
        // Use .contentProcessed (not .idempotent) so the NW stack won't retry
        // on transient error — reordering sync/rply seqnos would confuse the ATV.
        connection.send(content: encrypted, completion: .contentProcessed { err in
            if let err { Log.pairing.fail("MRPDataChannel: rply send failed: \(err)") }
        })
    }

    // MARK: - Plist encode / decode

    /// Wrap varint-framed MRP bytes in the plist envelope the ATV expects.
    private func encodePlist(mrpFrames: Data) -> Data {
        let plist: [String: Any] = ["params": ["data": mrpFrames]]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)) ?? Data()
    }

    /// Extract MRP bytes from the plist envelope the ATV sends.
    private func decodePlist(_ data: Data) -> Data? {
        guard !data.isEmpty,
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any],
              let params = dict["params"] as? [String: Any],
              let mrp   = params["data"] as? Data else { return nil }
        return mrp
    }
}
