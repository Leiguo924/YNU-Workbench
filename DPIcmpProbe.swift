import Foundation

struct DPIcmpProbe: Sendable {
    let packet: Data
    private let source: [UInt8]
    private let destination: [UInt8]
    private let identifier: UInt16
    private let payload: [UInt8]

    init(source: String, destination: String) throws {
        let local = try Self.parseIPv4(source)
        let remote = try Self.parseIPv4(destination)
        let id = UInt16.random(in: 1...UInt16.max)
        let payload = (0..<12).map { _ in UInt8.random(in: .min ... .max) }
        var icmp = [UInt8(8), 0, 0, 0, UInt8(id >> 8), UInt8(truncatingIfNeeded: id), 0, 1] + payload
        Self.fillChecksum(&icmp, index: 2)
        let length = UInt16(20 + icmp.count)
        var header: [UInt8] = [0x45, 0, UInt8(length >> 8), UInt8(truncatingIfNeeded: length),
                              UInt8(id >> 8), UInt8(truncatingIfNeeded: id), 0, 0, 64, 1, 0, 0]
        header.append(contentsOf: local)
        header.append(contentsOf: remote)
        Self.fillChecksum(&header, index: 10)
        self.packet = Data(header + icmp)
        self.source = local
        self.destination = remote
        self.identifier = id
        self.payload = payload
    }

    func matchesReply(_ packet: Data) -> Bool {
        let bytes = [UInt8](packet)
        guard bytes.count >= 28, bytes[0] >> 4 == 4, bytes[9] == 1 else { return false }
        let headerSize = Int(bytes[0] & 15) * 4
        let totalSize = Int(bytes[2]) * 256 + Int(bytes[3])
        guard headerSize >= 20, totalSize == bytes.count, bytes.count == headerSize + 8 + payload.count,
              bytes[12..<16].elementsEqual(destination), bytes[16..<20].elementsEqual(source),
              Self.internetChecksum(Array(bytes[..<headerSize])) == 0 else { return false }
        let icmp = Array(bytes[headerSize...])
        return icmp[0] == 0 && icmp[1] == 0 &&
            (UInt16(icmp[4]) << 8 | UInt16(icmp[5])) == identifier &&
            icmp[6] == 0 && icmp[7] == 1 && icmp.dropFirst(8).elementsEqual(payload) &&
            Self.internetChecksum(icmp) == 0
    }

    static func parseIPv4(_ address: String) throws -> [UInt8] {
        let fields = address.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = fields.compactMap { UInt8($0) }
        guard fields.count == 4, bytes.count == 4, bytes != [0, 0, 0, 0] else {
            throw DPTCPError.invalidRequest
        }
        return bytes
    }

    static func internetChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let low = index + 1 < bytes.count ? UInt32(bytes[index + 1]) : 0
            sum += UInt32(bytes[index]) << 8 | low
        }
        while sum > 0xffff { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    private static func fillChecksum(_ bytes: inout [UInt8], index: Int) {
        let checksum = internetChecksum(bytes)
        bytes[index] = UInt8(checksum >> 8)
        bytes[index + 1] = UInt8(truncatingIfNeeded: checksum)
    }

    func testFixture() -> Bool {
        var bytes = Array(packet)
        bytes.replaceSubrange(12..<16, with: destination)
        bytes.replaceSubrange(16..<20, with: source)
        bytes[10] = 0
        bytes[11] = 0
        let ipChecksum = Self.internetChecksum(Array(bytes[..<20]))
        bytes[10] = UInt8(ipChecksum >> 8)
        bytes[11] = UInt8(truncatingIfNeeded: ipChecksum)
        var icmp = Array(bytes[20...])
        icmp[0] = 0
        icmp[2] = 0
        icmp[3] = 0
        Self.fillChecksum(&icmp, index: 2)
        bytes.replaceSubrange(20..., with: icmp)
        guard matchesReply(Data(bytes)) else { return false }
        bytes[bytes.count - 1] ^= 1
        return !matchesReply(Data(bytes))
    }
}
