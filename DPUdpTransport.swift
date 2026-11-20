import Darwin
import Foundation

enum DPUdpError: LocalizedError {
    case synchronizationTimedOut
    case noMatchingReply(String)

    var errorDescription: String? {
        switch self {
        case .synchronizationTimedOut: return "The DP gateway did not acknowledge UDP synchronization on either port."
        case .noMatchingReply(let details): return "No matching UDP tunnel reply (\(details))."
        }
    }
}

final class DPUdpTransport {
    let descriptor: Int32
    let port: UInt16
    private var sequence: UInt32 = 0
    private var replayWindow = DPReplayWindow()

    private init(address: String, port: UInt16) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw Self.lastError() }
        do {
            var peer = sockaddr_in()
            peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            peer.sin_family = sa_family_t(AF_INET)
            peer.sin_port = port.bigEndian
            guard inet_pton(AF_INET, address, &peer.sin_addr) == 1 else { throw POSIXError(.EINVAL) }
            let status = withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard status == 0 else { throw Self.lastError() }
            self.descriptor = descriptor
            self.port = port
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit { Darwin.close(descriptor) }

    static func synchronize(address: String, request: Data,
                            ports: [UInt16] = DPUdpProtocol.gatewayPorts) throws -> DPUdpTransport {
        for port in ports {
            let transport = try DPUdpTransport(address: address, port: port)
            do {
                try transport.send(request)
                let deadline = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
                while let response = try transport.receive(before: deadline) {
                    if DPUdpProtocol.isAcknowledgement(response) { return transport }
                }
            } catch let error as POSIXError where error.code == .ECONNREFUSED || error.code == .EHOSTUNREACH {
                continue
            }
        }
        throw DPUdpError.synchronizationTimedOut
    }

    func verifyRoundTrip(_ packet: Data, associations: DPUdpAssociations,
                         matchesReply: (Data) -> Bool) throws {
        var validated = 0
        var received = 0
        var validTagWithDifferentSPI = 0
        var invalidTags = 0
        var invalidFrames = 0
        var acknowledgements = 0
        var trailers = Set<String>()
        var lengths = Set<Int>()
        for _ in 0..<3 {
            try sendPacket(packet, association: associations.outbound)
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_500_000_000
            while let wire = try receive(before: deadline) {
                received += 1
                lengths.insert(wire.count)
                if DPUdpProtocol.isAcknowledgement(wire) { acknowledgements += 1; continue }
                do {
                    let decoded = try DPPacketCodec.open(wire, association: associations.inbound)
                    guard replayWindow.accept(decoded.sequence) else { continue }
                    validated += 1
                    if matchesReply(decoded.packet) { return }
                } catch DPPacketError.unexpectedSPI {
                    if DPPacketCodec.hasValidTag(wire, association: associations.inbound) {
                        validTagWithDifferentSPI += 1
                    } else { invalidTags += 1 }
                } catch DPPacketError.invalidTag {
                    invalidTags += 1
                } catch DPPacketError.invalidPacket {
                    invalidFrames += 1
                } catch let DPPacketError.invalidTrailer(nextHeader, paddingLength) {
                    invalidFrames += 1
                    trailers.insert("\(nextHeader)/\(paddingLength)")
                }
            }
        }
        throw DPUdpError.noMatchingReply("datagrams: \(received), decoded: \(validated), other SPI but valid tag: \(validTagWithDifferentSPI), invalid tag: \(invalidTags), invalid frame: \(invalidFrames), sync ACK: \(acknowledgements), lengths: \(lengths.sorted()), trailers: \(trailers.sorted())")
    }

    func sendPacket(_ packet: Data, association: DPAssociation) throws {
        guard sequence < UInt32.max else { throw DPPacketError.invalidAssociation }
        let wire = try DPPacketCodec.seal(packet, sequence: sequence, association: association)
        try send(wire)
        sequence += 1
    }

    func receivePacket(association: DPAssociation) throws -> Data? {
        guard let wire = try receive(before: DispatchTime.now().uptimeNanoseconds + 100_000_000),
              let decoded = try? DPPacketCodec.open(wire, association: association),
              replayWindow.accept(decoded.sequence) else { return nil }
        return decoded.packet
    }

    private func send(_ data: Data) throws {
        let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw count < 0 ? Self.lastError() : POSIXError(.EIO) }
    }

    private func receive(before deadline: UInt64) throws -> Data? {
        var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        var bytes = Data(count: Int(UInt16.max))
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            let milliseconds = Int32((deadline - now + 999_999) / 1_000_000)
            let result = poll(&state, 1, milliseconds)
            if result == 0 { return nil }
            if result < 0 {
                if errno == EINTR { continue }
                throw Self.lastError()
            }
            let count = bytes.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.lastError()
            }
            return Data(bytes.prefix(count))
        }
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
