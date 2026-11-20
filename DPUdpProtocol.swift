import Foundation

struct DPUdpAssociations {
    let outbound: DPAssociation
    let inbound: DPAssociation

    init(data: Data) throws {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let inRecord = Self.wireValue("IN", in: object) as? [String: Any]
        let outRecord = Self.wireValue("OUT", in: object) as? [String: Any]
        let code = (Self.wireValue("Result", in: object) as? NSNumber)?.intValue
        guard code == nil || code == 0,
              let outgoing = try Self.parse(inRecord), let incoming = try Self.parse(outRecord) else {
            let expected = [("IN", inRecord), ("OUT", outRecord)].map { name, record in
                let fields = ["SPI", "authKey", "encKey"].filter { Self.wireValue($0, in: record ?? [:]) != nil }
                return "\(name)=\(record == nil ? "absent" : fields.joined(separator: ","))"
            }.joined(separator: "; ")
            throw DPUdpAssociationError(result: code, fields: expected, contentLength: data.count)
        }
        outbound = outgoing
        inbound = incoming
    }

    private static func parse(_ record: [String: Any]?) throws -> DPAssociation? {
        guard let record, let rawSPI = wireValue("SPI", in: record) as? NSNumber,
              let spi = UInt32(exactly: rawSPI.doubleValue),
              let auth = wireValue("authKey", in: record) as? String,
              let enc = wireValue("encKey", in: record) as? String else { return nil }
        return try DPAssociation(spi: spi, authenticationKey: Data(auth.utf8.prefix(20)),
                                 encryptionKey: Data(enc.utf8.prefix(16)))
    }

    private static func wireValue(_ name: String, in object: [String: Any]) -> Any? {
        // The vendor JSON parser compares field names case-insensitively.
        let matches = object.filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }
        return matches.count == 1 ? matches.first?.value : nil
    }
}

struct DPUdpAssociationError: LocalizedError {
    let result: Int?
    let fields: String
    let contentLength: Int
    var errorDescription: String? {
        "DP association response was incomplete (result: \(result.map(String.init) ?? "absent"), \(fields), bytes: \(contentLength))."
    }
}

enum DPUdpProtocol {
    static let gatewayPorts: [UInt16] = [1701, 442]

    static func synchronizationDatagram(sessionID: String) throws -> Data {
        let bytes = Data(sessionID.utf8)
        guard !bytes.isEmpty, bytes.count <= 32, bytes.allSatisfy({ (33...126).contains($0) }) else {
            throw DPPacketError.invalidAssociation
        }
        var datagram = Data(repeating: 0, count: 4)
        datagram.append(bytes)
        datagram.append(Data(repeating: 0, count: 32 - bytes.count))
        return datagram
    }

    static func isAcknowledgement(_ datagram: Data) -> Bool {
        datagram.starts(with: Data("RECV".utf8))
    }
}

struct DPReplayWindow {
    private var highest: UInt32?
    private var received: UInt64 = 0

    // Call only after validating the packet authentication tag.
    mutating func accept(_ sequence: UInt32) -> Bool {
        guard let highest else {
            self.highest = sequence
            received = 1
            return true
        }
        if sequence > highest {
            let shift = sequence - highest
            received = shift < 64 ? (received << shift) | 1 : 1
            self.highest = sequence
            return true
        }
        let age = highest - sequence
        guard age < 64 else { return false }
        let bit = UInt64(1) << age
        guard received & bit == 0 else { return false }
        received |= bit
        return true
    }
}
