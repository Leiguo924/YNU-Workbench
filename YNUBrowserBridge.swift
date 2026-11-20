import AppKit
import Foundation
import Darwin
import CFNetwork

enum YNUBrowserBridge {
    static let coursework = URL(string: "https://ehall.ynu.edu.cn/new/index.html")!
    static let portal = URL(string: "https://selfsrv.ynu.edu.cn/")!
    static let portalIP = URL(string: "http://202.203.208.5/")!

    enum Browser: String, CaseIterable {
        case edge = "Microsoft Edge"
        case safari = "Safari"
        case chrome = "Google Chrome"

        var bundleID: String {
            switch self {
            case .edge: return "com.microsoft.edgemac"
            case .safari: return "com.apple.Safari"
            case .chrome: return "com.google.Chrome"
            }
        }
    }

    enum Kind { case courses, devices }

    static func openLinkedPage(_ url: URL, browser: Browser = preferredBrowser, activates: Bool = true) {
        let workspace = NSWorkspace.shared
        if let app = workspace.urlForApplication(withBundleIdentifier: browser.bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = activates
            workspace.open([url], withApplicationAt: app, configuration: config, completionHandler: nil)
        } else {
            workspace.open(url)
        }
    }

    static func courseImportURL(_ text: String) -> URL? {
        guard let info = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              info.scheme == "https", info.host?.lowercased() == coursework.host,
              info.user == nil, info.password == nil, info.port == nil || info.port == 443 else { return nil }
        return info.url
    }

    static var selectedCourseImportURL: URL {
        let value = UserDefaults.standard.string(forKey: "teacherScheduleURL") ?? ""
        return courseImportURL(value) ?? coursework
    }

    static var preferredBrowser: Browser {
        Browser(rawValue: UserDefaults.standard.string(forKey: "browserChoice") ?? "") ?? .safari
    }

    enum ReadError: LocalizedError, Equatable {
        case browserClosed, noSchoolPage, automationUnavailable, javaScriptUnavailable, unsupportedFormat, pageReadFailed(Int)
        var errorDescription: String? {
            switch self {
            case .browserClosed: return "请先打开设置中选择的浏览器。"
            case .noSchoolPage: return "请先登录学校网站并打开目标页面。"
            case .automationUnavailable: return "macOS 尚未允许工作台读取浏览器。请检查「隐私与安全性 → 自动化」。"
            case .javaScriptUnavailable: return "浏览器关闭了网页读取。可在工作台设置中选择 Safari，或在当前浏览器允许来自 Apple 事件的 JavaScript。"
            case .unsupportedFormat: return "页面打开了，但还没看到可识别的课表或带 IP 的在线设备表。"
            case .pageReadFailed(let code): return "浏览器没有返回网页内容（Apple 事件 \(code)）。请选中学校网页后重试。"
            }
        }
    }

    static func readDevicesOverHTTP() async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0
        ]
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config, delegate: PortalRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: portalIP)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 2_000_000, let html = String(data: data, encoding: .utf8),
              let payload = devicePayload(fromHTML: html), !devices(in: payload).isEmpty else {
            throw ReadError.unsupportedFormat
        }
        return payload
    }

    private final class PortalRedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.host == YNUBrowserBridge.portalIP.host ? request : nil)
        }
    }

    @MainActor
    static func read(_ kind: Kind, browser: Browser) async throws -> String {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty else {
            throw ReadError.browserClosed
        }
        return try await Task.detached(priority: .utility) { try readInBrowser(kind, browser: browser) }.value
    }

    private static func readInBrowser(_ kind: Kind, browser: Browser, preferNativeText: Bool = true) throws -> String {
        let expressions: [String]
        let script: String
        switch kind {
        case .courses:
            expressions = ["https://ehall.ynu.edu.cn/"]
            script = #"""
            (()=>{if(location.origin!=='https://ehall.ynu.edu.cn')return '';const docs=[document];for(const frame of document.querySelectorAll('iframe')){try{if(frame.contentDocument)docs.push(frame.contentDocument)}catch{}}const pattern=/(?:本|研)\s*([^,\n]+?)\s*([0-9][0-9,\-周]*)周\s*[,，]\s*星期([1-7])\s*[,，]\s*(\d+)\s*[-–]\s*(\d+)节\s*[,，]\s*([^\n]+)/g;const out=[];for(const doc of docs){for(const title of doc.querySelectorAll('.mtt_item_kcmc')){ const details=title.nextElementSibling; const name=(title.textContent||'').replace(/^(?:本|研)\s*/,'').trim(); if(name&&details?.matches('.mtt_item_room'))out.push('本 '+name+' '+details.textContent.trim()); }if(out.length)continue;const cells=[...doc.querySelectorAll('table td')];for(const node of cells.length?cells:[doc.body]){const input=(node?.innerText||'').replace(/\u00a0/g,' ').replace(/\n(?=[0-9][0-9,\-周]*周\s*[,，])/g,' ');for(const m of input.matchAll(pattern))out.push('本 '+m[1].trim()+' '+m[2]+'周,星期'+m[3]+','+m[4]+'-'+m[5]+'节,'+m[6].trim())}}return [...new Set(out)].join('\n').slice(0,90000)})()
            """#
        case .devices:
            expressions = ["https://selfsrv.ynu.edu.cn/", "http://202.203.208.5/", "https://202.203.208.5/"]
            script = #"""
            (()=>{if(!['https://selfsrv.ynu.edu.cn','http://202.203.208.5','https://202.203.208.5'].includes(location.origin))return '';const root=[...document.querySelectorAll('table')].find(t=>/(?:^|\s)IP\s*地址/i.test(t.querySelector('tr')?.innerText||''))||document;const rows=[...root.querySelectorAll('tr,[role=row]')].filter(r=>r.getClientRects().length).map(r=>[...r.querySelectorAll('th,td,[role=cell],[role=columnheader]')].map(c=>c.innerText.trim()));const ip=r=>r.findIndex(c=>/^(?:(?:用户|登录|终端|设备)?ip(?:v4)?(?:地址)?|地址)$/i.test(c.replace(/\s/g,'')));const at=rows.findIndex(r=>ip(r)>=0);if(at<0)return '';const header=rows[at],column=ip(header),since=header.findIndex(c=>c.replace(/\s/g,'')==='上线时间'),name=header.findIndex(c=>/^(终端名称|设备名称|设备|终端|名称|主机名)$/.test(c));const data=rows.slice(at+1).filter(r=>r.length===header.length&&/^(?:\d{1,3}\.){3}\d{1,3}$/.test(r[column])).slice(0,300).map(r=>[name<0?'':r[name].slice(0,72),r[column],since<0?'':r[since].replace(/\s+/g,' ').slice(0,40)]);return data.length?'YNU-DEVICES/1\n'+JSON.stringify([['设备名称','IP地址','上线时间'],...data]):''})()
            """#
        }

        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let conditions = expressions.map { "pageURL starts with \(quote($0))" }.joined(separator: " or ")
        let readOperation = browser == .safari
            ? "do JavaScript \(quote(script)) in targetTab"
            : "execute (contents of targetTab) javascript \(quote(script))"
        let nativeText: String
        if preferNativeText && browser == .safari && kind == .courses {
            nativeText = """
                                try
                                    set nativePage to text of targetTab
                                    if nativePage contains "星期" and nativePage contains "节" then return "YNU:TEXT:" & nativePage
                                end try
            """
        } else if preferNativeText && browser == .safari {
            nativeText = """
                                try
                                    set nativePage to source of targetTab
                                    if nativePage contains "在线信息" and nativePage contains "IP地址" then return "YNU:HTML:" & nativePage
                                end try
            """
        } else {
            nativeText = ""
        }
        let source = """
        with timeout of 8 seconds
            tell application id "\(browser.bundleID)"
                set foundSchoolPage to false
                set lastReadError to 0
                repeat with browserWindow in windows
                    repeat with targetTab in tabs of browserWindow
                        set pageURL to URL of targetTab
                        if pageURL is not missing value and (\(conditions)) then
                            set foundSchoolPage to true
        \(nativeText)
                            try
                                set pageValue to \(readOperation)
                                if pageValue is not missing value and pageValue is not "" then return pageValue
                            on error number errorNumber
                                set lastReadError to errorNumber
                            end try
                        end if
                    end repeat
                end repeat
                if lastReadError is not 0 then return "YNU:ERROR:" & lastReadError
                if foundSchoolPage then return "YNU:NO_DATA"
                return "YNU:NO_PAGE"
            end tell
        end timeout
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if result.contains("-1743") || result.contains("-1744") { throw ReadError.automationUnavailable }
            throw ReadError.unsupportedFormat
        }
        if result.hasPrefix("YNU:HTML:") {
            let text = String(result.dropFirst("YNU:HTML:".count))
            if let payload = devicePayload(fromHTML: text), !devices(in: payload).isEmpty { return payload }
            return try readInBrowser(kind, browser: browser, preferNativeText: false)
        }
        if result.hasPrefix("YNU:TEXT:") {
            let text = String(result.dropFirst("YNU:TEXT:".count))
            if !parseCourses(text).isEmpty { return text }
            return try readInBrowser(kind, browser: browser, preferNativeText: false)
        }
        if result.hasPrefix("YNU:ERROR:") {
            let number = Int(result.dropFirst("YNU:ERROR:".count)) ?? 0
            if number == -1743 || number == -1744 { throw ReadError.automationUnavailable }
            if number == 12 || number == -2700 { throw ReadError.javaScriptUnavailable }
            throw ReadError.pageReadFailed(number)
        }
        if result == "YNU:NO_PAGE" { throw ReadError.noSchoolPage }
        if result == "YNU:NO_DATA" || result.isEmpty { throw ReadError.unsupportedFormat }
        return result
    }

    struct Device: Codable, Identifiable, Hashable {
        let address: String
        let name: String
        let onlineSince: String?
        var id: String { address }
    }

    static func routeAddresses(for input: String) async throws -> [String] {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address = privateAddress(cleaned) { return [address] }
        let rawURL = cleaned.contains("://") ? cleaned : "https://" + cleaned
        guard let parts = URLComponents(string: rawURL),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil,
              let host = parts.host?.lowercased() else { throw RouteInputError.invalid }
        if DPCampusPolicy.portalDestinations.contains(host) || host == portal.host {
            throw RouteInputError.builtIn
        }
        if let address = privateAddress(host) { return [address] }
        guard host.hasSuffix(".ynu.edu.cn") else { throw RouteInputError.invalid }
        return try await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            var head: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &head) == 0, let head else {
                throw RouteInputError.noPrivateAddress
            }
            defer { freeaddrinfo(head) }
            var cursor: UnsafeMutablePointer<addrinfo>? = head
            var found: [String] = []
            while let info = cursor {
                defer { cursor = info.pointee.ai_next }
                guard let address = info.pointee.ai_addr else { continue }
                var value = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, info.pointee.ai_addrlen, &value, socklen_t(value.count),
                                  nil, 0, NI_NUMERICHOST) == 0,
                      let privateIP = privateAddress(String(cString: value)),
                      !found.contains(privateIP) else { continue }
                found.append(privateIP)
            }
            guard !found.isEmpty else { throw RouteInputError.noPrivateAddress }
            return found.sorted()
        }.value
    }

    enum RouteInputError: LocalizedError {
        case invalid, builtIn, noPrivateAddress
        var errorDescription: String? {
            switch self {
            case .invalid: return "请输入校园 10.x 地址或 ynu.edu.cn 下的学校网址。"
            case .builtIn: return "校园网入口已由内置门户分流处理。"
            case .noPrivateAddress: return "当前没有解析到可添加的校园 10.x 地址。可以直接输入校内 IP。"
            }
        }
    }

    static func privateAddress(_ input: String) -> String? {
        guard let address = ipv4Address(input), address.hasPrefix("10.") else { return nil }
        return address
    }

    private static func ipv4Address(_ input: String) -> String? {
        let pieces = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        let octets = pieces.compactMap { UInt8($0) }
        guard pieces.count == 4, octets.count == 4 else { return nil }
        return octets.map(String.init).joined(separator: ".")
    }

    static func devicePayload(fromHTML html: String) -> String? {
        guard html.utf8.count < 2_000_000 else { return nil }
        func captures(_ pattern: String, _ text: String) -> [String] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        let tables = captures(#"<table\b[^>]*>(.*?)</table\s*>"#, html)
        for portion in tables.isEmpty ? [html] : tables {
            let rows = captures(#"<tr\b[^>]*>(.*?)</tr\s*>"#, portion).map { row in
                captures(#"<t[hd]\b[^>]*>(.*?)</t[hd]\s*>"#, row).map {
                    $0.replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: .regularExpression)
                        .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: "&nbsp;", with: " ")
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            guard let payload = sanitizedDevicePayload(rows), !devices(in: payload).isEmpty else { continue }
            return payload
        }
        return nil
    }

    static func devicePayload(fromTabularText text: String) -> String? {
        let rows = text.split(whereSeparator: \.isNewline).map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        return sanitizedDevicePayload(rows)
    }

    private static func sanitizedDevicePayload(_ rows: [[String]]) -> String? {
        let headerIndex = rows.firstIndex { $0.contains { ipHeadings.contains(normalizedHeading($0)) } }
        guard let headerIndex else { return nil }
        let header = rows[headerIndex].map(normalizedHeading)
        guard let ip = header.firstIndex(where: { ipHeadings.contains($0) }) else { return nil }
        let name = header.firstIndex { nameHeadings.contains($0) }
        let online = header.firstIndex(of: "上线时间")
        let sanitized = rows.dropFirst(headerIndex + 1).prefix(300).compactMap { row -> [String]? in
            guard row.indices.contains(ip), let address = ipv4Address(row[ip]) else { return nil }
            func value(_ index: Int?) -> String {
                index.flatMap { row.indices.contains($0) ? String(row[$0].prefix(72)) : nil } ?? ""
            }
            return [value(name), address, value(online)]
        }
        guard !sanitized.isEmpty,
              let data = try? JSONEncoder().encode([["设备名称", "IP地址", "上线时间"]] + sanitized) else { return nil }
        return "YNU-DEVICES/1\n" + String(decoding: data, as: UTF8.self)
    }

    private static let ipHeadings: Set<String> = ["ip", "ip地址", "ipv4", "地址", "ipv4地址", "用户ip", "用户ip地址", "登录ip", "登录ip地址", "终端ip", "终端ip地址", "设备ip", "设备ip地址"]
    private static let nameHeadings: Set<String> = ["终端名称", "设备名称", "设备", "终端", "名称", "主机名"]

    private static func normalizedHeading(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }

    static func devices(in text: String) -> [Device] {
        let prefix = "YNU-DEVICES/1\n"
        guard text.hasPrefix(prefix), text.utf8.count < 200_000,
              let rows = try? JSONDecoder().decode([[String]].self, from: Data(text.dropFirst(prefix.count).utf8)) else {
            return []
        }
        var entries: [String: Device] = [:]
        var addressColumn: Int?
        var deviceColumn: Int?
        var dateColumn: Int?
        for row in rows {
            let headers = row.map(normalizedHeading)
            if let column = headers.firstIndex(where: { ipHeadings.contains($0) }) {
                addressColumn = column
                deviceColumn = headers.firstIndex { nameHeadings.contains($0) }
                dateColumn = headers.firstIndex(of: "上线时间")
                continue
            }
            guard let addressColumn, row.indices.contains(addressColumn),
                  let address = ipv4Address(row[addressColumn]) else { continue }
            let name = deviceColumn.flatMap { row.indices.contains($0) ? row[$0] : nil } ?? ""
            let date = dateColumn.flatMap { row.indices.contains($0) && !row[$0].isEmpty ? String(row[$0].prefix(40)) : nil }
            entries[address] = Device(address: address, name: String(name.prefix(72)), onlineSince: date)
        }
        return entries.values.sorted { $0.address < $1.address }
    }
}
