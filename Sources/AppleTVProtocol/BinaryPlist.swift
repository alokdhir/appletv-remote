import Foundation

/// Minimal binary plist (bplist00) writer that correctly encodes UID references
/// using the `0x8N` tag required by NSKeyedArchiver / RTIKeyedArchiver.
///
/// `PropertyListSerialization` serialises `["CF$UID": N]` dicts as regular
/// dictionaries, which the ATV's archiver cannot decode as UID references.
/// This writer produces byte-level–compatible output with Python's `plistlib`.
struct BinaryPlistWriter {

    // MARK: - Public value types

    /// A reference to an already-added object (by index in `objects`).
    struct ObjRef {
        let index: Int
    }

    // MARK: - State

    private var objects: [[UInt8]] = []

    // MARK: - Adding objects

    /// Append the `$null` sentinel string used in NSKeyedArchiver archives.
    @discardableResult
    mutating func addNull() -> ObjRef {
        return addString("$null")
    }

    @discardableResult
    mutating func addInt(_ value: Int) -> ObjRef {
        let bytes: [UInt8]
        if value >= 0 && value <= 0xFF {
            bytes = [0x10, UInt8(value)]
        } else if value >= 0 && value <= 0xFFFF {
            let v = UInt16(value)
            bytes = [0x11, UInt8(v >> 8), UInt8(v & 0xFF)]
        } else {
            let v = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
            bytes = [0x12,
                     UInt8(v >> 24), UInt8((v >> 16) & 0xFF),
                     UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
        return append(bytes)
    }

    /// Encode a UID reference — the binary plist `0x8N` type that
    /// NSKeyedArchiver / RTIKeyedArchiver uses for object cross-references.
    @discardableResult
    mutating func addUID(_ value: UInt32) -> ObjRef {
        if value <= 0xFF {
            return append([0x80, UInt8(value)])
        } else {
            return append([0x81, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        }
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
                    // Encode as UTF-16 surrogate pair
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
        return append(bytes)
    }

    @discardableResult
    mutating func addData(_ d: Data) -> ObjRef {
        let payload = Array(d)
        let bytes = lengthPrefixed(tag: 0x40, count: payload.count) + payload
        return append(bytes)
    }

    /// Add an array whose elements are already-added object references.
    @discardableResult
    mutating func addArray(_ refs: [ObjRef]) -> ObjRef {
        var bytes = lengthPrefixed(tag: 0xA0, count: refs.count)
        for r in refs { bytes += objRefBytes(r.index) }
        return append(bytes)
    }

    /// Add a dictionary. Keys and values must be already-added object references,
    /// passed as `(key, value)` pairs.
    @discardableResult
    mutating func addDict(_ kvPairs: [(ObjRef, ObjRef)]) -> ObjRef {
        var bytes = lengthPrefixed(tag: 0xD0, count: kvPairs.count)
        for (k, _) in kvPairs { bytes += objRefBytes(k.index) }
        for (_, v) in kvPairs { bytes += objRefBytes(v.index) }
        return append(bytes)
    }

    // MARK: - Serialise

    /// Serialise all objects into a binary plist with `topObject` as the root.
    func build(topObject: ObjRef) -> Data {
        precondition(objects.count <= 0xFF, "BinaryPlistWriter: too many objects (\(objects.count)) for 1-byte refs")
        let refSize = 1

        // Lay out object bytes and record offsets.
        var body = Data()
        var offsets: [Int] = []
        let headerLen = 8  // "bplist00"
        for obj in objects {
            offsets.append(headerLen + body.count)
            body.append(contentsOf: obj)
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
    private mutating func append(_ bytes: [UInt8]) -> ObjRef {
        objects.append(bytes)
        return ObjRef(index: objects.count - 1)
    }

    private func objRefBytes(_ idx: Int) -> [UInt8] {
        // objRefSize is always 1 for our use-case (RTI payloads have ~50 objects max).
        // If this writer is ever used for larger plists, the add* methods would need
        // to be called with a known final refSize so refs are encoded correctly.
        precondition(idx <= 0xFF, "BinaryPlistWriter: object index \(idx) exceeds 1-byte ref limit")
        return [UInt8(idx)]
    }

    private func lengthPrefixed(tag: UInt8, count: Int) -> [UInt8] {
        if count < 15 {
            return [tag | UInt8(count)]
        } else {
            // count encoded as a nested int object (inline)
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
