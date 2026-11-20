import Foundation
import Network

enum DPTCPError: LocalizedError {
    case invalidRequest
    case invalidFrame
    case unexpectedResponse
    case closed
    case timeout(acknowledged: Bool, responseFrames: Int, receivedBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid DP transport request."
        case .invalidFrame: return "The gateway returned invalid DP transport framing."
        case .unexpectedResponse: return "The gateway did not acknowledge the TCP tunnel keepalive."
        case .closed: return "The gateway closed the TCP tunnel."
        case let .timeout(acknowledged, responseFrames, receivedBytes):
            return "DP TCP tunnel probe timed out (keepalive ack: \(acknowledged), subsequent frames: \(responseFrames), TLS bytes: \(receivedBytes))." 
        }
    }
}

struct DPTCPFrame {
    let header: String
    let body: Data
}

struct DPTCPFrameDecoder {
    private static let delimiter = Data([13, 10, 13, 10])
    private static let maxHeader = 16 * 1024
    private static let maxBody = Int(UInt16.max)
    private var pending = Data()

    mutating func receive(_ bytes: Data) throws -> [DPTCPFrame] {
        guard bytes.count <= Self.maxHeader + Self.maxBody else { throw DPTCPError.invalidFrame }
        pending.append(bytes)
        var frames: [DPTCPFrame] = []
        while let marker = pending.range(of: Self.delimiter) {
            guard pending.distance(from: pending.startIndex, to: marker.lowerBound) <= Self.maxHeader,
                  let header = String(data: pending[..<marker.lowerBound], encoding: .ascii) else {
                throw DPTCPError.invalidFrame
            }
            let lines = header.components(separatedBy: "\r\n")
            guard let status = lines.first, status.hasPrefix("HTTP/1.1 ") || status.hasPrefix("HTTP/1.0 ") else {
                throw DPTCPError.invalidFrame
            }
            let contentLengths = lines.dropFirst().compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":"),
                      line[..<colon].lowercased() == "content-length" else { return nil }
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard !lines.dropFirst().contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }),
                  contentLengths.count <= 1 else { throw DPTCPError.invalidFrame }
            let size: Int
            if let length = contentLengths.first {
                guard let value = Int(length), value >= 0, value <= Self.maxBody else {
                    throw DPTCPError.invalidFrame
                }
                size = value
            } else {
                guard header.contains("TCP_TUNNEL_KEEP_ALIVE_RESP") else { throw DPTCPError.invalidFrame }
                size = 0
            }
            guard pending.distance(from: marker.upperBound, to: pending.endIndex) >= size else { break }
            let end = pending.index(marker.upperBound, offsetBy: size)
            frames.append(DPTCPFrame(header: header, body: Data(pending[marker.upperBound..<end])))
            pending.removeSubrange(..<end)
        }
        if pending.count > Self.maxHeader && pending.range(of: Self.delimiter) == nil {
            throw DPTCPError.invalidFrame
        }
        return frames
    }
}

enum DPTCPRequest {
    static func keepalive(host: String, cookie: String) throws -> Data {
        try make(method: "GET", path: "/sslvpn/action/TCPTunnelKeepAlive", host: host, cookie: cookie, body: Data())
    }

    static func packet(_ packet: Data, host: String, cookie: String) throws -> Data {
        guard packet.count >= 20, packet.count <= Int(UInt16.max), packet.first.map({ $0 >> 4 }) == 4 else {
            throw DPTCPError.invalidRequest
        }
        return try make(method: "POST", path: "/SSLVPN_CLIENT_TCP_DATA", host: host, cookie: cookie, body: packet)
    }

    private static func make(method: String, path: String, host: String, cookie: String, body: Data) throws -> Data {
        guard !host.isEmpty, !cookie.isEmpty,
              host.utf8.allSatisfy({ (33...126).contains($0) }),
              cookie.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw DPTCPError.invalidRequest
        }
        let headers = [
            "\(method) \(path) HTTP/1.1",
            "Accept-Language: zh-CN",
            "User-Agent: ComLineLinux",
            "Content-Type: application/x-www-form-urlencoded",
            "Host: \(host)",
            "Cookie:\(cookie)",
            "Content-length: \(body.count)"
        ]
        var frame = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        frame.append(body)
        return frame
    }
}

// Connection state and all mutable fields are confined to queue.
final class DPTCPKeepaliveProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "local.dp-native.tcp-keepalive")
    private var result: CheckedContinuation<Void, Error>?
    private var decoder = DPTCPFrameDecoder()
    private var sent = false
    private var started = false
    private var nextRequest: Data?
    private var packetMatcher: (@Sendable (Data) -> Bool)?
    private var acknowledged = false
    private var responseFrames = 0
    private var receivedBytes = 0

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw DPTCPError.invalidRequest }
        let tls = NWProtocolTLS.Options()
        host.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                  using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
    }

    func run(request: Data, packetRequest: Data? = nil,
             packetMatcher: (@Sendable (Data) -> Bool)? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.started else { continuation.resume(throwing: DPTCPError.invalidRequest); return }
                self.started = true
                self.nextRequest = packetRequest
                self.packetMatcher = packetMatcher
                self.result = continuation
                self.connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready where !self.sent:
                        self.sent = true
                        self.connection.send(content: request, completion: .contentProcessed { error in
                            if let error { self.finish(.failure(error)) }
                            else { self.receive() }
                        })
                    case .failed(let error): self.finish(.failure(error))
                    case .cancelled: self.finish(.failure(DPTCPError.closed))
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 9) { [weak self] in
                    guard let self else { return }
                    self.finish(.failure(DPTCPError.timeout(acknowledged: self.acknowledged,
                        responseFrames: self.responseFrames, receivedBytes: self.receivedBytes)))
                }
            }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self, self.result != nil else { return }
            do {
                if let error { throw error }
                self.receivedBytes += data?.count ?? 0
                for frame in try self.decoder.receive(data ?? Data()) {
                    if !self.acknowledged {
                        guard frame.header.contains("TCP_TUNNEL_KEEP_ALIVE_RESP") else {
                            throw DPTCPError.unexpectedResponse
                        }
                        self.acknowledged = true
                        guard let packet = self.nextRequest else {
                            self.finish(.success(()))
                            return
                        }
                        self.connection.send(content: packet, completion: .contentProcessed { error in
                            if let error { self.finish(.failure(error)) }
                            else { self.receive() }
                        })
                        return
                    }
                    self.responseFrames += 1
                    if frame.header.contains("SSLVPN_IP_DATA"), self.packetMatcher?(frame.body) == true {
                        self.finish(.success(()))
                        return
                    }
                }
                guard !complete else { throw DPTCPError.closed }
                self.receive()
            } catch { self.finish(.failure(error)) }
        }
    }

    private func finish(_ value: Result<Void, Error>) {
        guard let continuation = result else { return }
        result = nil
        connection.cancel()
        continuation.resume(with: value)
    }
}
