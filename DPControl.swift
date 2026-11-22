import Foundation

enum DPControlError: LocalizedError {
    case invalidGateway
    case invalidUsername
    case invalidHTTPResponse
    case unexpectedStatus(Int)
    case invalidSession(DPLoginRejection)
    case invalidPayload(String)
    case emptyVersion
    case unauthorizedHost(String)

    var errorDescription: String? {
        switch self {
        case .invalidGateway: return "The gateway must be an HTTPS origin."
        case .invalidUsername: return "The username contains unsupported characters."
        case .invalidHTTPResponse: return "The gateway returned an invalid response."
        case .unexpectedStatus(let status): return "The gateway returned HTTP \(status)."
        case .invalidSession(let result): return result.message
        case .unauthorizedHost(let host): return "学校网关未授权设备 \(host)。"
        case .invalidPayload(let phase): return "学校网关返回了无法识别的\(phase)响应。"
        case .emptyVersion: return "The gateway did not return a version."
        }
    }
}

struct DPLoginRejection {
    enum Reason: Equatable {
        case duplicate
        case locked
        case credential
        case authentication
        case unknown
    }

    let status: Int
    let reason: Reason
    let vendorCode: Int?

    init(status: Int, location: String?, body: Data, vendorCode: Int? = nil) {
        self.status = status
        self.vendorCode = vendorCode
        let query = location.flatMap { URLComponents(string: $0)?.queryItems } ?? []
        let html = String(decoding: body.prefix(32_768), as: UTF8.self)
        let pattern = #"(?i)\balert\(\s*["']([^"'<>]{1,180})["']\s*\)"#
        let match = html.range(of: pattern, options: .regularExpression).map { String(html[$0]).lowercased() } ?? ""
        if vendorCode == 22 || query.contains(where: { $0.name == "repeat_login" && $0.value == "1" }) ||
            ["重复登录", "已在线", "already logged in", "concurrent session"].contains(where: { match.contains($0) }) {
            reason = .duplicate
        } else if vendorCode == 8 || status == 429 || ["已锁定", "账户锁定", "account locked"].contains(where: { match.contains($0) }) {
            reason = .locked
        } else if vendorCode == 2 || vendorCode == 3 || status == 401 || ["用户名或密码错误", "密码错误", "invalid credentials"].contains(where: { match.contains($0) }) {
            reason = .credential
        } else if vendorCode == 25 {
            reason = .authentication
        } else {
            reason = .unknown
        }
    }

    var message: String {
        let detail: String
        switch reason {
        case .duplicate: detail = "网关报告重复登录。请通过学校门户检查当前会话。"
        case .locked: detail = "网关报告登录受限。请等待学校解除限制后再试。"
        case .credential: detail = "网关拒绝了这次认证。请核对校园网上网账号和密码。"
        case .authentication: detail = "迪普网关报告认证失败。请核对密码中的英文标点，或使用密码栏右侧的粘贴按钮。"
        case .unknown: detail = "网关没有发回 VPN 会话，也没有提供可识别的失败原因。"
        }
        let details = vendorCode.map { "HTTP \(status) · DP \($0)" } ?? "HTTP \(status)"
        return "\(detail)（\(details)）"
    }
}

struct DPVersion: Decodable {
    let ServerVersion: String
}

struct DPTunnelConfiguration: Decodable {
    let virtualAddress: String
    let subnetMask: String
    let gateway: String

    enum CodingKeys: String, CodingKey {
        case virtualAddress = "VirIP"
        case subnetMask = "VirMask"
        case gateway = "GateWay"
    }
}

struct DPLoginRequest {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func body(username: String, password: String) throws -> Data {
        guard !username.isEmpty,
              username.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                  (97...122).contains(byte) || [45, 46, 64, 95].contains(byte)
              }) else { throw DPControlError.invalidUsername }
        let encodedPassword = Data(password.utf8).base64EncodedString()
        let form = "u_name=\(username)&pawd=\(encodedPassword)&language=1&Submit=%E7%99%BB%E5%BD%95"
        guard let wireBody = form.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw DPControlError.invalidHTTPResponse
        }
        return Data(wireBody.utf8)
    }
}

struct DPSession {
    fileprivate let cookie: String

    var cookieHeader: String { "Dptech_SSLID=\(cookie)" }

    func udpSynchronization() throws -> Data {
        try DPUdpProtocol.synchronizationDatagram(sessionID: cookie)
    }
}

struct DPResourceMatch {
    let networks: Int
    let matchingNetworks: Int
    let policyFields: String
    let permitsSSH: Bool
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class DPControl: @unchecked Sendable {
    private static let cookieName = "Dptech_SSLID"
    private let origin: URL
    private let transport: URLSession

    init(origin: URL, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard let url = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              (url.path.isEmpty || url.path == "/"), url.query == nil, url.fragment == nil
        else { throw DPControlError.invalidGateway }
        self.origin = origin
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        self.transport = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private func request(_ path: String, session: DPSession? = nil) -> URLRequest {
        let url = URL(string: path.hasPrefix("/") ? path : "/\(path)", relativeTo: origin)!.absoluteURL
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue("ComLineLinux", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let session {
            request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url?.host == origin.host,
              response.url?.port == origin.port,
              response.url?.scheme == origin.scheme else {
            throw DPControlError.invalidHTTPResponse
        }
        return (data, response)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data, phase: String) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DPControlError.invalidPayload(phase) }
    }

    func version(session: DPSession? = nil) async throws -> String {
        let (data, response) = try await send(request("sslvpn/action/VPNVersion", session: session))
        guard response.statusCode == 200 else { throw DPControlError.unexpectedStatus(response.statusCode) }
        let version = try decode(DPVersion.self, from: data, phase: session == nil ? "版本查询" : "连接检查").ServerVersion
        guard !version.isEmpty else { throw DPControlError.emptyVersion }
        return version
    }

    func tunnelConfiguration(session: DPSession) async throws -> DPTunnelConfiguration {
        let (data, response) = try await send(request("sslvpn/action/TunnelInfo", session: session))
        guard response.statusCode == 200 else { throw DPControlError.unexpectedStatus(response.statusCode) }
        return try decode(DPTunnelConfiguration.self, from: data, phase: "隧道配置")
    }

    func udpAssociations(session: DPSession) async throws -> DPUdpAssociations {
        let (data, response) = try await send(request("sslvpn/action/SAInfo", session: session))
        guard response.statusCode == 200 else { throw DPControlError.unexpectedStatus(response.statusCode) }
        do { return try DPUdpAssociations(data: data) }
        catch { throw DPControlError.invalidPayload("隧道密钥配置") }
    }

    func endSession(_ session: DPSession) async throws {
        let (_, response) = try await send(request("sslvpn/SSLVPN_IP_EXIT", session: session))
        guard (200..<400).contains(response.statusCode) else {
            throw DPControlError.unexpectedStatus(response.statusCode)
        }
    }

    func keepalive(_ session: DPSession) async throws {
        _ = try await version(session: session)
    }

    func campusPolicy(session: DPSession, virtualAddress: String, broad: Bool = false, extraHosts: [String] = [], includePortal: Bool = false) async throws -> DPCampusPolicy {
        let (data, response) = try await send(request("sslvpn/action/UserResource", session: session))
        guard response.statusCode == 200 else { throw DPControlError.unexpectedStatus(response.statusCode) }
        do {
            return try DPCampusPolicy(data: data, virtualAddress: virtualAddress, broad: broad, extraHosts: extraHosts, includePortal: includePortal)
        } catch let error as DPControlError {
            if case .invalidHTTPResponse = error { throw DPControlError.invalidPayload("校园路由") }
            throw error
        } catch {
            throw DPControlError.invalidPayload("校园路由")
        }
    }

    func resourceSummary(session: DPSession, destination: String) async throws -> DPResourceMatch {
        let (data, response) = try await send(request("sslvpn/action/UserResource", session: session))
        guard response.statusCode == 200 else { throw DPControlError.unexpectedStatus(response.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DPControlError.invalidHTTPResponse
        }
        let target = try DPIcmpProbe.parseIPv4(destination)
        var networks = 0
        var matching = 0
        var policyFields = Set<String>()
        var permitsSSH = false
        func visit(_ value: Any) {
            if let entry = value as? [String: Any] {
                if let net = (entry["Net"] as? String)?.split(separator: ".").compactMap({ UInt8($0) }),
                   let mask = (entry["Mask"] as? String)?.split(separator: ".").compactMap({ UInt8($0) }),
                   net.count == 4, mask.count == 4 {
                    networks += 1
                    if (0..<4).allSatisfy({ net[$0] & mask[$0] == target[$0] & mask[$0] }) {
                        matching += 1
                        policyFields.formUnion(entry.keys.filter { ["access_contrl", "TCP", "UDP", "Protocol"].contains($0) })
                        let control = (entry["access_contrl"] as? NSNumber)?.intValue
                        let tcp = entry["TCP"] as? [String: Any]
                        let ranges = tcp?["Range"] as? [[String: Any]] ?? []
                        let matchesPort = ranges.contains { range in
                            guard let min = (range["Min"] as? NSNumber)?.intValue,
                                  let max = (range["Max"] as? NSNumber)?.intValue else { return false }
                            return min >= 0 && min <= 22 && max >= 22 && max <= 65535
                        }
                        permitsSSH = permitsSSH || control == 0 || (control == 1 && matchesPort)
                    }
                }
                entry.values.forEach(visit)
            } else if let entries = value as? [Any] {
                entries.forEach(visit)
            }
        }
        visit(object)
        return DPResourceMatch(networks: networks, matchingNetworks: matching,
            policyFields: policyFields.sorted().joined(separator: ","), permitsSSH: permitsSSH)
    }

    func authenticate(username: String, password: String, replaceExisting: Bool = false, confirmedDuplicate: Bool = false) async throws -> DPSession {
        let body = try DPLoginRequest.body(username: username, password: password)
        if replaceExisting && confirmedDuplicate {
            return try await postLogin(path: "/kick_other_user/", body: body)
        }
        do {
            return try await postLogin(path: "/", body: body)
        } catch DPControlError.invalidSession(let result) where replaceExisting && result.reason == .duplicate {
            return try await postLogin(path: "/kick_other_user/", body: body)
        }
    }

    private func postLogin(path: String, body: Data) async throws -> DPSession {
        var login = request(path)
        login.httpMethod = "POST"
        login.httpBody = body
        let (data, response) = try await send(login)
        let vendorCode = response.value(forHTTPHeaderField: "x-errcode").flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let rejection = DPLoginRejection(status: response.statusCode,
                                         location: response.value(forHTTPHeaderField: "Location"),
                                         body: data, vendorCode: vendorCode)
        if let vendorCode, vendorCode != 0 { throw DPControlError.invalidSession(rejection) }
        if [401, 403, 429].contains(response.statusCode) { throw DPControlError.invalidSession(rejection) }
        guard (200..<400).contains(response.statusCode) else {
            throw DPControlError.unexpectedStatus(response.statusCode)
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: origin).first {
            $0.name == Self.cookieName && !$0.value.isEmpty && $0.value.caseInsensitiveCompare("deleted") != .orderedSame
        }
        guard let cookie else { throw DPControlError.invalidSession(rejection) }
        return DPSession(cookie: cookie.value)
    }
}
