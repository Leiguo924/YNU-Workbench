import AppKit
import OSLog
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
        case .ocean: return WorkbenchPalette.adaptive(light: 0x2e5fb3, dark: 0x8bb4ff)
        case .jade: return WorkbenchPalette.adaptive(light: 0x177a73, dark: 0x6cc8b9)
        case .indigo: return WorkbenchPalette.adaptive(light: 0x5b4db3, dark: 0xb5a2ff)
        case .rust: return WorkbenchPalette.adaptive(light: 0xa04d3b, dark: 0xe5a38e)
        }
    }

    var bannerColors: [Color] {
        let shades: (UInt32, UInt32)
        switch self {
        case .ocean: shades = (0x244782, 0x2c5ca3)
        case .jade: shades = (0x145852, 0x206f64)
        case .indigo: shades = (0x443781, 0x5b499b)
        case .rust: shades = (0x733f34, 0x9a4e3d)
        }
        return [shades.0, shades.1].map { WorkbenchPalette.adaptive(light: $0, dark: $0) }
    }
}

enum WorkbenchPalette {
    static let canvas = adaptive(light: 0xf5f6f9, dark: 0x181a20)
    static let surface = adaptive(light: 0xffffff, dark: 0x20232b)
    static let inset = adaptive(light: 0xeff1f5, dark: 0x292d37)
    static let ink = adaptive(light: 0x252a38, dark: 0xe9ebf2)
    static let muted = adaptive(light: 0x596375, dark: 0xaeb6c6)
    static let line = adaptive(light: 0xdce1e9, dark: 0x3a4050)

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct WorkbenchSurface: ViewModifier {
    var radius: CGFloat = 13

    func body(content: Content) -> some View {
        content.background(WorkbenchPalette.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius).strokeBorder(WorkbenchPalette.line)
                    .allowsHitTesting(false)
            }
    }
}

struct WorkbenchButton: ButtonStyle {
    enum Kind { case primary, secondary, icon }

    let kind: Kind
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        let foreground = kind == .primary ? tint : WorkbenchPalette.ink
        let fill = kind == .primary ? tint.opacity(configuration.isPressed ? 0.20 : 0.11)
            : kind == .secondary ? WorkbenchPalette.surface : Color.clear
        configuration.label
            .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .icon ? 8 : 11)
            .frame(minWidth: 34, minHeight: 32)
            .background(fill, in: shape)
            .overlay {
                if kind == .secondary {
                    shape.strokeBorder(WorkbenchPalette.line)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.44)
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
    private let vpnLog = Logger(subsystem: "local.ynu.workbench", category: "VPN")
    let schedule = Schedule()
    @Published var page: Page = .courses
    @Published var showAddRoute = false
    @Published var showVPNControls = false
    @Published var desktopAgendaVisible = false
    var toggleDesktopAgenda: (() -> Void)?
    @Published var retryKeepalive = UserDefaults.standard.object(forKey: "retryVPNKeepalive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(retryKeepalive, forKey: "retryVPNKeepalive") }
    }
    @Published var reconnectVPN = UserDefaults.standard.object(forKey: "reconnectVPN") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reconnectVPN, forKey: "reconnectVPN") }
    }
    @Published var testingNetwork = false
    @Published var networkReport: NetworkReport?
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
    @Published var state = "未连接" {
        didSet {
            if state != oldValue { vpnLog.info("VPN 状态：\(self.state, privacy: .public)") }
        }
    }
    @Published private(set) var vpnHealth: DPTunnelHealth?
    private var didReachCampus = false
    private var didOpenTunnel = false
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
    @Published private var duplicateSessionAccount: String?
    var takeoverAvailable: Bool {
        duplicateSessionAccount == account.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @Published var busy = false
    private let pendingLogout = DPPendingLogout()
    private var worker: Task<Void, Never>?
    var changed: (() -> Void)?
    var quitting = false

    var canQuickConnect: Bool {
        let username = account.trimmingCharacters(in: .whitespacesAndNewlines)
        return !busy && error == nil && remember && !username.isEmpty
            && UserDefaults.standard.string(forKey: "vpnAccount") == username
            && FileManager.default.fileExists(atPath: DPKernelSession.helperSocket)
    }

    @discardableResult
    func connect(replaceExisting: Bool = false, savedPasswordOnly: Bool = false) -> Bool {
        guard worker == nil, !savedPasswordOnly || canQuickConnect,
              !replaceExisting || takeoverAvailable else { return false }
        let confirmedDuplicate = takeoverAvailable
        duplicateSessionAccount = nil
        if !savedPasswordOnly { NSApp.keyWindow?.makeFirstResponder(nil) }
        let endpoint = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard [Self.gateway, Self.gateway + "/", "vpn.ynu.edu.cn", Self.gateway + ":443"].contains(endpoint) else {
            error = "请输入云大 VPN 地址 vpn.ynu.edu.cn。"
            return false
        }
        guard FileManager.default.fileExists(atPath: DPKernelSession.helperSocket) else {
            error = DPKernelError.noHelper.localizedDescription
            return false
        }
        let username = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let usedSavedPassword = savedPasswordOnly || (password.isEmpty && remember)
        let secret = usedSavedPassword ? VPNKeychain.read(account: username) ?? "" : password
        guard !username.isEmpty, !secret.isEmpty else { error = "请输入账号和密码。"; return false }
        let shouldRemember = remember
        let useBroadRoutes = broad
        let selectedHosts = extraHosts
        let routePortal = includePortal
        let shouldRetry = retryKeepalive
        let previousAccount = UserDefaults.standard.string(forKey: "vpnAccount")
        let anotherWorkbenchIsRunning = Bundle.main.bundleIdentifier.map { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        } ?? false
        error = nil
        busy = true
        vpnHealth = nil
        didReachCampus = false
        didOpenTunnel = false
        let connectingState = replaceExisting ? "正在接管并连接" : "正在连接"
        state = connectingState
        changed?()
        worker = Task { [weak self, pendingLogout] in
            var failures = 0
            while !Task.isCancelled {
                let takeOver = failures == 0 && replaceExisting
                let started = ContinuousClock.now
                do {
                    try await DPKernelSession.run(username: username, password: secret, broad: useBroadRoutes,
                                                  extraHosts: selectedHosts, replaceExisting: takeOver,
                                                  confirmedDuplicate: takeOver && confirmedDuplicate, includePortal: routePortal,
                                                  retryKeepalive: shouldRetry, pendingLogout: pendingLogout,
                                                  health: { [weak self] health in
                        self?.updateVPNHealth(health)
                    }) { [weak self] _, hosts in
                        guard let self, self.worker?.isCancelled == false else { return }
                        if !self.didOpenTunnel {
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
                            self.didOpenTunnel = true
                        }
                        self.routes = hosts
                        self.updateVPNHealth(.checking)
                    }
                    break
                } catch DPControlError.invalidSession(let rejection) {
                    guard !Task.isCancelled else { break }
                    let duplicateSession = rejection.reason == .duplicate
                    let vendorCode = rejection.vendorCode.map { String($0) } ?? "—"
                    self?.vpnLog.info("登录被拒绝，HTTP \(rejection.status, privacy: .public)，DP \(vendorCode, privacy: .public)")
                    var failure = rejection.message
                    if usedSavedPassword && (rejection.reason == .credential || rejection.reason == .authentication) {
                        failure += " 本次使用了钥匙串中的密码。"
                    }
                    if takeOver && (confirmedDuplicate || duplicateSession) {
                        failure = "网关未完成旧会话接管。\(failure)"
                    }
                    self?.finished(failure, duplicateSessionAccount: duplicateSession ? username : nil)
                    return
                } catch {
                    guard !Task.isCancelled else { break }
                    var failure = error.localizedDescription
                    if let issue = error as? DPKernelError, case .routeMismatch = issue, anotherWorkbenchIsRunning {
                        failure += " 检测到另一个工作台实例正在运行。请断开旧版工作台的 VPN 后重试。"
                    }
                    guard self?.didOpenTunnel == true, self?.reconnectVPN == true,
                          DPReconnectPolicy.canRetry(error) else {
                        self?.finished(failure)
                        return
                    }
                    if self?.didReachCampus == true, ContinuousClock.now - started >= .seconds(90) {
                        failures = 1
                    } else {
                        failures += 1
                    }
                    let delay = DPReconnectPolicy.delay(afterFailures: failures - 1)
                    self?.routes = []
                    self?.didReachCampus = false
                    self?.updateVPNHealth(.reconnecting(delay, failure))
                    do {
                        try await Task.sleep(for: .seconds(delay))
                        try await DPNetworkAvailability.waitUntilAvailable()
                    } catch { break }
                    guard !Task.isCancelled else { break }
                    guard self?.reconnectVPN == true else {
                        self?.finished(failure)
                        return
                    }
                    self?.updateVPNHealth(.connectingAgain)
                }
            }
            self?.finished(nil)
        }
        return true
    }

    private func updateVPNHealth(_ health: DPTunnelHealth) {
        guard worker?.isCancelled == false, health != vpnHealth else { return }
        vpnHealth = health
        state = health.status
        if health == .stopping {
            campusSync?.cancel()
            campusSync = nil
            campusSyncGeneration = nil
        }
        changed?()
        if health.isVerified, !didReachCampus {
            didReachCampus = true
            startCampusSync()
        }
    }

    func testNetwork() {
        guard !testingNetwork else { return }
        testingNetwork = true
        changed?()
        Task {
            networkReport = await NetworkReport.measure()
            testingNetwork = false
            changed?()
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
            await self.syncCampusPages(includeCourses: true)
        }
    }

    func refreshSelectedPages() {
        let retryCourses = syncOnConnect && pendingCourses
        let retryDevices = syncOnConnect && pendingDevices
        guard automaticImport || retryCourses || retryDevices,
              !refreshing, !importing, campusSync == nil else { return }
        Task { await syncCampusPages(includeCourses: retryCourses) }
    }

    private func syncCampusPages(includeCourses: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if includeCourses {
            do {
                let text = try await YNUBrowserBridge.read(.courses, browser: browser)
                guard !Task.isCancelled else { return }
                if schedule.importBrowserText(text) { pendingCourses = false }
                else { schedule.status = YNUBrowserBridge.ReadError.unsupportedFormat.localizedDescription }
            } catch {
                guard !Task.isCancelled else { return }
                schedule.status = error.localizedDescription
            }
        }
        guard !Task.isCancelled else { return }
        do { try await updateDeviceList() }
        catch let error as YNUBrowserBridge.ReadError
            where error == .automationUnavailable || error == .javaScriptUnavailable {
            deviceMessage = error.localizedDescription
        } catch {
            deviceMessage = devices.isEmpty ? error.localizedDescription : "显示上次同步。\(error.localizedDescription)"
        }
    }

    private func updateDeviceList() async throws {
        let text: String
        if let direct = try? await YNUBrowserBridge.readDevicesOverHTTP() {
            text = direct
        } else {
            text = try await YNUBrowserBridge.read(.devices, browser: browser)
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
        vpnHealth = nil
        state = "正在断开"
        changed?()
        worker.cancel()
    }

    private func finished(_ failure: String?, duplicateSessionAccount: String? = nil) {
        self.duplicateSessionAccount = duplicateSessionAccount
        worker = nil
        busy = false
        vpnHealth = nil
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
    @State private var showCampusNotices = false
    @State private var showCampusOffice = false
    @State private var showNetworkDetails = false
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
    @AppStorage("keepInMenuBarOnClose") private var keepInMenuBarOnClose = true
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
                    CampusWeek(schedule: schedule, desktopAgendaVisible: app.desktopAgendaVisible, toggleDesktopAgenda: { app.toggleDesktopAgenda?() })
                case .todos:
                    VStack(alignment: .leading, spacing: 18) {
                        Text("待办事项").font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(WorkbenchPalette.ink).accessibilityAddTraits(.isHeader)
                        TodoView(model: schedule)
                    }.frame(maxWidth: 890).padding(22).frame(maxWidth: .infinity, alignment: .center)
                case .vpn:
                    vpn
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(WorkbenchPalette.line).frame(height: 1)
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
                    }.buttonStyle(WorkbenchButton(kind: .icon, tint: theme.tint)).accessibilityLabel("工作台设置").help("工作台设置")
                        .padding(.trailing, 16)
                }
        }
        .frame(minWidth: 735, minHeight: 510)
        .background(WorkbenchPalette.canvas.ignoresSafeArea())
        .sheet(isPresented: $settings) { settingsPage }
        .sheet(isPresented: $showCampusNotices) { CampusNoticesView() }
        .sheet(isPresented: $showCampusOffice) { CampusOfficeView() }
        .sheet(isPresented: $app.showAddRoute) { addRoutePage.onAppear { routeInput = ""; routeProblem = nil } }
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
        HStack(spacing: 5) {
            ForEach(Page.allCases, id: \.self) { page in
                let selected = app.page == page
                Button { app.page = page } label: {
                    Label(page.title, systemImage: page.symbol)
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? theme.tint : WorkbenchPalette.muted)
                        .frame(minWidth: 105, minHeight: 36)
                        .background(selected ? theme.tint.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(WorkbenchPalette.inset, in: RoundedRectangle(cornerRadius: 10))
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(WorkbenchPalette.surface)
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("工作台设置").font(.system(size: 25, weight: .semibold))
                .foregroundStyle(WorkbenchPalette.ink)
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
                }.frame(width: 112).padding(7)
                    .background(WorkbenchPalette.inset, in: RoundedRectangle(cornerRadius: 10))
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        Text(settingsSection).font(.system(size: 22, weight: .semibold))
                        switch settingsSection {
                        case "网络":
                            settingsSwitch("VPN 掉线后自动重连", isOn: $app.reconnectVPN)
                            settingsSwitch("保活检查异常时重试", isOn: $app.retryKeepalive)
                            Text("手动断开会取消自动重连。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Divider()
                            settingsSwitch("校园网段走 VPN", isOn: $app.broad)
                                .onChange(of: app.broad) { UserDefaults.standard.set($0, forKey: "broadVPN") }
                            settingsSwitch("校园自助服务走 VPN", isOn: $app.includePortal)
                            Text("更改将在下次连接时生效。").foregroundStyle(.secondary)
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
                            settingsSwitch("显示下一堂课", isOn: $showUpcoming)
                            settingsSwitch("突出下一堂课", isOn: $coloredBanner)
                            settingsSwitch("显示带日期的待办", isOn: $showDatedTasks)
                            HStack {
                                Button("管理调课") {
                                    settings = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { schedule.showAdjustments = true }
                                }
                                Button("导出日历") { exportCalendar(schedule) }
                            }
                        case "导入":
                            Picker("默认浏览器", selection: $app.browser) {
                                ForEach(YNUBrowserBridge.Browser.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            settingsSwitch("自动同步已打开的学校网页", isOn: $app.syncOnConnect)
                            TextField("教师课表网址（可选）", text: $teacherScheduleURL)
                            if !teacherScheduleURL.isEmpty && YNUBrowserBridge.courseImportURL(teacherScheduleURL) == nil {
                                Text("请输入 https://ehall.ynu.edu.cn 下的课表地址。").foregroundStyle(.red)
                            }
                            settingsSwitch("定期更新在线设备", isOn: $app.automaticImport)
                            Text("同步需要你先打开并登录学校网页，首次使用可能需要允许工作台读取浏览器。")
                                .foregroundStyle(.secondary)
                        default:
                            settingsRow("外观") {
                                Picker("外观", selection: $app.appearance) {
                                    ForEach(WorkbenchAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }.pickerStyle(.segmented).labelsHidden().frame(width: 234)
                            }
                            settingsRow("启动页面") {
                                Picker("启动页面", selection: $startPage) {
                                    ForEach(Page.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                                }.labelsHidden().frame(width: 140)
                            }
                            Divider()
                            Text("主题色").font(.system(size: 15, weight: .semibold))
                            HStack(spacing: 8) {
                                ForEach(WorkbenchTheme.allCases, id: \.rawValue) { option in
                                    let selected = themeName == option.rawValue
                                    Button { themeName = option.rawValue } label: {
                                        VStack(spacing: 7) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 8).fill(option.tint)
                                                if selected {
                                                    Image(systemName: "checkmark").foregroundStyle(.white).fontWeight(.bold)
                                                }
                                            }.frame(height: 28)
                                            Text(option.rawValue).font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.primary).fixedSize()
                                        }.padding(7).frame(maxWidth: .infinity)
                                            .background(option.tint.opacity(selected ? 0.13 : 0),
                                                        in: RoundedRectangle(cornerRadius: 10))
                                            .overlay { RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(option.tint.opacity(selected ? 0.65 : 0.18)) }
                                    }.buttonStyle(.plain)
                                        .accessibilityAddTraits(selected ? .isSelected : [])
                                }
                            }
                            Divider()
                            settingsSwitch("关闭窗口后留在菜单栏", isOn: $keepInMenuBarOnClose)
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(17)
                }.modifier(WorkbenchSurface())
            }
            HStack { Spacer(); Button("完成") { settings = false }.buttonStyle(WorkbenchButton(kind: .primary, tint: theme.tint)).keyboardShortcut(.defaultAction) }
        }.padding(25).frame(width: 670, height: 490)
            .background(WorkbenchPalette.canvas)
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(WorkbenchPalette.ink)
                .accessibilityHidden(true)
            Spacer(minLength: 12)
            control()
        }.frame(minHeight: 32)
    }

    private func settingsSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
        settingsRow(title) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    private var routingCard: some View {
        let visible = app.routes.filter { !DPCampusPolicy.portalDestinations.contains($0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("VPN 连接范围", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { routeInput = ""; routeProblem = nil; app.showAddRoute = true } label: {
                    Label("添加地址", systemImage: "plus")
                }
            }
            if !visible.isEmpty {
                Text(visible.joined(separator: "  ·  ")).font(.callout.monospaced()).textSelection(.enabled)
            } else if !app.extraHosts.isEmpty {
                Text(app.extraHosts.joined(separator: "  ·  ")).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            if !routeMessage.isEmpty { Text(routeMessage).font(.callout).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .modifier(WorkbenchSurface())
    }

    private var addRoutePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加校园地址").font(.title2.bold())
            TextField("学校网址或 10.x IPv4 地址", text: $routeInput)
            if let routeProblem { Text(routeProblem).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { app.showAddRoute = false }
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
                            app.showAddRoute = false
                        } catch { routeProblem = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(routeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvingRoute)
            }
        }.padding(23).frame(width: 445)
    }


    @State private var revealVPNPassword = false
    @State private var revealedSavedPassword = ""

    private func hideVPNPassword() {
        revealVPNPassword = false
        revealedSavedPassword = ""
    }

    private var vpn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("校内资源").font(.system(size: 27, weight: .semibold)).foregroundStyle(WorkbenchPalette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { showCampusOffice = true } label: {
                        Label("办事速查", systemImage: "building.2")
                    }.buttonStyle(WorkbenchButton(kind: .primary, tint: theme.tint))
                    Button { showCampusNotices = true } label: {
                        Label("校内通知", systemImage: "newspaper")
                    }.buttonStyle(WorkbenchButton(kind: .secondary, tint: theme.tint))
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        linksCard.frame(minWidth: 375)
                        networkColumn.frame(minWidth: 420)
                    }
                    VStack(spacing: 14) {
                        linksCard
                        networkColumn
                    }
                }
            }
            .onAppear {
                if app.busy || app.error != nil { app.showVPNControls = true }
            }
            .frame(maxWidth: 1040, alignment: .leading).frame(maxWidth: .infinity)
            .padding(22)
        }
    }

    private var networkColumn: some View {
        VStack(spacing: 12) {
            vpnConnectionCard
            VStack(alignment: .leading, spacing: 9) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showNetworkDetails.toggle() }
                } label: {
                    HStack {
                        Label("在线设备与测速", systemImage: "speedometer")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        if let report = app.networkReport {
                            Text(report.shortResult).font(.callout).foregroundStyle(WorkbenchPalette.muted)
                        }
                        Image(systemName: showNetworkDetails ? "chevron.up" : "chevron.down")
                            .foregroundStyle(theme.tint)
                    }.padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(showNetworkDetails ? "已展开" : "已折叠")
                if showNetworkDetails {
                    Rectangle().fill(WorkbenchPalette.line).frame(height: 1)
                    devicesCard
                    Rectangle().fill(WorkbenchPalette.line).frame(height: 1)
                    networkTools
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).modifier(WorkbenchSurface())
        }
    }

    private var vpnConnectionCard: some View {
    VStack(alignment: .leading, spacing: 0) {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { app.showVPNControls.toggle() }
        } label: {
            HStack {
                Label("校园 VPN", systemImage: "lock.shield").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(app.vpnHealth?.shortStatus ?? app.state)
                    .foregroundStyle(.secondary)
                Image(systemName: app.showVPNControls ? "chevron.up" : "chevron.down").foregroundStyle(theme.tint)
            }.padding(.vertical, 5).frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(app.showVPNControls ? "已展开" : "已折叠")
        if app.showVPNControls {
            VStack(spacing: 14) {
                if app.busy {
                    vpnStatus.padding(16).background(WorkbenchPalette.inset, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 19) {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield").foregroundStyle(theme.tint)
                            Text("连接校园 VPN").fontWeight(.semibold)
                        }.font(.system(size: 22))
                        vpnCredentials
                    }
                    .frame(maxWidth: .infinity)
                    .padding(19).background(WorkbenchPalette.inset, in: RoundedRectangle(cornerRadius: 10))
                }
                routingCard
            }.padding(.top, 12)
        }
    }
    .padding(16).modifier(WorkbenchSurface())
    }

    private var networkTools: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("网络测速").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let report = app.networkReport {
                    Button("复制诊断") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.summary, forType: .string)
                    }.buttonStyle(.borderless)
                }
                Button(app.testingNetwork ? "测速中…" : "开始测速") { app.testNetwork() }
                    .buttonStyle(WorkbenchButton(kind: .secondary, tint: theme.tint))
                    .disabled(app.testingNetwork)
            }
            if let report = app.networkReport {
                Text(report.summary).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text("用约 4 MB 测外网下载速度，同时检查校内连接。").foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
    }

    private var vpnStatus: some View {
        HStack(alignment: .center, spacing: 15) {
            Image(systemName: app.vpnHealth?.isVerified == true ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 28, weight: .medium)).foregroundStyle(theme.tint)
                .frame(width: 54, height: 54)
                .background(theme.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 4) {
                Text("校园 VPN").font(.system(size: 22, weight: .semibold))
                Text(app.state).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                if let detail = app.vpnHealth?.detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                }
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
                    .buttonStyle(WorkbenchButton(kind: .primary, tint: theme.tint))
                    .keyboardShortcut(.defaultAction)
            }
            if let error = app.error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if app.takeoverAvailable {
                    Button("剔除旧会话并连接…") {
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
                .background(WorkbenchPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchPalette.line).allowsHitTesting(false) }
        }
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("在线设备").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("打开自助服务") {
                    YNUBrowserBridge.openLinkedPage(YNUBrowserBridge.portalIP, browser: app.browser)
                }.buttonStyle(WorkbenchButton(kind: .secondary, tint: theme.tint))
                Button(app.importing ? "正在读取…" : "同步设备") { app.importDevices() }
                    .buttonStyle(WorkbenchButton(kind: .primary, tint: theme.tint)).disabled(app.importing)
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
                    Button(app.extraHosts.contains(device.address) ? "已添加" : "走 VPN") {
                        if app.addHost(device.address) { app.deviceMessage = "新地址将在下次连接时生效。" }
                    }.disabled(app.extraHosts.contains(device.address) || YNUBrowserBridge.privateAddress(device.address) == nil)
                }
            }
        }.padding(.vertical, 5)
    }

    private var linksCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("常用链接", systemImage: "link").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("编辑") { schedule.showServices = true }.buttonStyle(.borderless)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(schedule.services) { link in
                    Button { schedule.openService(link) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: link.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(theme.tint)
                                .frame(width: 29, height: 29)
                                .background(theme.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                            Text(link.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                .foregroundStyle(WorkbenchPalette.ink)
                            Spacer(minLength: 3)
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium))
                                .foregroundStyle(WorkbenchPalette.muted)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(WorkbenchPalette.inset.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(link.name)
                }
            }
        }.padding(17).modifier(WorkbenchSurface())
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

@MainActor
final class DPMenuApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model = Workbench()
    private var window: NSWindow?
    private var statusLabel: NSMenuItem?
    private var importTimer: Timer?
    private var vpnAction: NSMenuItem?
    private var speedAction: NSMenuItem?
    private var agendaAction: NSMenuItem?
    private var desktopPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.appearance.apply()
        model.startCampusSync(onLaunch: true)
        importTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.model.refreshSelectedPages() }
        }
        status.button?.image = WorkbenchMark.menuImage
        status.isVisible = true
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusLabel = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        vpnAction = add("连接 VPN…", #selector(toggleVPN), to: menu)
        menu.addItem(.separator())
        add("打开云大工作台", #selector(openWorkbench), to: menu)
        agendaAction = add("显示桌面课表", #selector(toggleDesktopAgenda), to: menu)
        model.toggleDesktopAgenda = { [weak self] in self?.toggleDesktopAgenda() }
        let networkMenu = NSMenu()
        networkMenu.autoenablesItems = false
        speedAction = add("测速", #selector(testNetwork), to: networkMenu)
        add("添加 VPN 地址…", #selector(addCampusRoute), to: networkMenu)
        let networkItem = menu.addItem(withTitle: "网络工具", action: nil, keyEquivalent: "")
        networkItem.submenu = networkMenu
        menu.addItem(.separator())
        add("退出云大工作台", #selector(quit), to: menu).keyEquivalent = "q"
        status.menu = menu
        model.changed = { [weak self] in self?.updateMenu() }
        updateMenu()
        show(Page(rawValue: UserDefaults.standard.string(forKey: "startPage") ?? "") ?? .courses)
        if UserDefaults.standard.bool(forKey: "showDesktopAgenda") { toggleDesktopAgenda() }
    }

    private var keepsRunningWhenClosed: Bool {
        UserDefaults.standard.object(forKey: "keepInMenuBarOnClose") as? Bool ?? true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window, keepsRunningWhenClosed else { return true }
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !keepsRunningWhenClosed
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
        let vpnStatus = model.vpnHealth?.shortStatus ?? model.state
        statusLabel?.title = vpnStatus
        statusLabel?.isHidden = !model.busy
        status.button?.toolTip = "云大工作台"
        if model.busy {
            vpnAction?.title = "断开 VPN"
        } else {
            vpnAction?.title = model.canQuickConnect ? "快速连接 VPN" : "连接 VPN…"
        }
        vpnAction?.isEnabled = model.state != "正在断开"
        agendaAction?.title = model.desktopAgendaVisible ? "隐藏桌面课表" : "显示桌面课表"
        speedAction?.title = model.testingNetwork ? "测速中…" : model.networkReport.map { "测速 · " + $0.shortResult } ?? "测速"
        speedAction?.isEnabled = !model.testingNetwork
        status.button?.appearsDisabled = false
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
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
            newWindow.delegate = self
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

    @objc private func toggleDesktopAgenda() {
        if model.desktopAgendaVisible {
            desktopPanel?.orderOut(nil)
        } else {
            if desktopPanel == nil {
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 328, height: 285),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "桌面课表"
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.hidesOnDeactivate = false
                panel.isFloatingPanel = false
                panel.isMovableByWindowBackground = true
                panel.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                panel.contentView = NSHostingView(rootView: DesktopAgenda(schedule: model.schedule,
                    open: { [weak self] in self?.show(.courses) },
                    close: { [weak self] in self?.toggleDesktopAgenda() }))
                if let frame = (window?.screen ?? NSScreen.main)?.visibleFrame {
                    panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 365, y: frame.maxY - 25))
                }
                desktopPanel = panel
            }
            desktopPanel?.orderFrontRegardless()
        }
        model.desktopAgendaVisible.toggle()
        UserDefaults.standard.set(model.desktopAgendaVisible, forKey: "showDesktopAgenda")
        updateMenu()
    }

    @objc private func testNetwork() { model.testNetwork() }
    @objc private func addCampusRoute() {
        show(.vpn)
        model.showAddRoute = true
    }

    @objc private func openWorkbench() { show(model.page) }
    @objc private func toggleVPN() {
        if model.busy {
            model.disconnect()
        } else if !model.connect(savedPasswordOnly: true) {
            model.showVPNControls = true
            show(.vpn)
        }
    }
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
