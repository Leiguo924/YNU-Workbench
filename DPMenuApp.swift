import AppKit
import Security
import SwiftUI

private enum Page: String, CaseIterable {
    case courses = "课程表"
    case todos = "待办事项"
    case vpn = "VPN"

    var title: String { self == .vpn ? "校内资源" : rawValue }

    var symbol: String {
        switch self {
        case .courses: return "calendar"
        case .todos: return "checklist"
        case .vpn: return "building.columns"
        }
    }
}

private enum WorkbenchAppearance: String, CaseIterable {
    case system = "跟随系统"
    case light = "日间"
    case dark = "夜间"

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum WorkbenchTheme: String, CaseIterable {
    case ocean = "深海蓝"
    case jade = "松石绿"
    case indigo = "鸢尾紫"
    case rust = "暖陶红"

    var tint: Color {
        switch self {
        case .ocean: return Color(red: 0.20, green: 0.49, blue: 0.82)
        case .jade: return .teal
        case .indigo: return .indigo
        case .rust: return Color(red: 0.74, green: 0.36, blue: 0.26)
        }
    }

    var banner: [Color] {
        switch self {
        case .ocean: return [Color(red: 0.12, green: 0.25, blue: 0.50), Color(red: 0.12, green: 0.43, blue: 0.62)]
        case .jade: return [Color(red: 0.09, green: 0.30, blue: 0.34), Color(red: 0.12, green: 0.44, blue: 0.42)]
        case .indigo: return [Color(red: 0.23, green: 0.22, blue: 0.47), Color(red: 0.40, green: 0.32, blue: 0.60)]
        case .rust: return [Color(red: 0.48, green: 0.24, blue: 0.23), Color(red: 0.65, green: 0.35, blue: 0.25)]
        }
    }
}
private enum VPNKeychain {
    static let service = "local.ynu.workbench.vpn"

    static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var attributes = query(account: account)
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ secret: String, account: String) -> OSStatus {
        let attributes = query(account: account)
        let value = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(attributes as CFDictionary, value as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(attributes.merging(value) { _, new in new } as CFDictionary, nil)
    }

    static func remove(account: String) -> OSStatus {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

@MainActor
private final class Workbench: ObservableObject {
    static let gateway = "https://vpn.ynu.edu.cn"
    let schedule = Schedule()
    @Published var page: Page = .courses
    @Published var server = gateway
    @Published var appearance = WorkbenchAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            appearance.apply()
        }
    }
    @Published var extraHosts = UserDefaults.standard.stringArray(forKey: "vpnExtraHosts") ?? []
    @Published var account = UserDefaults.standard.string(forKey: "vpnAccount") ?? ""
    @Published var password = ""
    @Published var remember = UserDefaults.standard.bool(forKey: "rememberVPN")
    @Published var broad = UserDefaults.standard.object(forKey: "broadVPN") as? Bool ?? true
    @Published var state = "未连接"
    @Published var routes: [String] = []
    @Published var devices: [YNUBrowserBridge.Device] = {
        guard let data = UserDefaults.standard.data(forKey: "lastOnlineDevices") else { return [] }
        return (try? JSONDecoder().decode([YNUBrowserBridge.Device].self, from: data)) ?? []
    }()
    @Published var deviceMessage = ""
    @Published var importing = false
    @Published var automaticImport = UserDefaults.standard.bool(forKey: "automaticPageImport") {
        didSet { UserDefaults.standard.set(automaticImport, forKey: "automaticPageImport") }
    }
    private var refreshing = false
    private var campusSync: Task<Void, Never>?
    private var campusSyncGeneration: UUID?
    private var pendingCourses = false
    private var pendingDevices = false
    @Published var syncOnConnect = UserDefaults.standard.object(forKey: "syncCampusOnVPN") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncOnConnect, forKey: "syncCampusOnVPN") }
    }
    @Published var includePortal = UserDefaults.standard.object(forKey: "includeCampusPortal") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includePortal, forKey: "includeCampusPortal") }
    }
    @Published var browser = YNUBrowserBridge.preferredBrowser {
        didSet { UserDefaults.standard.set(browser.rawValue, forKey: "browserChoice") }
    }
    @Published var error: String?
    @Published var takeoverAvailable = false
    @Published var canCheckOldSession = false
    @Published var busy = false
    private var worker: Task<Void, Never>?
    var changed: (() -> Void)?
    var quitting = false

    func connect(replaceExisting: Bool = false) {
        guard worker == nil else { return }
        let confirmedDuplicate = takeoverAvailable
        takeoverAvailable = false
        canCheckOldSession = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        let endpoint = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard [Self.gateway, Self.gateway + "/", "vpn.ynu.edu.cn", Self.gateway + ":443"].contains(endpoint) else {
            error = "请输入云大 VPN 地址 vpn.ynu.edu.cn。"
            return
        }
        guard FileManager.default.fileExists(atPath: DPKernelSession.helperSocket) else {
            error = DPKernelError.noHelper.localizedDescription
            return
        }
        let username = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let usedSavedPassword = password.isEmpty && remember
        let secret = usedSavedPassword ? VPNKeychain.read(account: username) ?? "" : password
        guard !username.isEmpty, !secret.isEmpty else { error = "请输入账号和密码。"; return }
        let shouldRemember = remember
        let useBroadRoutes = broad
        let selectedHosts = extraHosts
        let routePortal = includePortal
        let previousAccount = UserDefaults.standard.string(forKey: "vpnAccount")
        let anotherWorkbenchIsRunning = Bundle.main.bundleIdentifier.map { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        } ?? false
        error = nil
        busy = true
        let connectingState = replaceExisting ? "正在接管并连接" : "正在连接"
        state = connectingState
        changed?()
        worker = Task.detached { [weak self] in
            var failure: String?
            var duplicateSession = false
            var canCheck = false
            do {
                try await DPKernelSession.run(username: username, password: secret, broad: useBroadRoutes, extraHosts: selectedHosts, replaceExisting: replaceExisting, confirmedDuplicate: confirmedDuplicate, includePortal: routePortal) { [weak self] _, hosts in
                    Task { @MainActor [weak self] in
                        guard let self, self.worker?.isCancelled == false, self.state == connectingState else { return }
                        let defaults = UserDefaults.standard
                        defaults.set(username, forKey: "vpnAccount")
                        defaults.set(shouldRemember, forKey: "rememberVPN")
                        defaults.set(useBroadRoutes, forKey: "broadVPN")
                        if let previousAccount, previousAccount != username {
                            _ = VPNKeychain.remove(account: previousAccount)
                        }
                        let result = shouldRemember ? VPNKeychain.save(secret, account: username) : VPNKeychain.remove(account: username)
                        if result != errSecSuccess { self.error = "无法更新钥匙串中的 VPN 密码（\(result)）。" }
                        self.password = ""
                        self.routes = hosts
                        self.state = "已连接"
                        self.changed?()
                        self.startCampusSync()
                    }
                }
            } catch DPControlError.invalidSession(let rejection) {
                if !Task.isCancelled {
                    duplicateSession = rejection.reason == .duplicate
                    canCheck = duplicateSession || rejection.reason == .authentication || rejection.reason == .unknown
                    failure = rejection.message
                    if usedSavedPassword && rejection.reason != .duplicate && rejection.reason != .locked {
                        failure = rejection.message + " 可以重新输入密码，覆盖钥匙串中的旧值。"
                    }
                    if replaceExisting && (confirmedDuplicate || duplicateSession), let detail = failure {
                        failure = "网关未完成旧会话接管。\(detail)"
                    }
                }
            } catch let issue as DPKernelError {
                if !Task.isCancelled {
                    failure = issue.localizedDescription
                    if case .routeMismatch = issue, anotherWorkbenchIsRunning {
                        failure = issue.localizedDescription + " 检测到另一个工作台实例正在运行。请断开旧版工作台的 VPN 后重试。"
                    }
                }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            await self?.finished(failure, duplicateSession: duplicateSession, canCheck: canCheck)
        }
    }

    func startCampusSync(onLaunch: Bool = false) {
        guard syncOnConnect else { return }
        let previous = campusSync
        previous?.cancel()
        let generation = UUID()
        campusSyncGeneration = generation
        pendingCourses = true
        pendingDevices = true
        campusSync = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            defer {
                if self.campusSyncGeneration == generation { self.campusSync = nil }
            }
            self.schedule.status = onLaunch ? "正在同步课表。" : "VPN 已连接，正在同步课表。"
            self.deviceMessage = "正在同步在线设备…"
            await self.syncCampusPages(includeCourses: true, canOpen: true)
        }
    }

    func refreshSelectedPages() {
        let retryCourses = syncOnConnect && pendingCourses
        let retryDevices = syncOnConnect && pendingDevices
        guard automaticImport || retryCourses || retryDevices,
              !refreshing, !importing, campusSync == nil else { return }
        Task { await syncCampusPages(includeCourses: retryCourses, canOpen: false) }
    }

    private func syncCampusPages(includeCourses: Bool, canOpen: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if includeCourses {
            do {
                let text = try await readConnectedPage(.courses, canOpen: canOpen)
                guard !Task.isCancelled else { return }
                if schedule.importBrowserText(text) { pendingCourses = false }
                else { schedule.status = YNUBrowserBridge.ReadError.unsupportedFormat.localizedDescription }
            } catch {
                guard !Task.isCancelled else { return }
                schedule.status = error.localizedDescription
            }
        }
        guard !Task.isCancelled else { return }
        do { try await updateDeviceList(canOpen: canOpen) }
        catch let error as YNUBrowserBridge.ReadError
            where error == .automationUnavailable || error == .javaScriptUnavailable {
            deviceMessage = error.localizedDescription
        } catch {
            deviceMessage = devices.isEmpty ? error.localizedDescription : "显示上次同步。\(error.localizedDescription)"
        }
    }

    private func readConnectedPage(_ kind: YNUBrowserBridge.Kind, canOpen: Bool) async throws -> String {
        do {
            return try await YNUBrowserBridge.read(kind, browser: browser)
        } catch let error as YNUBrowserBridge.ReadError {
            guard canOpen, error == .noSchoolPage || error == .browserClosed else { throw error }
        }
        let address = kind == .courses ? YNUBrowserBridge.selectedCourseImportURL : YNUBrowserBridge.portalIP
        try Task.checkCancellation()
        YNUBrowserBridge.openLinkedPage(address, browser: browser, activates: false)
        for attempt in 0..<4 {
            try await Task.sleep(for: .seconds(2))
            do { return try await YNUBrowserBridge.read(kind, browser: browser) }
            catch let error as YNUBrowserBridge.ReadError where attempt < 3 &&
                (error == .noSchoolPage || error == .browserClosed || error == .unsupportedFormat) {}
        }
        throw YNUBrowserBridge.ReadError.unsupportedFormat
    }

    private func updateDeviceList(canOpen: Bool = false) async throws {
        let text: String
        if let direct = try? await YNUBrowserBridge.readDevicesOverHTTP() {
            text = direct
        } else {
            text = try await readConnectedPage(.devices, canOpen: canOpen)
        }
        guard !Task.isCancelled else { return }
        let imported = YNUBrowserBridge.devices(in: text)
        guard !imported.isEmpty else { throw YNUBrowserBridge.ReadError.unsupportedFormat }
        devices = imported
        if let saved = try? JSONEncoder().encode(imported) {
            UserDefaults.standard.set(saved, forKey: "lastOnlineDevices")
        }
        pendingDevices = false
        deviceMessage = "已同步 \(devices.count) 台设备"
    }

    func importDevices() {
        guard !importing, !refreshing else { return }
        importing = true
        Task {
            defer { importing = false }
            do { try await updateDeviceList() }
            catch { deviceMessage = error.localizedDescription }
        }
    }
    func pasteDeviceTable() {
        let clipboard = NSPasteboard.general
        let html = clipboard.data(forType: .html).map { String(decoding: $0, as: UTF8.self) }
        let plain = clipboard.string(forType: .string) ?? ""
        let payload = html.flatMap(YNUBrowserBridge.devicePayload(fromHTML:))
            ?? YNUBrowserBridge.devicePayload(fromTabularText: plain)
        let imported = payload.map(YNUBrowserBridge.devices(in:)) ?? []
        guard !imported.isEmpty else {
            deviceMessage = "剪贴板里没有可识别的在线信息表。请在学校页面选中带 IP 地址表头的表格并复制。"
            return
        }
        devices = imported
        if let saved = try? JSONEncoder().encode(imported) {
            UserDefaults.standard.set(saved, forKey: "lastOnlineDevices")
        }
        pendingDevices = false
        deviceMessage = "已导入 \(devices.count) 台在线设备"
    }

    func addHost(_ value: String) -> Bool {
        guard let address = YNUBrowserBridge.privateAddress(value),
              extraHosts.count < 8, !extraHosts.contains(address) else { return false }
        extraHosts.append(address)
        UserDefaults.standard.set(extraHosts, forKey: "vpnExtraHosts")
        return true
    }

    func removeHost(_ address: String) {
        extraHosts.removeAll { $0 == address }
        UserDefaults.standard.set(extraHosts, forKey: "vpnExtraHosts")
    }

    func forgetPassword() {
        let saved = UserDefaults.standard.string(forKey: "vpnAccount") ?? account
        let status = VPNKeychain.remove(account: saved)
        if status == errSecSuccess {
            UserDefaults.standard.set(false, forKey: "rememberVPN")
        } else {
            error = "无法从钥匙串移除 VPN 密码（\(status)）。"
        }
    }

    func disconnect() {
        campusSync?.cancel()
        campusSync = nil
        campusSyncGeneration = nil
        guard let worker, !worker.isCancelled else { return }
        state = "正在断开"
        changed?()
        worker.cancel()
    }

    private func finished(_ failure: String?, duplicateSession: Bool = false, canCheck: Bool = false) {
        takeoverAvailable = duplicateSession
        canCheckOldSession = canCheck
        worker = nil
        busy = false
        state = failure == nil ? "未连接" : "连接失败"
        routes = []
        if let failure { error = failure }
        changed?()
        if quitting { NSApp.terminate(nil) }
    }
}

private struct WorkbenchView: View {
    @ObservedObject var app: Workbench
    @ObservedObject var schedule: Schedule
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings = false
    @State private var addRoute = false
    @State private var routeInput = ""
    @State private var resolvingRoute = false
    @State private var routeMessage = ""
    @State private var routeProblem: String?
    @State private var settingsSection = "通用"
    @AppStorage("startPage") private var startPage = "课程表"
    @AppStorage("teacherScheduleURL") private var teacherScheduleURL = ""
    @AppStorage("showUpcoming") private var showUpcoming = true
    @AppStorage("showDatedTasks") private var showDatedTasks = true
    @AppStorage("coloredBanner") private var coloredBanner = true
    @AppStorage("workbenchTheme") private var themeName = WorkbenchTheme.ocean.rawValue
    private var theme: WorkbenchTheme { WorkbenchTheme(rawValue: themeName) ?? .ocean }
    @State private var confirmReplacement = false
    @State private var host = ""
    @State private var hostError = false
    @State private var termSettings = false
    @State private var termMonday = Date()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch app.page {
                case .courses:
                    CampusWeek(schedule: schedule)
                case .todos:
                    VStack(alignment: .leading, spacing: 18) {
                        Text("待办事项").font(.system(size: 29, weight: .semibold))
                        TodoView(model: schedule)
                    }.frame(maxWidth: 890).padding(22).frame(maxWidth: .infinity, alignment: .center)
                case .vpn:
                    vpn
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            tabs
                .overlay(alignment: .leading) {
                    Button {
                        app.appearance = colorScheme == .dark ? .light : .dark
                    } label: {
                        Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 36, height: 36)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(colorScheme == .dark ? "切换日间模式" : "切换夜间模式")
                        .help(colorScheme == .dark ? "切换日间模式" : "切换夜间模式")
                        .padding(.leading, 16)
                }
                .overlay(alignment: .trailing) {
                    Button { settings = true } label: {
                        Image(systemName: "gearshape").font(.system(size: 16, weight: .semibold))
                            .frame(width: 36, height: 36)
                    }.buttonStyle(.plain).accessibilityLabel("工作台设置").help("工作台设置")
                        .padding(.trailing, 16)
                }
        }
        .frame(minWidth: 735, minHeight: 510)
        .background {
            ZStack {
                VisualEffectSurface()
                LinearGradient(colors: [theme.tint.opacity(0.18), theme.tint.opacity(0.05), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }.ignoresSafeArea()
        }
        .sheet(isPresented: $settings) { settingsPage }
        .sheet(isPresented: $addRoute) { addRoutePage }
        .confirmationDialog("接管这个账号的 VPN 会话？", isPresented: $confirmReplacement) {
            Button("剔除旧会话并连接", role: .destructive) { app.connect(replaceExisting: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只有学校网关明确报告此账号已有会话时，才会请网关下线旧连接。")
        }
        .tint(theme.tint)
        .font(.system(size: 15))
        .controlSize(.large)
        .sheet(isPresented: $schedule.showTodo) { TodoEditor(model: schedule) }
        .sheet(isPresented: $schedule.showImport) { ImportView(model: schedule) }
        .sheet(isPresented: $schedule.showServices) { CampusLinksView(model: schedule) }
        .sheet(isPresented: $termSettings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("学期设置").font(.title2.bold())
                DatePicker("第一周周一", selection: $termMonday, displayedComponents: .date)
                HStack {
                    Button("导出日历") { exportCalendar(schedule) }
                    Spacer()
                    Button("完成") {
                        schedule.firstMonday = termMonday
                        UserDefaults.standard.set(schedule.firstMonday, forKey: "firstMonday")
                        schedule.goToday()
                        termSettings = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(Calendar.current.component(.weekday, from: termMonday) != 2)
                }
            }.padding(22).frame(width: 380)
        }
        .sheet(item: $schedule.editing) { CourseDetail(model: schedule, meeting: $0) }
        .sheet(item: $schedule.adjustTarget) { AdjustmentView(model: schedule, meeting: $0) }
        .sheet(item: $schedule.noteTarget) { CourseNoteView(model: schedule, course: $0) }
        .sheet(item: $schedule.editingManual) { ManualCourseView(model: schedule, existing: $0) }
        .sheet(isPresented: $schedule.showManual) { ManualCourseView(model: schedule) }
        .sheet(isPresented: $schedule.showGroup) { GroupView(model: schedule) }
        .sheet(isPresented: $schedule.showAdjustments) { AdjustmentList(model: schedule) }
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(Page.allCases, id: \.self) { page in
                Button { app.page = page } label: {
                    VStack(spacing: 4) {
                        Image(systemName: page.symbol).font(.system(size: 16, weight: .medium))
                        Text(page.title).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(app.page == page ? Color.teal : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background {
                        if app.page == page {
                            RoundedRectangle(cornerRadius: 10).fill(theme.tint.opacity(0.16))
                        }
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(app.page == page ? .isSelected : [])
            }
        }
        .frame(width: 322)
        .padding(4)
        .modifier(WorkbenchGlass(radius: 18))
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("工作台设置", systemImage: "gearshape").font(.system(size: 25, weight: .semibold))
                .foregroundStyle(theme.tint)
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 6) {
                    ForEach([("通用", "slider.horizontal.3"), ("课程", "calendar"),
                             ("网络", "network"), ("导入", "arrow.down.to.line")], id: \.0) { item in
                        Button { settingsSection = item.0 } label: {
                            Label(item.0, systemImage: item.1).font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                .background(theme.tint.opacity(settingsSection == item.0 ? 0.20 : 0),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(settingsSection == item.0 ? .isSelected : [])
                    }
                }.frame(width: 108)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        Text(settingsSection).font(.system(size: 20, weight: .semibold))
                        switch settingsSection {
                        case "网络":
                            Toggle("分流校园子网", isOn: $app.broad)
                                .onChange(of: app.broad) { UserDefaults.standard.set($0, forKey: "broadVPN") }
                            Toggle("校园认证门户走 VPN", isOn: $app.includePortal)
                            Text("网络设置在下次连接时生效。").foregroundStyle(.secondary)
                            Text("额外设备").font(.headline)
                            HStack {
                                TextField("10.x.x.x", text: $host)
                                Button("添加") {
                                    hostError = !app.addHost(host)
                                    if !hostError { host = "" }
                                }.disabled(app.extraHosts.count >= 8)
                            }
                            if hostError { Text("请输入未添加的校园 10.x IPv4 地址。").foregroundStyle(.red) }
                            ForEach(app.extraHosts, id: \.self) { address in
                                HStack {
                                    Text(address).monospaced()
                                    Spacer()
                                    Button("移除") { app.removeHost(address) }
                                }
                            }
                        case "课程":
                            HStack {
                                Text("学期起始").font(.headline)
                                Text(schedule.firstMonday, format: .dateTime.year().month().day())
                                Spacer()
                                Button("调整") {
                                    settings = false
                                    termMonday = schedule.firstMonday
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { termSettings = true }
                                }
                            }
                            Toggle("显示下一堂课横幅", isOn: $showUpcoming)
                            Toggle("显示带日期的待办", isOn: $showDatedTasks)
                            HStack {
                                Button("管理调课") {
                                    settings = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { schedule.showAdjustments = true }
                                }
                                Button("导出日历") { exportCalendar(schedule) }
                            }
                        case "导入":
                            Picker("读取网页的浏览器", selection: $app.browser) {
                                ForEach(YNUBrowserBridge.Browser.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Toggle("打开工作台或连接 VPN 时自动同步", isOn: $app.syncOnConnect)
                            TextField("教师课表网址（可选）", text: $teacherScheduleURL)
                            if !teacherScheduleURL.isEmpty && YNUBrowserBridge.courseImportURL(teacherScheduleURL) == nil {
                                Text("请输入 https://ehall.ynu.edu.cn 下的课表地址。").foregroundStyle(.red)
                            }
                            Toggle("每 30 秒后台刷新已打开的在线设备页", isOn: $app.automaticImport)
                            Text("工作台只读取已打开的云大教务和自助服务页。首次使用需要由你在浏览器允许来自 Apple 事件的 JavaScript，并同意 macOS 的自动化授权。")
                                .foregroundStyle(.secondary)
                        default:
                            Picker("外观", selection: $app.appearance) {
                                ForEach(WorkbenchAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented)
                            Picker("启动页面", selection: $startPage) {
                                ForEach(Page.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                            }
                            Picker("主题色", selection: $themeName) {
                                ForEach(WorkbenchTheme.allCases, id: \.rawValue) { option in
                                    Label(option.rawValue, systemImage: "circle.fill")
                                        .foregroundStyle(option.tint).tag(option.rawValue)
                                }
                            }
                            Toggle("显示彩色横幅", isOn: $coloredBanner)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(17)
                }.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
            }
            HStack { Spacer(); Button("完成") { settings = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(23).frame(width: 620, height: 435)
    }

    private var routingCard: some View {
        let visible = app.routes.filter { !DPCampusPolicy.portalDestinations.contains($0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("校园分流", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { routeInput = ""; routeProblem = nil; addRoute = true } label: {
                    Label("添加路由", systemImage: "plus")
                }
            }
            if !visible.isEmpty {
                Text(visible.joined(separator: "  ·  ")).font(.callout.monospaced()).textSelection(.enabled)
            } else if !app.extraHosts.isEmpty {
                Text(app.extraHosts.joined(separator: "  ·  ")).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            if !routeMessage.isEmpty { Text(routeMessage).font(.callout).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var addRoutePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加校园路由").font(.title2.bold())
            TextField("学校网址或 10.x IPv4 地址", text: $routeInput)
            if let routeProblem { Text(routeProblem).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { addRoute = false }
                Button(resolvingRoute ? "正在解析…" : "添加") {
                    resolvingRoute = true
                    routeProblem = nil
                    let request = routeInput
                    Task {
                        defer { resolvingRoute = false }
                        do {
                            let addresses = try await YNUBrowserBridge.routeAddresses(for: request)
                            let new = addresses.filter { !app.extraHosts.contains($0) }
                            guard !new.isEmpty else { routeProblem = "这些地址已经添加。"; return }
                            guard new.count + app.extraHosts.count <= 8 else { routeProblem = "最多可添加 8 个额外地址。"; return }
                            for address in new { _ = app.addHost(address) }
                            routeMessage = "已添加 \(new.joined(separator: "、"))，下次连接生效。"
                            addRoute = false
                        } catch { routeProblem = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(routeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvingRoute)
            }
        }.padding(23).frame(width: 445)
    }

    @State private var showVPNControls = false
    @State private var revealVPNPassword = false
    @State private var revealedSavedPassword = ""

    private func hideVPNPassword() {
        revealVPNPassword = false
        revealedSavedPassword = ""
    }

    private var vpn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("校内资源").font(.system(size: 29, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                linksCard
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showVPNControls.toggle() }
                    } label: {
                        HStack {
                            Label("校园 VPN", systemImage: "lock.shield").font(.system(size: 17, weight: .semibold))
                            Spacer()
                            Text(app.state).foregroundStyle(.secondary)
                            Image(systemName: showVPNControls ? "chevron.up" : "chevron.down").foregroundStyle(theme.tint)
                        }.padding(.vertical, 5).frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityValue(showVPNControls ? "已展开" : "已折叠")
                    if showVPNControls {
                        VStack(spacing: 14) {
                            if app.busy {
                                vpnStatus.padding(20).modifier(WorkbenchGlass(radius: 20))
                            } else {
                                VStack(spacing: 19) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "lock.shield").foregroundStyle(theme.tint)
                                        Text("连接校园 VPN").fontWeight(.semibold)
                                    }.font(.system(size: 22))
                                    vpnCredentials
                                }
                                .frame(maxWidth: .infinity)
                                .padding(22).modifier(WorkbenchGlass(radius: 20))
                            }
                            routingCard
                        }.padding(.top, 12)
                    }
                }
                .padding(16).modifier(WorkbenchGlass(radius: 16))
                devicesCard
            }
            .onAppear { showVPNControls = app.busy || app.error != nil }
            .frame(maxWidth: 890, alignment: .leading).frame(maxWidth: .infinity)
            .padding(22)
        }
    }
    private var vpnStatus: some View {
        HStack(alignment: .center, spacing: 15) {
            Image(systemName: app.routes.isEmpty ? "lock.shield" : "checkmark.shield.fill")
                .font(.system(size: 28, weight: .medium)).foregroundStyle(theme.tint)
                .frame(width: 54, height: 54)
                .background(theme.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 4) {
                Text("校园 VPN").font(.system(size: 30, weight: .semibold))
                Text(app.state).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            if app.busy {
                Button("断开") { app.disconnect() }
                    .disabled(app.state == "正在断开")
            }
        }
    }

    private var vpnCredentials: some View {
        VStack(alignment: .leading, spacing: 15) {
            loginField("服务器") {
                TextField("vpn.ynu.edu.cn", text: $app.server).accessibilityLabel("服务器 URL")
            }
            loginField("账号") {
                TextField("校园账号", text: $app.account).accessibilityLabel("账号")
                    .onChange(of: app.account) { _ in hideVPNPassword() }
            }
            loginField("密码") {
                HStack(spacing: 9) {
                    Group {
                        if revealVPNPassword {
                            TextField("密码", text: Binding(
                                get: { app.password.isEmpty ? revealedSavedPassword : app.password },
                                set: { revealedSavedPassword = ""; app.password = $0 }
                            )).accessibilityLabel("可见密码")
                        } else {
                            VPNPasswordField(placeholder: app.remember ? "留空使用已保存的密码" : "输入密码",
                                             secret: $app.password).frame(height: 34)
                        }
                    }
                    .frame(height: 34)
                    Button {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        if revealVPNPassword {
                            hideVPNPassword()
                        } else {
                            let account = app.account.trimmingCharacters(in: .whitespacesAndNewlines)
                            if app.password.isEmpty && app.remember {
                                revealedSavedPassword = VPNKeychain.read(account: account) ?? ""
                            }
                            revealVPNPassword = true
                        }
                    } label: {
                        Image(systemName: revealVPNPassword ? "eye.slash" : "eye").frame(width: 30, height: 34)
                    }.buttonStyle(.borderless)
                        .accessibilityLabel(revealVPNPassword ? "隐藏密码" : "显示密码")
                        .help(revealVPNPassword ? "隐藏密码" : "显示密码")
                    Button {
                        if let password = NSPasteboard.general.string(forType: .string), !password.isEmpty {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            hideVPNPassword()
                            app.password = password
                        }
                    } label: {
                        Image(systemName: "clipboard").frame(width: 25, height: 34)
                    }.buttonStyle(.borderless).accessibilityLabel("粘贴密码")
                }
            }
            HStack {
                Toggle("记住密码", isOn: $app.remember)
                    .onChange(of: app.remember) {
                        if !$0 { hideVPNPassword(); app.forgetPassword() }
                    }
                Spacer()
                Button("连接 VPN") { hideVPNPassword(); app.connect() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            if let error = app.error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if app.canCheckOldSession {
                    Button(app.takeoverAvailable ? "剔除旧会话并连接…" : "检查并接管旧会话…") {
                        hideVPNPassword()
                        confirmReplacement = true
                    }.buttonStyle(.borderless)
                }
            }
        }
        .font(.system(size: 16)).textFieldStyle(.plain)
        .frame(maxWidth: 470)
        .onDisappear(perform: hideVPNPassword)
    }

    private func loginField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
            content()
                .padding(.horizontal, 10).frame(minHeight: 39)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(theme.tint.opacity(0.15)).allowsHitTesting(false) }
        }
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("在线设备", systemImage: "desktopcomputer").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("打开校园认证") {
                    YNUBrowserBridge.openLinkedPage(YNUBrowserBridge.portalIP, browser: app.browser)
                }
                Button(app.importing ? "正在读取…" : "同步设备") { app.importDevices() }
                    .buttonStyle(.borderedProminent).disabled(app.importing)
            }
            HStack {
                Toggle("后台自动同步", isOn: $app.automaticImport)
                    .toggleStyle(.switch)
                    .onChange(of: app.automaticImport) { enabled in
                        if enabled { app.refreshSelectedPages() }
                    }
                Spacer()
                if !app.deviceMessage.isEmpty && app.devices.isEmpty {
                    Button("粘贴表格") { app.pasteDeviceTable() }.buttonStyle(.borderless)
                }
            }
            if !app.deviceMessage.isEmpty { Text(app.deviceMessage).foregroundStyle(.secondary) }
            ForEach(app.devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name.isEmpty ? device.address : device.name)
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                        if let time = device.onlineSince {
                            Text("上线 \(time)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !device.name.isEmpty { Text(device.address).monospaced().foregroundStyle(.secondary) }
                    Button(app.extraHosts.contains(device.address) ? "已添加" : "加入分流") {
                        if app.addHost(device.address) { app.deviceMessage = "下次连接时启用新增分流。" }
                    }.disabled(app.extraHosts.contains(device.address) || YNUBrowserBridge.privateAddress(device.address) == nil)
                }
            }
        }.padding(17).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var linksCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("常用链接", systemImage: "link").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("编辑") { schedule.showServices = true }.buttonStyle(.borderless)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 9)], alignment: .leading, spacing: 9) {
                ForEach(schedule.services) { link in
                    Button { schedule.openService(link) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: link.symbol)
                                .font(.system(size: 24, weight: .medium)).foregroundStyle(theme.tint)
                            Text(link.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(.plain)
                }
            }
        }.padding(17).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

}

private struct VPNPasswordField: NSViewRepresentable {
    let placeholder: String
    @Binding var secret: String

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var secret: Binding<String>
        init(_ secret: Binding<String>) { self.secret = secret }

        func controlTextDidBeginEditing(_ notification: Notification) {
            let field = notification.object as? NSSecureTextField
            field?.currentEditor()?.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSecureTextField else { return }
            secret.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSSecureTextField else { return }
            secret.wrappedValue = field.stringValue
            field.currentEditor()?.inputContext?.allowedInputSourceLocales = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator($secret) }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.isEditable = true
        field.font = .systemFont(ofSize: 16)
        field.controlSize = .large
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.setAccessibilityLabel("密码")
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.secret = $secret
        field.placeholderString = placeholder
        if field.stringValue != secret { field.stringValue = secret }
    }
}

struct WorkbenchGlass: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

private struct VisualEffectSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .contentBackground
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

@MainActor
final class DPMenuApp: NSObject, NSApplicationDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model = Workbench()
    private var window: NSWindow?
    private var statusLabel: NSMenuItem?
    private var importTimer: Timer?
    private var vpnAction: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.appearance.apply()
        model.startCampusSync(onLaunch: true)
        importTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.model.refreshSelectedPages() }
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let path = NSBezierPath()
            path.lineWidth = 1.35
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 9, y: 4))
            for point in [NSPoint(x: 6, y: 5), NSPoint(x: 2, y: 5), NSPoint(x: 2, y: 14),
                          NSPoint(x: 6, y: 14), NSPoint(x: 9, y: 13), NSPoint(x: 12, y: 14),
                          NSPoint(x: 16, y: 14), NSPoint(x: 16, y: 5), NSPoint(x: 12, y: 5),
                          NSPoint(x: 9, y: 4), NSPoint(x: 9, y: 13)] {
                path.line(to: point)
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "云大工作台"
        status.button?.image = image
        let menu = NSMenu()
        statusLabel = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add("打开云大工作台", #selector(openWorkbench), to: menu)
        vpnAction = add("连接 VPN…", #selector(toggleVPN), to: menu)
        menu.addItem(.separator())
        add("退出云大工作台", #selector(quit), to: menu).keyEquivalent = "q"
        status.menu = menu
        model.changed = { [weak self] in self?.updateMenu() }
        updateMenu()
        show(Page(rawValue: UserDefaults.standard.string(forKey: "startPage") ?? "") ?? .courses)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { return .terminateNow }
        model.quitting = true
        model.disconnect()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(model.page)
        return true
    }

    private func updateMenu() {
        statusLabel?.title = "VPN  \(model.state)"
        status.button?.toolTip = "云大工作台 · VPN \(model.state)"
        vpnAction?.title = model.busy ? "断开 VPN" : "连接 VPN…"
        status.button?.appearsDisabled = false
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func show(_ page: Page) {
        model.page = page
        if window == nil {
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 970, height: 630),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                     backing: .buffered, defer: false)
            newWindow.title = "云大工作台"
            newWindow.isReleasedWhenClosed = false
            newWindow.isOpaque = true
            newWindow.backgroundColor = .windowBackgroundColor
            newWindow.styleMask.insert(.fullSizeContentView)
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.contentView = NSHostingView(rootView: WorkbenchView(app: model, schedule: model.schedule))
            newWindow.contentMinSize = NSSize(width: 735, height: 510)
            newWindow.center()
            newWindow.setFrameAutosaveName("YNUWorkbenchMain")
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openWorkbench() { show(model.page) }
    @objc private func toggleVPN() { if model.busy { model.disconnect() } else { show(.vpn) } }
    @objc private func quit() {
        guard model.busy else { NSApp.terminate(nil); return }
        model.quitting = true
        model.disconnect()
    }
}

@main
struct DPMenuMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = DPMenuApp()
        app.delegate = delegate
        app.run()
    }
}
