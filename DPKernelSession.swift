import Darwin
import Foundation
import Network

enum DPKernelError: LocalizedError {
    case noAuthorizedRoutes
    case sessionExpired
    case keepaliveFailed(String)
    case dataPlaneUnavailable
    case sessionEnded
    case networkUnavailable
    case routeMismatch(destination: String, expected: String, actual: String?)
    case noHelper

    var errorDescription: String? {
        switch self {
        case .noAuthorizedRoutes: return "学校网关没有授权本客户端配置的校内目标。"
        case .sessionExpired: return "学校网关已结束当前 VPN 会话，请重新连接。"
        case .keepaliveFailed(let message): return "多次检查不到 VPN 连接，已断开。\(message)"
        case .dataPlaneUnavailable: return "连续三次没有收到校内回复，且隧道近期没有回包。"
        case .sessionEnded: return "虚拟网卡或 UDP 套接字已关闭。"
        case .networkUnavailable: return "本机网络已断开。"
        case .routeMismatch(let destination, let expected, let actual):
            return "\(destination) 的系统路由使用 \(actual ?? "无接口")，预期为 \(expected)。请检查其他 VPN 或 Clash 的分流。"
        case .noHelper: return "未安装校园 VPN 路由组件。"
        }
    }
}

enum DPTunnelHealth: Sendable, Equatable {
    case checking
    case responsive(Int, viaHTTP: Bool)
    case trafficObserved
    case noResponse
    case noTarget
    case reconnecting(Int, String)
    case connectingAgain
    case stopping

    var status: String {
        switch self {
        case .checking: return "正在验证隧道"
        case .responsive, .trafficObserved: return "已连接"
        case .noResponse: return "校内无响应"
        case .noTarget: return "隧道未验证"
        case .reconnecting: return "等待自动重连"
        case .connectingAgain: return "正在重连"
        case .stopping: return "正在断开"
        }
    }

    var detail: String? {
        switch self {
        case .responsive(let milliseconds, let viaHTTP):
            return "\(viaHTTP ? "校内 HTTP 响应" : "校内设备 Ping") \(milliseconds) ms"
        case .noResponse: return "校内探测未收到回复。系统会继续检查。"
        case .noTarget: return "当前分流没有可探测的校内服务。"
        case .trafficObserved: return "隧道有回包，未测得延迟。"
        case .reconnecting(let delay, let reason): return "\(delay) 秒后重试。\(reason)"
        default: return nil
        }
    }

    var shortStatus: String {
        if case .responsive(let milliseconds, _) = self { return "\(status) · \(milliseconds) ms" }
        return status
    }

    var isVerified: Bool {
        switch self {
        case .responsive, .trafficObserved: return true
        default: return false
        }
    }
}

private final class DPTunnelStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    private var lastReply: ContinuousClock.Instant?

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

    func recordReply() {
        lock.lock()
        lastReply = ContinuousClock.now
        lock.unlock()
    }

    var hasRecentReply: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastReply.map { ContinuousClock.now - $0 < .seconds(8) } ?? false
    }
}

enum DPReconnectPolicy {
    static func delay(afterFailures failures: Int) -> Int {
        let delays = [2, 5, 15, 30, 60, 120]
        return delays[min(failures, delays.count - 1)]
    }

    static func canRetry(_ error: Error) -> Bool {
        if let error = error as? DPControlError {
            switch error {
            case .invalidSession, .unauthorizedHost, .invalidUsername, .invalidGateway: return false
            case .unexpectedStatus(let code): return code == 408 || (500..<600).contains(code)
            default: return true
            }
        }
        if let error = error as? DPKernelError {
            switch error {
            case .noHelper, .noAuthorizedRoutes: return false
            default: return true
            }
        }
        return true
    }
}

enum DPNetworkAvailability {
    static func updates() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "local.ynu.workbench.network-path"))
        }
    }

    static func waitUntilAvailable() async throws {
        for await available in updates() where available {
            try Task.checkCancellation()
            return
        }
        throw CancellationError()
    }
}

enum DPKernelSession {
    static let origin = URL(string: "https://vpn.ynu.edu.cn")!
    static let helperSocket = "/var/run/ynu-native-vpn.sock"

    static func run(
        username: String, password: String, broad: Bool = false, extraHosts: [String] = [], replaceExisting: Bool = false, confirmedDuplicate: Bool = false, includePortal: Bool = false, retryKeepalive: Bool = true,
        health: @escaping @MainActor @Sendable (DPTunnelHealth) -> Void = { _ in },
        ready: @escaping @MainActor @Sendable (String, [String]) -> Void
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
            let routedHosts = Array(Set(extraHosts + portal + broadProbes)).sorted()
            try checkRoutes(routedHosts, interface: tunnel.name)
            let pingHost = extraHosts.first { address in
                guard let probe = try? DPIcmpProbe(source: settings.virtualAddress, destination: address) else { return false }
                return policy.allows(probe.packet, inbound: false)
            }
            await ready(tunnel.name, (policy.routeMask & 4 != 0 ? DPCampusPolicy.campusNetworks : []) + policy.extraHosts + portal)
            let stop = DPTunnelStop()
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try pump(tunnel, transport: transport, associations: associations, policy: policy, stop: stop)
                    }
                    group.addTask {
                        for await available in DPNetworkAvailability.updates() where !available {
                            throw DPKernelError.networkUnavailable
                        }
                    }
                    group.addTask {
                        try await checkSession(gateway, session: session, expectedAddress: settings.virtualAddress,
                                               retry: retryKeepalive)
                    }
                    group.addTask {
                        var missedProbes = 0
                        var verifiedByProbe = false
                        while !Task.isCancelled {
                            let nextProbe = ContinuousClock.now + .seconds(5)
                            try checkRoutes(routedHosts, interface: tunnel.name)
                            var measurement = await probeTunnel(interface: tunnel.name, portal: policy.permitsPortalHTTP,
                                                                pingHost: pingHost)
                            try Task.checkCancellation()
                            if measurement.isVerified {
                                verifiedByProbe = true
                            } else if stop.hasRecentReply {
                                measurement = .trafficObserved
                            }
                            missedProbes = measurement == .noResponse ? missedProbes + 1 : 0
                            await health(measurement)
                            if verifiedByProbe, missedProbes >= 3 { throw DPKernelError.dataPlaneUnavailable }
                            try await Task.sleep(until: nextProbe, clock: .continuous)
                        }
                    }
                    defer { stop.stop(); group.cancelAll() }
                    _ = try await group.next()
                }
            } onCancel: {
                stop.stop()
            }
        } catch {
            await health(.stopping)
            let cleanup = Task.detached { try? await gateway.endSession(session, timeout: 2) }
            _ = await cleanup.value
            throw error
        }
        try await gateway.endSession(session)
    }

    private static func checkSession(_ gateway: DPControl, session: DPSession,
                                     expectedAddress: String, retry: Bool) async throws {
        var failuresSince: ContinuousClock.Instant?
        var rejectedChecks = 0
        var delay = Duration.seconds(15)
        while !Task.isCancelled {
            do {
                async let heartbeat: Void = gateway.keepalive(session)
                let current = try await gateway.tunnelConfiguration(session: session)
                guard current.virtualAddress == expectedAddress else { throw DPKernelError.sessionExpired }
                try await heartbeat
                failuresSince = nil
                rejectedChecks = 0
                delay = .seconds(15)
            } catch {
                try Task.checkCancellation()
                if let issue = error as? DPKernelError { throw issue }
                if !retry { throw error }
                if case DPControlError.unexpectedStatus(let status) = error, [401, 403].contains(status) {
                    rejectedChecks += 1
                    if rejectedChecks >= 2 { throw DPKernelError.sessionExpired }
                } else {
                    rejectedChecks = 0
                }
                let now = ContinuousClock.now
                let first = failuresSince ?? now
                guard now - first < .seconds(30) else { throw DPKernelError.keepaliveFailed(error.localizedDescription) }
                failuresSince = first
                delay = .seconds(4)
            }
            try await Task.sleep(for: delay)
        }
    }

    private static func checkRoutes(_ hosts: [String], interface: String) throws {
        for destination in hosts {
            let actual = routeInterface(to: destination)
            guard actual == interface else {
                throw DPKernelError.routeMismatch(destination: destination, expected: interface, actual: actual)
            }
        }
        let gateway = "113.55.10.4"
        if routeInterface(to: gateway) == interface {
            throw DPKernelError.routeMismatch(destination: gateway, expected: "校外网络接口", actual: interface)
        }
    }

    private static func probeTunnel(interface: String, portal: Bool, pingHost: String?) async -> DPTunnelHealth {
        if portal, let milliseconds = await NetworkReport.probeCampus(interface: interface, timeout: 3).milliseconds {
            return .responsive(milliseconds, viaHTTP: true)
        }
        if let pingHost, !Task.isCancelled, let milliseconds = await NetworkReport.pingCampus(pingHost, interface: interface) {
            return .responsive(milliseconds, viaHTTP: false)
        }
        return portal || pingHost != nil ? .noResponse : .noTarget
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
                stop.recordReply()
            }
        }
    }

    static func routeInterface(to host: String) -> String? {
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
