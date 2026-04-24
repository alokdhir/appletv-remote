import Foundation

/// Minimal binary plist (bplist00) writer that correctly encodes UID references
/// using the `0x8N` tag required by NSKeyedArchiver / RTIKeyedArchiver.
///
/// `PropertyListSerialization` serialises `["CF$UID": N]` dicts as regular
/// dictionaries, which the ATV's archiver cannot decode as UID references.
/// This writer produces byte-level–compatible output with Python's `plistlib`.
///
/// Object-reference size is chosen automatically at `build()` time:
///   ≤ 255 objects  → 1-byte refs
///   ≤ 65535 objects → 2-byte refs
/// Beyond 65535 objects `build()` precondition-fails.
struct BinaryPlistWriter {

    // MARK: - Public value types

    /// A reference to an already-added object (by index in `objects`).
    struct ObjRef {
        let index: Int
    }

    // MARK: - Internal object representation

    private enum Obj {
        case raw([UInt8])                        // scalars: int, string, data, UID
        case array([Int])                        // indices of elements
        case dict([Int], [Int])                  // parallel key-indices, value-indices
    }

    // MARK: - State

    private var objects: [Obj] = []

    // MARK: - Adding objects

    /// Append the `$null` sentinel string used in NSKeyedArchiver archives.
    @discardableResult
    mutating func addNull() -> ObjRef {
        return addString("$null")
    }

    /// Encode a non-negative integer.
    /// - Precondition: `value >= 0`. Binary plist signed encoding (tag 0x13)
    ///   is not implemented — NSKeyedArchiver payloads use only non-negative ints.
    @discardableResult
    mutating func addInt(_ value: Int) -> ObjRef {
        precondition(value >= 0, "BinaryPlistWriter.addInt: negative values not supported")
        let bytes: [UInt8]
        if value <= 0xFF {
            bytes = [0x10, UInt8(value)]
        } else if value <= 0xFFFF {
            let v = UInt16(value)
            bytes = [0x11, UInt8(v >> 8), UInt8(v & 0xFF)]
        } else {
            let v = UInt32(value)
            bytes = [0x12,
                     UInt8(v >> 24), UInt8((v >> 16) & 0xFF),
                     UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
        return append(.raw(bytes))
    }

    /// Encode a UID reference — the binary plist `0x8N` type that
    /// NSKeyedArchiver / RTIKeyedArchiver uses for object cross-references.
    /// Supports values up to 0xFFFFFFFF (4-byte UID).
    @discardableResult
    mutating func addUID(_ value: UInt32) -> ObjRef {
        let bytes: [UInt8]
        if value <= 0xFF {
            bytes = [0x80, UInt8(value)]
        } else if value <= 0xFFFF {
            bytes = [0x81, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        } else {
            bytes = [0x83,
                     UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8)  & 0xFF), UInt8(value & 0xFF)]
        }
        return append(.raw(bytes))
    }

    @discardableResult
    mutating func addString(_ s: String) -> ObjRef {
        let isASCII = s.unicodeScalars.allSatisfy { $0.value < 128 }
        let bytes: [UInt8]
        if isASCII {
            let payload = Array(s.utf8)
            bytes = lengthPrefixed(tag: 0x50, count: payload.count) + payload
        } else {
            // Encode as UTF-16BE with proper surrogate pairs for chars > U+FFFF.
            var utf16: [UInt8] = []
            for scalar in s.unicodeScalars {
                let v = scalar.value
                if v <= 0xFFFF {
                    utf16.append(UInt8((v >> 8) & 0xFF))
                    utf16.append(UInt8(v & 0xFF))
                } else {
                    let vp = v - 0x10000
                    let hi = UInt16(0xD800 + (vp >> 10))
                    let lo = UInt16(0xDC00 + (vp & 0x3FF))
                    utf16.append(UInt8(hi >> 8)); utf16.append(UInt8(hi & 0xFF))
                    utf16.append(UInt8(lo >> 8)); utf16.append(UInt8(lo & 0xFF))
                }
            }
            let charCount = utf16.count / 2
            bytes = lengthPrefixed(tag: 0x60, count: charCount) + utf16
        }
        return append(.raw(bytes))
    }

    @discardableResult
    mutating func addData(_ d: Data) -> ObjRef {
        let payload = Array(d)
        let bytes = lengthPrefixed(tag: 0x40, count: payload.count) + payload
        return append(.raw(bytes))
    }

    /// Add an array whose elements are already-added object references.
    @discardableResult
    mutating func addArray(_ refs: [ObjRef]) -> ObjRef {
        return append(.array(refs.map { $0.index }))
    }

    /// Add a dictionary. Keys and values must be already-added object references,
    /// passed as `(key, value)` pairs.
    @discardableResult
    mutating func addDict(_ kvPairs: [(ObjRef, ObjRef)]) -> ObjRef {
        return append(.dict(kvPairs.map { $0.0.index }, kvPairs.map { $0.1.index }))
    }

    // MARK: - Serialise

    /// Serialise all objects into a binary plist with `topObject` as the root.
    /// Supports up to 65535 objects (2-byte refs). Precondition-fails beyond that.
    func build(topObject: ObjRef) -> Data {
        precondition(objects.count <= 0xFFFF,
                     "BinaryPlistWriter: too many objects (\(objects.count)); max 65535")
        let refSize = objects.count <= 0xFF ? 1 : 2

        // Render each object to bytes now that refSize is known.
        var body = Data()
        var offsets: [Int] = []
        let headerLen = 8  // "bplist00"

        for obj in objects {
            offsets.append(headerLen + body.count)
            switch obj {
            case .raw(let bytes):
                body.append(contentsOf: bytes)
            case .array(let indices):
                body.append(contentsOf: lengthPrefixed(tag: 0xA0, count: indices.count))
                for idx in indices { body.append(contentsOf: refBytes(idx, size: refSize)) }
            case .dict(let keys, let vals):
                body.append(contentsOf: lengthPrefixed(tag: 0xD0, count: keys.count))
                for idx in keys { body.append(contentsOf: refBytes(idx, size: refSize)) }
                for idx in vals { body.append(contentsOf: refBytes(idx, size: refSize)) }
            }
        }

        let offsetTableStart = headerLen + body.count
        let offsetSize = offsetTableStart <= 0xFF ? 1 : (offsetTableStart <= 0xFFFF ? 2 : 4)

        var result = Data("bplist00".utf8)
        result.append(body)

        for off in offsets {
            for shift in stride(from: (offsetSize - 1) * 8, through: 0, by: -8) {
                result.append(UInt8((off >> shift) & 0xFF))
            }
        }

        // 32-byte trailer
        result.append(contentsOf: [0, 0, 0, 0, 0, 0])   // 6 unused bytes
        result.append(UInt8(offsetSize))
        result.append(UInt8(refSize))
        appendUInt64(&result, UInt64(objects.count))
        appendUInt64(&result, UInt64(topObject.index))
        appendUInt64(&result, UInt64(offsetTableStart))

        return result
    }

    // MARK: - Private helpers

    @discardableResult
    private mutating func append(_ obj: Obj) -> ObjRef {
        objects.append(obj)
        return ObjRef(index: objects.count - 1)
    }

    private func refBytes(_ idx: Int, size: Int) -> [UInt8] {
        if size == 1 {
            return [UInt8(idx & 0xFF)]
        } else {
            return [UInt8((idx >> 8) & 0xFF), UInt8(idx & 0xFF)]
        }
    }

    private func lengthPrefixed(tag: UInt8, count: Int) -> [UInt8] {
        if count < 15 {
            return [tag | UInt8(count)]
        } else {
            var header: [UInt8] = [tag | 0x0F]
            if count <= 0xFF {
                header += [0x10, UInt8(count)]
            } else if count <= 0xFFFF {
                let v = UInt16(count)
                header += [0x11, UInt8(v >> 8), UInt8(v & 0xFF)]
            } else {
                let v = UInt32(count)
                header += [0x12,
                            UInt8(v >> 24), UInt8((v >> 16) & 0xFF),
                            UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
            }
            return header
        }
    }

    private func appendUInt64(_ data: inout Data, _ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> shift) & 0xFF))
        }
    }
}
