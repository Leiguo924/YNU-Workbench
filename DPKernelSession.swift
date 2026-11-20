import Darwin
import Foundation

enum DPKernelError: LocalizedError {
    case noAuthorizedRoutes
    case sessionEnded
    case routeMismatch(destination: String, expected: String, actual: String?)
    case noHelper

    var errorDescription: String? {
        switch self {
        case .noAuthorizedRoutes: return "学校网关没有授权本客户端配置的校内目标。"
        case .sessionEnded: return "虚拟网卡或 UDP 套接字已关闭。"
        case .routeMismatch(let destination, let expected, let actual):
            return "网关已接受登录，但 \(destination) 的系统路由是 \(actual ?? "无路由")，预期使用 \(expected)。"
        case .noHelper: return "未安装校园 VPN 路由组件。"
        }
    }
}

private final class DPTunnelStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false

    var requested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }
}

enum DPKernelSession {
    static let origin = URL(string: "https://vpn.ynu.edu.cn")!
    static let helperSocket = "/var/run/ynu-native-vpn.sock"

    static func run(
        username: String, password: String, broad: Bool = false, extraHosts: [String] = [], replaceExisting: Bool = false, confirmedDuplicate: Bool = false, includePortal: Bool = false,
        ready: @escaping @Sendable (String, [String]) -> Void
    ) async throws {
        guard FileManager.default.fileExists(atPath: helperSocket) else { throw DPKernelError.noHelper }
        let gateway = try DPControl(origin: origin)
        let session = try await gateway.authenticate(username: username, password: password, replaceExisting: replaceExisting, confirmedDuplicate: confirmedDuplicate)
        do {
            try Task.checkCancellation()
            let settings = try await gateway.tunnelConfiguration(session: session)
            let transport = try DPUdpTransport.synchronize(address: "113.55.10.4",
                                                           request: session.udpSynchronization())
            let associations = try await gateway.udpAssociations(session: session)
            let policy = try await gateway.campusPolicy(session: session, virtualAddress: settings.virtualAddress, broad: broad, extraHosts: extraHosts, includePortal: includePortal)
            guard policy.routeMask != 0 || !policy.extraHosts.isEmpty else { throw DPKernelError.noAuthorizedRoutes }
            try Task.checkCancellation()
            let tunnel = try DPVirtualInterface(address: settings.virtualAddress, routes: policy.routeMask, hosts: policy.extraHosts)
            if ProcessInfo.processInfo.environment["YNU_SHOW_NETWORKS"] == "1" {
                print("DP_ADVERTISED_NETWORKS", policy.advertisedNetworks.joined(separator: ", "))
            }
            let portal = policy.routeMask & 8 == 0 ? [] : DPCampusPolicy.portalDestinations
            let broadProbes = policy.routeMask & 4 != 0 ? ["10.111.176.1", "10.141.176.1"] : []
            for destination in policy.extraHosts + portal + broadProbes {
                let actual = routeInterface(to: destination)
                guard actual == tunnel.name else {
                    throw DPKernelError.routeMismatch(destination: destination, expected: tunnel.name, actual: actual)
                }
            }
            let gatewayAddress = "113.55.10.4"
            if routeInterface(to: gatewayAddress) == tunnel.name {
                throw DPKernelError.routeMismatch(destination: gatewayAddress, expected: "校外网络接口", actual: tunnel.name)
            }
            ready(tunnel.name, (policy.routeMask & 4 != 0 ? DPCampusPolicy.campusNetworks : []) + policy.extraHosts + portal)
            let stop = DPTunnelStop()
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try pump(tunnel, transport: transport, associations: associations, policy: policy, stop: stop)
                    }
                    group.addTask {
                        var consecutiveFailures = 0
                        while !Task.isCancelled {
                            try await Task.sleep(nanoseconds: 15_000_000_000)
                            do {
                                try await gateway.keepalive(session)
                                consecutiveFailures = 0
                            } catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                                consecutiveFailures += 1
                                if consecutiveFailures >= 3 { throw error }
                            }
                        }
                    }
                    defer { stop.stop(); group.cancelAll() }
                    _ = try await group.next()
                }
            } onCancel: {
                stop.stop()
            }
        } catch {
            let cleanup = Task.detached { try? await gateway.endSession(session) }
            _ = await cleanup.value
            throw error
        }
        try await gateway.endSession(session)
    }

    private static func pump(
        _ tunnel: DPVirtualInterface, transport: DPUdpTransport,
        associations: DPUdpAssociations, policy: DPCampusPolicy, stop: DPTunnelStop
    ) throws {
        var descriptors = [
            pollfd(fd: tunnel.descriptor, events: Int16(POLLIN), revents: 0),
            pollfd(fd: transport.descriptor, events: Int16(POLLIN), revents: 0)
        ]
        while !stop.requested {
            let count = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 500) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, !descriptors.contains(where: {
                $0.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0
            }) else { throw DPKernelError.sessionEnded }
            if descriptors[0].revents & Int16(POLLIN) != 0,
               let packet = try tunnel.readIPv4(), policy.allows(packet, inbound: false) {
                try transport.sendPacket(packet, association: associations.outbound)
            }
            if descriptors[1].revents & Int16(POLLIN) != 0,
               let packet = try transport.receivePacket(association: associations.inbound),
               policy.allows(packet, inbound: true) {
                try tunnel.writeIPv4(packet)
            }
        }
    }

    private static func routeInterface(to host: String) -> String? {
        let pipe = Pipe()
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/sbin/route")
        command.arguments = ["-n", "get", host]
        command.standardOutput = pipe
        command.standardError = FileHandle.nullDevice
        guard (try? command.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { return nil }
        return output.split(separator: "\n").lazy.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first {
            $0.hasPrefix("interface:")
        }.map { String($0.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces) }
    }
}
