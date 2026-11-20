import Darwin
import Foundation

final class DPVirtualInterface {
    let name: String
    let descriptor: Int32

    init() throws {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        let fd = dp_utun_open(&buffer, buffer.count)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        descriptor = fd
        name = String(cString: buffer)
    }

    init(address: String, routes: UInt8, hosts: [String] = []) throws {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        let capacity = buffer.count
        let fd = address.withCString { address in
            hosts.joined(separator: ",").withCString { extra in
                dp_helper_acquire_hosts(address, routes, extra, &buffer, capacity)
            }
        }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        descriptor = fd
        name = String(cString: buffer)
    }

    deinit { close(descriptor) }

    func readIPv4() throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: Int(UInt16.max) + 4)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard count >= 24, bytes[0...3].elementsEqual([0, 0, 0, UInt8(AF_INET)]) else { return nil }
        return Data(bytes[4..<count])
    }

    func writeIPv4(_ packet: Data) throws {
        guard packet.count >= 20, packet.count <= Int(UInt16.max),
              packet.first.map({ $0 >> 4 }) == 4 else { throw POSIXError(.EINVAL) }
        var frame = Data([0, 0, 0, UInt8(AF_INET)])
        frame.append(packet)
        let count = frame.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == frame.count else {
            throw POSIXError(count < 0 ? POSIXErrorCode(rawValue: errno) ?? .EIO : .EIO)
        }
    }
}
