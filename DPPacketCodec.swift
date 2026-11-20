import CommonCrypto
import CryptoKit
import Foundation
import Security

enum DPPacketError: LocalizedError {
    case invalidAssociation
    case invalidPacket
    case invalidTrailer(nextHeader: UInt8, paddingLength: Int)
    case unexpectedSPI
    case invalidTag
    case encryptionFailure

    var errorDescription: String? {
        switch self {
        case .invalidAssociation: return "Invalid DP association parameters."
        case .invalidPacket: return "Invalid DP packet framing."
        case let .invalidTrailer(nextHeader, paddingLength):
            return "Invalid authenticated DP trailer (next header: \(nextHeader), padding: \(paddingLength))."
        case .unexpectedSPI: return "The packet belongs to a different DP association."
        case .invalidTag: return "DP packet authentication failed."
        case .encryptionFailure: return "DP packet encryption or decryption failed."
        }
    }
}

struct DPAssociation {
    let spi: UInt32
    fileprivate let authenticationKey: SymmetricKey
    fileprivate let encryptionKey: Data

    init(spi: UInt32, authenticationKey: Data, encryptionKey: Data) throws {
        guard authenticationKey.count == 20, encryptionKey.count == 16 else {
            throw DPPacketError.invalidAssociation
        }
        self.spi = spi
        self.authenticationKey = SymmetricKey(data: authenticationKey)
        self.encryptionKey = encryptionKey
    }
}

enum DPPacketCodec {
    static let headerLength = 24
    private static let blockLength = 16
    private static let tagLength = 12

    static func seal(_ packet: Data, sequence: UInt32, association: DPAssociation) throws -> Data {
        var iv = Data(count: blockLength)
        let status = iv.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, blockLength, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw DPPacketError.encryptionFailure }
        return try seal(packet, sequence: sequence, association: association, iv: iv)
    }

    static func seal(_ packet: Data, sequence: UInt32, association: DPAssociation, iv: Data) throws -> Data {
        guard packet.count >= 20, packet.count <= Int(UInt16.max),
              packet.first.map({ $0 >> 4 }) == 4, iv.count == blockLength else {
            throw DPPacketError.invalidPacket
        }
        let padLength = (blockLength - (packet.count + 2) % blockLength) % blockLength
        var plain = packet
        plain.append(contentsOf: (0..<padLength).map(UInt8.init))
        plain.append(UInt8(padLength))
        plain.append(4)

        var wire = Data()
        for field in [association.spi, sequence] {
            for shift in [24, 16, 8, 0] {
                wire.append(UInt8(truncatingIfNeeded: field >> shift))
            }
        }
        wire.append(iv)
        wire.append(try crypt(plain, key: association.encryptionKey, iv: iv, operation: CCOperation(kCCEncrypt)))
        wire.append(tag(for: wire, key: association.authenticationKey))
        return wire
    }

    static func open(_ wire: Data, association: DPAssociation) throws -> (sequence: UInt32, packet: Data) {
        let cipherLength = wire.count - headerLength - tagLength
        guard cipherLength >= 2 * blockLength, cipherLength % blockLength == 0,
              cipherLength <= Int(UInt16.max) + blockLength else { throw DPPacketError.invalidPacket }
        let receivedSPI = wire.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard receivedSPI == association.spi else { throw DPPacketError.unexpectedSPI }
        let authenticated = wire.dropLast(tagLength)
        guard hasValidTag(wire, association: association) else { throw DPPacketError.invalidTag }

        let sequence = wire.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let iv = Data(wire.dropFirst(8).prefix(blockLength))
        let encrypted = Data(authenticated.dropFirst(headerLength))
        let plain = try crypt(encrypted, key: association.encryptionKey, iv: iv, operation: CCOperation(kCCDecrypt))
        let nextHeader = plain.last!
        let padLength = Int(plain.suffix(2).first!)
        let length = plain.count - padLength - 2
        guard nextHeader == 4, length >= 20, plain[0] >> 4 == 4 else {
            throw DPPacketError.invalidTrailer(nextHeader: nextHeader, paddingLength: padLength)
        }
        let headerLength = Int(plain[0] & 15) * 4
        let ipLength = Int(plain[2]) * 256 + Int(plain[3])
        // Padding bytes are covered by the verified tag. Validate the IP length rather than a padding pattern.
        guard headerLength >= 20, headerLength <= length, ipLength == length else {
            throw DPPacketError.invalidTrailer(nextHeader: nextHeader, paddingLength: padLength)
        }
        return (sequence, Data(plain.prefix(length)))
    }

    static func hasValidTag(_ wire: Data, association: DPAssociation) -> Bool {
        guard wire.count >= headerLength + tagLength else { return false }
        let expected = tag(for: Data(wire.dropLast(tagLength)), key: association.authenticationKey)
        return zip(expected, wire.suffix(tagLength)).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func tag(for data: Data, key: SymmetricKey) -> Data {
        // The vendor protocol uses the first 96 bits of HMAC-SHA1.
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key).prefix(tagLength))
    }

    private static func crypt(_ data: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        let capacity = data.count + blockLength
        var result = Data(count: capacity)
        var written = 0
        let status = result.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), 0, keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress, input.baseAddress, data.count, output.baseAddress,
                                capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess, written == data.count else { throw DPPacketError.encryptionFailure }
        return result.prefix(written)
    }
}
