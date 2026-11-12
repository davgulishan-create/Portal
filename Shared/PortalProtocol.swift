import Foundation

/// Shared constants + wire format used by both the iOS and macOS apps.
enum Portal {
    /// Bonjour service type. Must match NSBonjourServices in both Info.plists.
    static let serviceType = "_portal._tcp"
    /// Hard cap on a single transfer so a bad peer can't make us allocate unbounded memory.
    static let maxPayload: UInt64 = 1 << 30 // 1 GiB
    static let maxNameLength = 1024
}

enum PortalMessage {
    /// First message on every connection.
    /// iPhone -> Mac: name = iPhone name, code = pairing code.
    /// Mac -> iPhone: name = Mac name, code = "" (means "accepted").
    case hello(name: String, code: String)
    /// Sent by the Mac when the pairing code is wrong. The Mac closes the connection after this.
    case reject(reason: String)
    /// A file transfer.
    case file(name: String, data: Data)
    /// Receiver confirms it stored the file.
    case ack(name: String)
}

/// Wire format (all integers big-endian):
///
///   [4]  magic "PRTL"
///   [1]  version (1)
///   [1]  kind (1 hello, 2 reject, 3 file, 4 ack)
///   [2]  name length N
///   [8]  payload length P
///   [N]  UTF-8 name
///   [P]  payload (file bytes, pairing code, or reject reason)
enum PortalCodec {
    static let magic: [UInt8] = Array("PRTL".utf8)
    static let version: UInt8 = 1
    static let headerSize = 16

    enum Kind: UInt8 { case hello = 1, reject = 2, file = 3, ack = 4 }

    struct Header {
        let kind: Kind
        let nameLength: Int
        let payloadLength: UInt64
    }

    enum DecodeError: Error { case badMagic, badVersion, badKind, tooLarge }

    static func encode(_ message: PortalMessage) -> Data {
        let kind: Kind
        let name: String
        let payload: Data
        switch message {
        case let .hello(n, code): kind = .hello; name = n; payload = Data(code.utf8)
        case let .reject(reason): kind = .reject; name = ""; payload = Data(reason.utf8)
        case let .file(n, data): kind = .file; name = n; payload = data
        case let .ack(n): kind = .ack; name = n; payload = Data()
        }
        let nameBytes = Array(name.utf8.prefix(Portal.maxNameLength))

        var out = Data(capacity: headerSize + nameBytes.count + payload.count)
        out.append(contentsOf: magic)
        out.append(version)
        out.append(kind.rawValue)
        out.append(contentsOf: bigEndianBytes(UInt16(nameBytes.count)))
        out.append(contentsOf: bigEndianBytes(UInt64(payload.count)))
        out.append(contentsOf: nameBytes)
        out.append(payload)
        return out
    }

    static func decodeHeader(_ data: Data) throws -> Header {
        let b = Array(data)
        guard b.count == headerSize, Array(b[0..<4]) == magic else { throw DecodeError.badMagic }
        guard b[4] == version else { throw DecodeError.badVersion }
        guard let kind = Kind(rawValue: b[5]) else { throw DecodeError.badKind }
        let nameLen = Int(b[6]) << 8 | Int(b[7])
        var payloadLen: UInt64 = 0
        for i in 8..<16 { payloadLen = payloadLen << 8 | UInt64(b[i]) }
        guard nameLen <= Portal.maxNameLength, payloadLen <= Portal.maxPayload else { throw DecodeError.tooLarge }
        return Header(kind: kind, nameLength: nameLen, payloadLength: payloadLen)
    }

    static func message(header: Header, name: String, payload: Data) -> PortalMessage {
        switch header.kind {
        case .hello: return .hello(name: name, code: String(decoding: payload, as: UTF8.self))
        case .reject: return .reject(reason: String(decoding: payload, as: UTF8.self))
        case .file: return .file(name: name, data: payload)
        case .ack: return .ack(name: name)
        }
    }

    private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
}

/// Turns an untrusted filename from the network into a safe last-path-component.
enum FileNames {
    static func sanitize(_ raw: String, fallback: String = "Portal File") -> String {
        var name = (raw as NSString).lastPathComponent
        name = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? fallback : String(name.prefix(200))
    }

    /// Returns a URL in `directory` that doesn't exist yet: "IMG_1.HEIC", "IMG_1 (1).HEIC", …
    static func uniqueURL(in directory: URL, for name: String) -> URL {
        let fm = FileManager.default
        var url = directory.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        while fm.fileExists(atPath: url.path) {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            url = directory.appendingPathComponent(candidate)
            n += 1
        }
        return url
    }
}
