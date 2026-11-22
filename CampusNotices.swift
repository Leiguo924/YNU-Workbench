import AppKit
import SwiftUI

enum CampusNoticeSource: String, CaseIterable, Sendable {
    case finance = "财务处"
    case technology = "信息技术中心"

    var page: URL {
        switch self {
        case .finance: return URL(string: "https://www.cwc.ynu.edu.cn/tzgg/zytz.htm")!
        case .technology: return URL(string: "https://itc.ynu.edu.cn/")!
        }
    }

    var noticePage: URL {
        self == .finance ? page : URL(string: "https://itc.ynu.edu.cn/xxgk/tzgg.htm")!
    }

    struct Notice: Identifiable, Sendable {
        let title: String
        let address: URL
        let date: String
        var id: URL { address }
    }

    func fetch() async -> [Notice]? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: page),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", http.url?.host == page.host,
              data.count < 1_000_000, let html = String(data: data, encoding: .utf8) else { return nil }
        let items = parse(html)
        return items.isEmpty ? nil : items
    }

    func parse(_ html: String) -> [Notice] {
        let list: String
        let pattern: String
        switch self {
        case .finance:
            list = html
            pattern = #"(?is)<a\b[^>]*href="([^"]*/info/1043/\d+\.htm)"[^>]*title="([^"]+)"[^>]*>\s*<div class="text-ldata">\s*<div>\s*<span>(\d{2})</span>\s*<p>(\d{4})-(\d{2})</p>"#
        case .technology:
            guard let heading = html.range(of: "<h5>通知公告</h5>"),
                  let end = html.range(of: "</ul>", range: heading.upperBound..<html.endIndex) else { return [] }
            list = String(html[heading.upperBound..<end.lowerBound])
            pattern = #"(?is)<a\b[^>]*href="([^"]*info/\d+/\d+\.htm)"[^>]*title="([^"]+)"[^>]*>\s*<div class="time">\s*<div class="day">(\d{2})-(\d{2})</div>\s*<div class="year">(\d{4})</div>"#
        }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let body = list as NSString
        var seen: Set<URL> = []
        return expression.matches(in: list, range: NSRange(location: 0, length: body.length)).compactMap { match -> Notice? in
            func field(_ index: Int) -> String { body.substring(with: match.range(at: index)) }
            guard let url = URL(string: field(1), relativeTo: page)?.absoluteURL,
                  url.scheme == "https", url.host == page.host, seen.insert(url).inserted else { return nil }
            let title = field(2).replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let date = self == .finance ? "\(field(4))-\(field(5))-\(field(3))"
                : "\(field(5))-\(field(3))-\(field(4))"
            return Notice(title: title, address: url, date: date)
        }.sorted { $0.date > $1.date }.prefix(5).map { $0 }
    }
}

struct CampusNoticesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CampusNoticeSource: [CampusNoticeSource.Notice]] = [:]
    @State private var refreshing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("校内通知").font(.system(size: 24, weight: .semibold)).foregroundStyle(WorkbenchPalette.ink)
                Spacer()
                if refreshing { ProgressView().controlSize(.small).accessibilityLabel("正在读取通知") }
                Button("刷新") { Task { await refresh() } }.disabled(refreshing)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(CampusNoticeSource.allCases, id: \.self) { source in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(source.rawValue).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Link("官网", destination: source.noticePage).font(.system(size: 13))
                            }
                            if let notices = items[source] {
                                ForEach(notices) { notice in
                                    Button { NSWorkspace.shared.open(notice.address) } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                                            Text(notice.title).font(.system(size: 14)).multilineTextAlignment(.leading)
                                            Spacer(minLength: 4)
                                            Text(notice.date).font(.system(size: 12).monospacedDigit())
                                                .foregroundStyle(WorkbenchPalette.muted).fixedSize()
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            } else if !refreshing {
                                Text("暂时读不到通知，可打开官网查看。").font(.subheadline)
                                    .foregroundStyle(WorkbenchPalette.muted)
                            }
                        }.padding(15).modifier(WorkbenchSurface())
                    }
                }
            }
        }.padding(20).frame(width: 610, height: 500)
            .background(WorkbenchPalette.canvas)
            .task { await refresh() }
    }

    @MainActor private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        async let finance = CampusNoticeSource.finance.fetch()
        async let technology = CampusNoticeSource.technology.fetch()
        let result = await (finance, technology)
        guard !Task.isCancelled else { return }
        items[.finance] = result.0
        items[.technology] = result.1
    }
}
