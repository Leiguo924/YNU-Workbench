import Foundation

struct NetworkReport: Sendable {
    private let downloadMegabits: Double?
    private let campusHTTP: Int?
    private let campusMilliseconds: Int?
    private let campusInterface: String?

    var shortResult: String {
        downloadMegabits.map { String(format: "外网 %.1f Mb/s", $0) } ?? "外网测速未完成"
    }

    var summary: String {
        let campus: String
        if let code = campusHTTP, let milliseconds = campusMilliseconds {
            campus = "校内响应 \(milliseconds) ms（HTTP \(code)）"
        } else {
            campus = "校内无响应"
        }
        return "\(shortResult)\n\(campus) · 接口 \(campusInterface ?? "未知")"
    }

    static func measure() async -> Self {
        async let download = measureDownload()
        async let campus = probeCampus()
        let (result, probe) = await (download, campus)
        return Self(downloadMegabits: result, campusHTTP: probe.code,
                    campusMilliseconds: probe.milliseconds, campusInterface: probe.route)
    }

    private static func measureDownload() async -> Double? {
        let sampleSize = 4_000_000
        let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(sampleSize)")!
        let session = downloadSession()
        defer { session.finishTasksAndInvalidate() }
        let clock = ContinuousClock()
        let begin = clock.now
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count == sampleSize else { return nil }
        let elapsed = (clock.now - begin).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        guard seconds > 0 else { return nil }
        return Double(data.count) * 8 / seconds / 1_000_000
    }

    static func probeCampus(interface: String? = nil, timeout: Int = 6) async -> (code: Int?, milliseconds: Int?, route: String?) {
        let url = YNUBrowserBridge.portalIP
        let route = DPKernelSession.routeInterface(to: url.host ?? "")
        if let interface, route != interface { return (nil, nil, route) }
        let probe = Process()
        let output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        let binding = interface.map { ["--interface", "if!" + $0] } ?? []
        probe.arguments = ["-q", "--noproxy", "*", "--silent", "--connect-timeout", "3",
                           "--max-time", String(timeout), "--output", "/dev/null",
                           "--write-out", "%{http_code} %{time_starttransfer}"] + binding + [url.absoluteString]
        probe.standardOutput = output
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return (nil, nil, route) }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let fields = String(decoding: result, as: UTF8.self).split(separator: " ")
        guard probe.terminationStatus == 0, fields.count == 2, let status = Int(fields[0]), (200..<600).contains(status),
              let seconds = Double(fields[1]), seconds.isFinite, (0...10).contains(seconds) else {
            return (nil, nil, route)
        }
        return (status, Int((seconds * 1_000).rounded()), route)
    }

    static func pingCampus(_ address: String, interface: String) async -> Int? {
        guard DPKernelSession.routeInterface(to: address) == interface else { return nil }
        let ping = Process()
        let output = Pipe()
        ping.executableURL = URL(fileURLWithPath: "/sbin/ping")
        ping.arguments = ["-n", "-c", "1", "-t", "2", "-W", "1800", "-b", interface, address]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        ping.environment = environment
        ping.standardOutput = output
        ping.standardError = FileHandle.nullDevice
        guard (try? ping.run()) != nil else { return nil }
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ping.waitUntilExit()
        guard ping.terminationStatus == 0, let marker = result.range(of: "time="),
              let value = result[marker.upperBound...].split(whereSeparator: \.isWhitespace).first,
              let milliseconds = Double(value), milliseconds.isFinite, (0...3_000).contains(milliseconds)
        else { return nil }
        return Int(milliseconds.rounded())
    }

    private static func downloadSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
