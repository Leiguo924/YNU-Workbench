import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

struct Course: Codable, Identifiable, Equatable {
    var id: String { "\(name)|\(weeks)|\(day)|\(start)|\(end)|\(place)" }
    let name: String, weeks: String, place: String
    let day: Int, start: Int, end: Int
    func occurs(_ week: Int) -> Bool {
        weeks.replacingOccurrences(of: "周", with: "").split(separator: ",").contains { part in
            let nums = part.split(separator: "-").compactMap { Int($0) }
            guard let first = nums.first else { return false }
            return nums.count == 1 ? week == first : nums.count == 2 && first <= nums[1] && week >= first && week <= nums[1]
        }
    }
}

func parseCourses(_ text: String) -> [Course] {
    let pattern = #"(?:本|研)\s*([^\n]+?)\s+([\d,\-周]+)周,星期([1-7]),(\d+)-(\d+)节,([^\n]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    var found: [Course] = []
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        func field(_ n: Int) -> String { ns.substring(with: match.range(at: n)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let day = Int(field(3)), let start = Int(field(4)), let end = Int(field(5)), (1...12).contains(start), (start...12).contains(end) else { continue }
        let course = Course(name: field(1), weeks: field(2), place: field(6), day: day, start: start, end: end)
        if !found.contains(course) { found.append(course) }
    }
    return found
}

struct Adjustment: Codable, Identifiable {
    var id: String { courseID + "|" + String(originalDay.timeIntervalSince1970) }
    let courseID: String
    let originalDay: Date
    var targetDay: Date
    var start: Int
    var end: Int
    var place: String
}
struct Meeting: Identifiable {
    let course: Course
    let originalDay: Date
    let day: Date
    let start: Int
    let end: Int
    let place: String
    let adjusted: Bool
    var id: String { course.id + "|" + String(originalDay.timeIntervalSince1970) }
}

struct TodoItem: Codable, Identifiable {
    var id = UUID()
    var title: String
    var due: Date?
    var done = false
    var hasTime: Bool? = nil

    var overdue: Bool {
        guard !done, let due else { return false }
        return due < (hasTime == true ? .now : Calendar.current.startOfDay(for: .now))
    }
}
struct CampusLink: Codable, Identifiable {
    var id = UUID()
    var name: String
    var address: String

    var symbol: String {
        switch name {
        case "图书馆": return "books.vertical"
        case "校园邮箱": return "envelope"
        case "融合门户": return "square.grid.2x2"
        case "教务系统": return "graduationcap"
        case "研究生平台": return "person.text.rectangle"
        case "OA 系统": return "folder"
        case "财务处": return "creditcard"
        case "综合财务信息平台": return "banknote"
        case "云南大学": return "building.columns"
        default: return "link"
        }
    }
}
struct FixedEvent: Codable, Identifiable { var id = UUID(); var title: String; var place: String; var weekday: Int; var startHour: Int; var startMinute: Int; var endHour: Int; var endMinute: Int; var from: Date; var until: Date }

final class Schedule: ObservableObject {
    @Published var tab = 0
    @Published var courses: [Course] = []
    @Published var manualCourses: [Course] = []
    @Published var adjustments: [Adjustment] = []
    @Published var todos: [TodoItem] = []
    @Published var groups: [FixedEvent] = []
    @Published var services: [CampusLink] = [CampusLink(name:"教务系统",address:"https://ehall.ynu.edu.cn/new/index.html"),CampusLink(name:"OA 系统",address:"https://ids.ynu.edu.cn/authserver/login?service=https%3A%2F%2Fnew-oa.ynu.edu.cn%2Fseeyon%2Findex.jsp"),CampusLink(name:"财务处",address:"https://www.cwc.ynu.edu.cn/"),CampusLink(name:"研究生平台",address:"https://yjs-grs.ynu.edu.cn/")]
    @Published var showServices = false
    @Published var editing: Meeting?
    @Published var showAdjustments = false
    @Published var showManual = false
    @Published var editingManual: Course?
    @Published var confirmDeleteCourse = false
    @Published var showTodo = false
    var selectedTodo: TodoItem?

    func openTodo(_ task: TodoItem? = nil) {
        selectedTodo = task
        showTodo = true
    }
    @Published var showGroup = false
    @Published var showImport = false
    @Published var showSettings = false
    @Published var noteTarget: Course?
    @Published var notes: [String:String] = [:]
    @Published var adjustTarget: Meeting?
    @Published var status = "课程数据保存在本机。"
    @Published var firstMonday = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 31))!
    @Published var week = 11
    @Published var lastSync: Date?
    var allCourses: [Course] { courses + manualCourses }
    init() {
        let current = UserDefaults.standard
        let legacy = current.persistentDomain(forName: "local.ynu.timetable") ?? [:]
        for key in ["courses", "manualCourses", "todos", "groups", "campusLinks", "adjustments",
                    "firstMonday", "courseNotes", "lastSync"] where current.object(forKey: key) == nil {
            if let value = legacy[key] { current.set(value, forKey: key) }
        }
        if let data = UserDefaults.standard.data(forKey: "courses"), let value = try? JSONDecoder().decode([Course].self, from: data) { courses = value }
        if let data = UserDefaults.standard.data(forKey: "manualCourses"), let value = try? JSONDecoder().decode([Course].self, from: data) { manualCourses = value }
        if let data = UserDefaults.standard.data(forKey: "todos"), let value = try? JSONDecoder().decode([TodoItem].self, from: data) { todos = value }
        if let data = UserDefaults.standard.data(forKey: "groups"), let value = try? JSONDecoder().decode([FixedEvent].self, from: data) { groups = value }
        if let data = UserDefaults.standard.data(forKey: "campusLinks"), let value = try? JSONDecoder().decode([CampusLink].self, from: data) { services = value }
        services.removeAll { $0.name == "本科生院" }
        if let i=services.firstIndex(where:{$0.name == "OA 系统"}) {
            services[i].address = "https://ids.ynu.edu.cn/authserver/login?service=https%3A%2F%2Fnew-oa.ynu.edu.cn%2Fseeyon%2Findex.jsp"
        }
        let knownLinks = ["财务处":"https://www.cwc.ynu.edu.cn/", "研究生教学":"https://yjs-grs.ynu.edu.cn/", "本科教务":"https://ehall.ynu.edu.cn/new/index.html"]
        for i in services.indices where services[i].address.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            if let url = knownLinks[services[i].name] { services[i].address = url }
        }
        if !current.bool(forKey: "didAddCampusLinksV16") {
            let additional = [
                CampusLink(name: "图书馆", address: "https://lib.ynu.edu.cn/"),
                CampusLink(name: "校园邮箱", address: "https://mail.ynu.edu.cn/"),
                CampusLink(name: "融合门户", address: "https://ehall.ynu.edu.cn/"),
                CampusLink(name: "云南大学", address: "https://www.ynu.edu.cn/")
            ]
            for link in additional where !services.contains(where: { $0.name == link.name || $0.address == link.address }) {
                services.append(link)
            }
            persist(services, key: "campusLinks")
            current.set(true, forKey: "didAddCampusLinksV16")
        }
        if !current.bool(forKey: "didReviseCampusLinksV17") {
            services.removeAll { (name: $0.name, address: $0.address) == ("图书馆选座", "https://seat-lib.ynu.edu.cn/")
                || (name: $0.name, address: $0.address) == ("WebVPN", "https://webvpn.ynu.edu.cn/") }
            if let index = services.firstIndex(where: { $0.name == "融合门户" && $0.address == "https://ehall.ynu.edu.cn/" }) {
                services[index].address = "https://casp.ynu.edu.cn/"
            }
            persist(services, key: "campusLinks")
            current.set(true, forKey: "didReviseCampusLinksV17")
        }
        if !current.bool(forKey: "didReviseCampusLinksV18") {
            let address = "https://fm-cwc.ynu.edu.cn/Api/CAS/Login"
            services.removeAll { $0.name == "云南大学" && $0.address == "https://www.ynu.edu.cn/" }
            if !services.contains(where: { $0.name == "综合财务信息平台" || $0.address == address }) {
                services.append(CampusLink(name: "综合财务信息平台", address: address))
            }
            persist(services, key: "campusLinks")
            current.set(true, forKey: "didReviseCampusLinksV18")
        }
        if let data = UserDefaults.standard.data(forKey: "adjustments"), let value = try? JSONDecoder().decode([Adjustment].self, from: data) { adjustments = value }
        if let date = UserDefaults.standard.object(forKey: "firstMonday") as? Date { firstMonday = date }
        if let data = UserDefaults.standard.data(forKey: "courseNotes"), let value = try? JSONDecoder().decode([String:String].self, from: data) { notes = value }
        lastSync = UserDefaults.standard.object(forKey: "lastSync") as? Date
        goToday()
    }
    func persist<T: Encodable>(_ value: T, key: String) { if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey:key) } }
    func importClipboard() {
        guard let text = NSPasteboard.general.string(forType:.string) else { status = "剪贴板中没有文本。"; return }
        if importBrowserText(text) {
            showImport = false
        } else {
            status = "没有识别到课程。请在教务课表页面全选并复制。"
        }
    }

    @discardableResult
    func importBrowserText(_ text: String) -> Bool {
        let found = parseCourses(text)
        guard !found.isEmpty else { return false }
        if found != courses {
            courses = found
            persist(found, key: "courses")
        }
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: "lastSync")
        status = "已从教务导入 \(found.count) 条课程。"
        return true
    }

    func openPortal() { YNUBrowserBridge.openLinkedPage(URL(string: "https://ehall.ynu.edu.cn/new/index.html")!) }
    func openService(_ link: CampusLink) {
        guard let url = validatedCampusURL(link.address) else { showServices = true; return }
        NSWorkspace.shared.open(url)
    }
    func meetings(in week: Int) -> [Meeting] {
        let calendar = Calendar.current
        guard let weekStart = calendar.date(byAdding: .day, value: (week - 1) * 7, to: calendar.startOfDay(for: firstMonday)), let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return [] }
        var meetings: [Meeting] = []
        for course in allCourses where course.occurs(week) {
            guard let original = calendar.date(byAdding: .day, value: course.day - 1, to: weekStart) else { continue }
            if !adjustments.contains(where: { $0.courseID == course.id && calendar.isDate($0.originalDay, inSameDayAs: original) }) {
                meetings.append(Meeting(course: course, originalDay: original, day: original, start: course.start, end: course.end, place: course.place, adjusted: false))
            }
        }
        for change in adjustments where change.targetDay >= weekStart && change.targetDay < weekEnd {
            if let course = allCourses.first(where: { $0.id == change.courseID }) {
                meetings.append(Meeting(course: course, originalDay: change.originalDay, day: change.targetDay, start: change.start, end: change.end, place: change.place, adjusted: true))
            }
        }
        return meetings.sorted { $0.day == $1.day ? $0.start < $1.start : $0.day < $1.day }
    }
    func hasConflict(for meeting:Meeting,day:Date,start:Int,end:Int)->Bool {
        let week=weekNumber(for:day)
        guard week>0,(1...12).contains(start),(1...12).contains(end) else {return false}
        let classConflict=meetings(in:week).contains{$0.id != meeting.id && Calendar.current.isDate($0.day,inSameDayAs:day) && start <= $0.end && $0.start <= end}
        let starts=[510,565,630,685,840,895,960,1015,1140,1195,1250,1305]
        let ends=[555,610,675,730,885,940,1005,1060,1185,1240,1295,1350]
        let date=Calendar.current.startOfDay(for:day)
        let weekday=(Calendar.current.component(.weekday,from:date)+5)%7+1
        let groupConflict=groups.contains{$0.weekday==weekday && date>=Calendar.current.startOfDay(for:$0.from) && date<=Calendar.current.startOfDay(for:$0.until) && starts[start-1] < $0.endHour*60+$0.endMinute && $0.startHour*60+$0.startMinute < ends[end-1]}
        return classConflict || groupConflict
    }
    func save(_ change: Adjustment) {
        adjustments.removeAll { $0.id == change.id }
        adjustments.append(change)
        persistAdjustments()
    }
    func restore(_ meeting: Meeting) {
        adjustments.removeAll { $0.id == meeting.id }
        persistAdjustments()
    }
    func persistAdjustments() {
        if let data = try? JSONEncoder().encode(adjustments) { UserDefaults.standard.set(data, forKey: "adjustments") }
    }
    func weekNumber(for date: Date) -> Int {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: firstMonday), to: Calendar.current.startOfDay(for: date)).day ?? 0
        return days >= 0 ? days / 7 + 1 : 0
    }
    func goToday() {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: firstMonday), to: Calendar.current.startOfDay(for: Date())).day ?? 0
        week = max(1, days / 7 + 1)
    }
}


func validatedCampusURL(_ text:String)->URL? {
    guard let components=URLComponents(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),let scheme=components.scheme?.lowercased(),["http","https"].contains(scheme),let host=components.host,!host.isEmpty,components.user==nil,components.password==nil else{return nil}
    return components.url
}

struct TodoView: View {
    @ObservedObject var model: Schedule
    private var ordered: [TodoItem] {
        model.todos.sorted { first, second in
            first.done == second.done ? (first.due ?? .distantFuture) < (second.due ?? .distantFuture) : !first.done
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("未完成 · \(ordered.filter { !$0.done }.count)")
                    .font(.headline).foregroundStyle(.secondary)
                Spacer()
                Button { model.openTodo() } label: {
                    Label("添加待办", systemImage: "plus").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.borderedProminent)
            }
            if ordered.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "checklist").font(.system(size: 28)).foregroundStyle(Color.teal)
                    Text("暂无待办").font(.headline)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(ordered) { task in row(task) }
                    }.padding(.vertical, 2)
                }
            }
        }
    }

    private func row(_ task: TodoItem) -> some View {
        let accent: Color = task.done ? .teal : task.overdue ? .red : .accentColor
        return HStack(alignment: .center, spacing: 14) {
            Button {
                guard let index = model.todos.firstIndex(where: { $0.id == task.id }) else { return }
                model.todos[index].done.toggle()
                persist()
            } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 23)).foregroundStyle(accent)
                    .frame(width: 32, height: 36)
            }.buttonStyle(.plain).accessibilityLabel(task.done ? "标为待办" : "标为完成")
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title).font(.system(size: 18, weight: .medium))
                    .strikethrough(task.done).foregroundStyle(task.done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = task.due {
                    let formatted = task.hasTime == true
                        ? date.formatted(.dateTime.month().day().hour().minute())
                        : date.formatted(.dateTime.month().day())
                    Label(formatted, systemImage: "calendar")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(accent)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("编辑待办") { model.openTodo(task) }
                Button("删除待办", role: .destructive) {
                    model.todos.removeAll { $0.id == task.id }
                    persist()
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 19))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("待办操作")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.18))
        }
    }

    private func persist() { model.persist(model.todos, key: "todos") }
}

struct TodoEditor: View {
    @ObservedObject var model: Schedule
    @AppStorage("workbenchTheme") private var themeName = WorkbenchTheme.ocean.rawValue
    private var tint: Color { (WorkbenchTheme(rawValue: themeName) ?? .ocean).tint }
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var title = ""
    @State private var dayText = ""
    @State private var timeText = ""
    @State private var showingCalendar = false
    @State private var showingTime = false
    @State private var selectedHour = 9
    @State private var selectedMinute = 0
    @State private var displayedMonth = Date()

    private var calendar: Calendar { .current }
    private var day: Date? {
        let fields = dayText.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].count == 4,
              let year = Int(fields[0]), (1...9999).contains(year),
              let month = Int(fields[1]), let day = Int(fields[2]) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }
    private var deadline: Date? {
        guard let day else { return nil }
        guard !timeText.isEmpty else { return day }
        let fields = timeText.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let hour = Int(fields[0]), (0..<24).contains(hour),
              let minute = Int(fields[1]), (0..<60).contains(minute) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                             matchingPolicy: .strict)
    }

    private var taskTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(model.selectedTodo == nil ? "新待办事项" : "编辑待办事项", systemImage: "checklist")
                .font(.system(size: 21, weight: .semibold)).foregroundStyle(tint)
            TextField("要做什么？", text: $title)
                .font(.system(size: 17)).textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .accessibilityLabel("待办内容")
            HStack(alignment: .top, spacing: 16) {
                deadlineField("日期", placeholder: "年-月-日", text: $dayText, icon: "calendar",
                              fieldLabel: "截止日期", pickerLabel: "打开日历") {
                    displayedMonth = day ?? .now
                    showingCalendar = true
                }
                .popover(isPresented: $showingCalendar) { calendarPanel }
                deadlineField("时间 · 可选", placeholder: "时:分", text: $timeText, icon: "clock",
                              fieldLabel: "截止时间", pickerLabel: "选择时间") {
                    let pieces = timeText.split(separator: ":").compactMap { Int($0) }
                    selectedHour = pieces.count == 2 ? min(23, max(0, pieces[0])) : 9
                    selectedMinute = pieces.count == 2 ? min(59, max(0, pieces[1])) : 0
                    showingTime = true
                }
                .popover(isPresented: $showingTime) { timePanel }
            }
            if deadline == nil && (!dayText.isEmpty || !timeText.isEmpty) {
                Text("请填写有效日期和时间，例如 2026-11-26、16:00。")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(taskTitle.isEmpty || (deadline == nil && (!dayText.isEmpty || !timeText.isEmpty)))
            }.controlSize(.large)
        }
        .padding(24).frame(width: 485).tint(tint)
        .onAppear {
            if let task = model.selectedTodo {
                title = task.title
                if let due = task.due {
                    dayText = formattedDay(due)
                    if task.hasTime == true {
                        timeText = String(format: "%02d:%02d", calendar.component(.hour, from: due),
                                          calendar.component(.minute, from: due))
                    }
                }
            }
            titleFocused = true
        }
    }

    private func deadlineField(_ label: String, placeholder: String, text: Binding<String>,
                               icon: String, fieldLabel: String, pickerLabel: String,
                               openPicker: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint).frame(height: 19, alignment: .leading)
            HStack(spacing: 0) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain).font(.system(size: 16, design: .monospaced))
                    .accessibilityLabel(fieldLabel).padding(.horizontal, 10)
                Button(action: openPicker) {
                    Image(systemName: icon).font(.system(size: 17))
                        .foregroundStyle(tint).frame(width: 35, height: 35)
                        .background(tint.opacity(0.11))
                }.buttonStyle(.plain).accessibilityLabel(pickerLabel).help(pickerLabel)
            }
            .frame(height: 35)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(tint.opacity(0.19)).allowsHitTesting(false) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择时间").font(.system(size: 19, weight: .semibold))
            Text("小时").font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            timeGrid(Array(0..<24), selected: $selectedHour, name: "小时")
            Text("分钟").font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            timeGrid(Array(stride(from: 0, to: 60, by: 5)), selected: $selectedMinute, name: "分钟")
            Stepper(value: $selectedMinute, in: 0...59) {
                Text(String(format: "%02d:%02d", selectedHour, selectedMinute))
                    .font(.system(size: 23, weight: .semibold, design: .monospaced))
            }.accessibilityLabel("逐分钟调整")
            HStack {
                Button("清除时间") { timeText = ""; showingTime = false }
                Spacer()
                Button("设定") {
                    timeText = String(format: "%02d:%02d", selectedHour, selectedMinute)
                    showingTime = false
                }.buttonStyle(.borderedProminent)
            }
        }.padding(16).frame(width: 305).tint(tint)
    }

    private func timeGrid(_ numbers: [Int], selected: Binding<Int>, name: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
            ForEach(numbers, id: \.self) { number in
                let active = selected.wrappedValue == number
                Button { selected.wrappedValue = number } label: {
                    Text(String(format: "%02d", number))
                        .font(.system(size: 15, weight: active ? .bold : .medium, design: .monospaced))
                        .frame(maxWidth: .infinity).frame(height: 29)
                        .background(tint.opacity(active ? 0.24 : 0.07), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityLabel("\(number) \(name)")
                    .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    private func formattedDay(_ date: Date) -> String {
        let fields = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", fields.year ?? 0, fields.month ?? 0, fields.day ?? 0)
    }

    private var calendarPanel: some View {
        let first = calendar.dateInterval(of: .month, for: displayedMonth)?.start ?? displayedMonth
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 0
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        return VStack(spacing: 12) {
            HStack {
                monthButton(-1, icon: "chevron.left", label: "上个月")
                Spacer()
                Text(first.formatted(.dateTime.year().month())).font(.system(size: 21, weight: .semibold))
                Spacer()
                monthButton(1, icon: "chevron.right", label: "下个月")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array("一二三四五六日"), id: \.self) { label in
                    Text(String(label)).foregroundStyle(.secondary)
                }
                ForEach(0..<(offset + count), id: \.self) { index in
                    let number = index - offset + 1
                    if number > 0, let choice = calendar.date(byAdding: .day, value: number - 1, to: first) {
                        let selected = day.map { calendar.isDate($0, inSameDayAs: choice) } ?? false
                        Button {
                            dayText = formattedDay(choice)
                            showingCalendar = false
                        } label: {
                            Text("\(number)").font(.system(size: 18, weight: selected ? .bold : .medium))
                                .frame(width: 38, height: 33)
                                .background(selected ? tint.opacity(0.27) : tint.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).foregroundStyle(calendar.isDateInToday(choice) ? tint : .primary)
                            .accessibilityLabel(formattedDay(choice))
                    } else {
                        Color.clear.frame(height: 33)
                    }
                }
            }
            HStack {
                Button("清除日期") { dayText = ""; timeText = ""; showingCalendar = false }
                Spacer()
                Button("今天") { dayText = formattedDay(.now); showingCalendar = false }
            }
        }.padding(16)
    }

    private func monthButton(_ step: Int, icon: String, label: String) -> some View {
        Button {
            displayedMonth = calendar.date(byAdding: .month, value: step, to: displayedMonth) ?? displayedMonth
        } label: {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).frame(width: 38, height: 32)
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private func save() {
        guard !taskTitle.isEmpty else { return }
        let due = deadline
        guard due != nil || (dayText.isEmpty && timeText.isEmpty) else { return }
        if let task = model.selectedTodo,
           let index = model.todos.firstIndex(where: { $0.id == task.id }) {
            model.todos[index].title = taskTitle
            model.todos[index].due = due
            model.todos[index].hasTime = !timeText.isEmpty
        } else if model.selectedTodo == nil {
            model.todos.append(TodoItem(title: taskTitle, due: due, hasTime: !timeText.isEmpty))
        }
        model.persist(model.todos, key: "todos")
        dismiss()
    }
}

struct ImportView: View {
    @ObservedObject var model: Schedule
    @AppStorage("browserChoice") private var browser = YNUBrowserBridge.Browser.safari.rawValue
    @State private var reader: Task<Void, Never>?
    @State private var attemptToken = UUID()
    @State private var showFallback = false

    private func beginReading(openPage: Bool) {
        guard let selected = YNUBrowserBridge.Browser(rawValue: browser) else { return }
        reader?.cancel()
        let token = UUID()
        attemptToken = token
        showFallback = false
        model.status = "正在查找已打开的教务课表。"
        reader = Task {
            defer { if attemptToken == token { reader = nil } }
            let limit = Date().addingTimeInterval(180)
            var openedPage = false
            repeat {
                do {
                    let result = try await YNUBrowserBridge.read(.courses, browser: selected)
                    guard !Task.isCancelled else { return }
                    if model.importBrowserText(result) {
                        model.showImport = false
                        NSApp.activate(ignoringOtherApps: true)
                        return
                    }
                } catch let error as YNUBrowserBridge.ReadError {
                    switch error {
                    case .automationUnavailable, .javaScriptUnavailable, .pageReadFailed:
                        model.status = error.localizedDescription
                        showFallback = true
                        return
                    case .browserClosed, .noSchoolPage:
                        if openPage && !openedPage {
                            YNUBrowserBridge.openLinkedPage(YNUBrowserBridge.selectedCourseImportURL, browser: selected)
                            openedPage = true
                        }
                        model.status = "等待已登录的教师个人课表。"
                    case .unsupportedFormat:
                        model.status = "已打开教务页面，等待课表显示。"
                    }
                } catch {
                    model.status = error.localizedDescription
                }
                if !openPage { return }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            } while !Task.isCancelled && Date() < limit
            if !Task.isCancelled {
                model.status = "还没读到课程。请确认浏览器中已经打开教师个人课表。"
                showFallback = true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入课表").font(.title2.bold())
            Text(model.status).foregroundStyle(.secondary)
            HStack {
                if showFallback { Button("粘贴课表") { model.importClipboard() } }
                Spacer()
                if let reader { Button("停止等待") { reader.cancel() } }
                Button("同步课表") { beginReading(openPage: true) }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 490)
            .onDisappear { reader?.cancel() }
    }
}

func calendarText(_ model:Schedule) -> String? {
    let starts=["08:30","09:25","10:30","11:25","14:00","14:55","16:00","16:55","19:00","19:55","20:50","21:45"]
    let ends=["09:15","10:10","11:15","12:10","14:45","15:40","16:45","17:40","19:45","20:40","21:35","22:30"]
    let calendar=Calendar.current
    let utc=DateFormatter();utc.locale=Locale(identifier:"en_US_POSIX");utc.timeZone=TimeZone(secondsFromGMT:0);utc.dateFormat="yyyyMMdd'T'HHmmss'Z'"
    func escaped(_ s:String)->String { s.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:",",with:"\\,").replacingOccurrences(of:";",with:"\\;") }
    func time(_ date:Date,_ text:String)->Date {let p=text.split(separator:":").compactMap{Int($0)};return calendar.date(bySettingHour:p[0],minute:p[1],second:0,of:date) ?? date}
    func folded(_ line:String)->String { var parts:[String]=[];var part="";var size=0;for scalar in line.unicodeScalars { let piece=String(scalar), n=piece.utf8.count; if size+n>75 {parts.append(part);part=" ";size=1};part += piece;size += n };parts.append(part);return parts.joined(separator:"\r\n") }
    var lines=["BEGIN:VCALENDAR","VERSION:2.0","PRODID:-//YNU Timetable//CN","CALSCALE:GREGORIAN"]
    func append(_ uid:String,_ title:String,_ place:String,_ start:Date,_ end:Date) { lines += ["BEGIN:VEVENT","UID:\(uid)@ynu-timetable.local","DTSTAMP:\(utc.string(from:Date()))","DTSTART:\(utc.string(from:start))","DTEND:\(utc.string(from:end))","SUMMARY:\(escaped(title))","LOCATION:\(escaped(place))","END:VEVENT"] }
    let last=model.allCourses.flatMap{$0.weeks.split(whereSeparator:{!$0.isNumber})}.compactMap{Int($0)}.max() ?? 0
    let moved=model.adjustments.map{model.weekNumber(for:$0.targetDay)}.max() ?? 0
    guard max(last,moved)<=60 else {model.status="无法导出：周次超出支持范围。";return nil}
    if max(last,moved)>0 { for week in 1...max(last,moved) { for m in model.meetings(in:week) {let hash=SHA256.hash(data:Data(m.id.utf8)).map{String(format:"%02x",$0)}.joined();append(hash,m.course.name,m.place,time(m.day,starts[m.start-1]),time(m.day,ends[m.end-1]))} } }
    for g in model.groups {
        let days=calendar.dateComponents([.day],from:calendar.startOfDay(for:g.from),to:calendar.startOfDay(for:g.until)).day ?? 0
        guard days>=0 && days<=1098 else {model.status="固定安排的日期范围不能超过三年。";return nil}
        for offset in 0...days {guard let d=calendar.date(byAdding:.day,value:offset,to:g.from) else {continue};let mondayBased=(calendar.component(.weekday,from:d)+5)%7+1;if mondayBased != g.weekday {continue};guard let start=calendar.date(bySettingHour:g.startHour,minute:g.startMinute,second:0,of:d),let end=calendar.date(bySettingHour:g.endHour,minute:g.endMinute,second:0,of:d) else {continue};append("\(g.id.uuidString)-\(Int(d.timeIntervalSince1970))",g.title,g.place,start,end)}
    }
    lines.append("END:VCALENDAR");return lines.map(folded).joined(separator:"\r\n")+"\r\n"
}
func exportCalendar(_ model:Schedule) {
    guard let content=calendarText(model) else {return}
    let panel=NSSavePanel();panel.allowedContentTypes=[UTType(filenameExtension:"ics") ?? .data];panel.nameFieldStringValue="云大课表.ics";panel.message="导出课程和固定安排，可导入系统日历。"
    if panel.runModal() == .OK,let url=panel.url { do {try content.write(to:url,atomically:true,encoding:.utf8);model.status="已导出日历文件。"} catch {model.status="导出失败：\(error.localizedDescription)"} }
}


final class CampusLinksDraft:ObservableObject {
    @Published var links:[CampusLink]
    init(_ links:[CampusLink]) { self.links=links }
}
struct CampusLinksView:View {
    @ObservedObject var model:Schedule
    @StateObject var draft:CampusLinksDraft
    init(model:Schedule) {self.model=model;_draft=StateObject(wrappedValue:CampusLinksDraft(model.services))}
    var invalid:Bool {draft.links.contains { link in
        link.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (!link.address.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && validatedCampusURL(link.address)==nil)
    }}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Text("校园服务").font(.title2.bold());Spacer();Button("完成"){model.showServices=false}}
            Text("可添加或修改常用入口；未填写网址的入口会提示设置。链接保存在本机。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing:8) {
                    ForEach($draft.links) { $link in
                        HStack(spacing:8) {
                            TextField("名称",text:$link.name).frame(width:115)
                            TextField("https://…",text:$link.address)
                            Button(role:.destructive) {draft.links.removeAll{$0.id==link.id}} label:{Image(systemName:"trash")}.buttonStyle(.plain).help("移除入口")
                        }
                    }
                }
            }.frame(minHeight:150,maxHeight:320)
            if invalid {Text("请填写入口名称；网址须为完整的 http 或 https 地址。").font(.caption).foregroundStyle(.orange)}
            HStack {
                Button("添加入口"){draft.links.append(CampusLink(name:"",address:""))}
                Spacer()
                Button("取消"){model.showServices=false}
                Button("保存") {
                    model.services=draft.links.map{CampusLink(id:$0.id,name:$0.name.trimmingCharacters(in:.whitespacesAndNewlines),address:$0.address.trimmingCharacters(in:.whitespacesAndNewlines))}
                    model.persist(model.services,key:"campusLinks");model.showServices=false
                }.buttonStyle(.borderedProminent).disabled(invalid)
            }
        }.padding(24).frame(width:570)
    }
}


final class AdjustmentDraft: ObservableObject {
    @Published var day: Date
    @Published var start: Int
    @Published var end: Int
    @Published var place: String
    init(_ meeting: Meeting) { day = meeting.day; start = meeting.start; end = meeting.end; place = meeting.place }
}
struct AdjustmentView: View {
    @ObservedObject var model: Schedule
    let meeting: Meeting
    @StateObject var draft: AdjustmentDraft
    let onClose: (() -> Void)?
    init(model: Schedule, meeting: Meeting, onClose: (() -> Void)? = nil) {
        self.model = model
        self.meeting = meeting
        self.onClose = onClose
        _draft = StateObject(wrappedValue: AdjustmentDraft(meeting))
    }
    private func close() {
        if let onClose { onClose() } else { model.adjustTarget = nil }
    }
    var conflicts: Bool { model.hasConflict(for:meeting,day:draft.day,start:draft.start,end:draft.end) }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { VStack(alignment:.leading,spacing:5) { Text("调整这一次课").font(.title2.bold()); Text(meeting.course.name).foregroundStyle(.secondary) }; Spacer(); Button("关闭") { close() } }
            Text("仅修改应用里的这一次课程，不会更改学校教务系统。教务更新后此调整会保留。").font(.caption).foregroundStyle(.secondary)
            Form {
                DatePicker("上课日期",selection:$draft.day,displayedComponents:.date)
                Picker("开始节次",selection:$draft.start) { ForEach(1...12,id:\.self) { Text("第 \($0) 节").tag($0) } }
                Picker("结束节次",selection:$draft.end) { ForEach(1...12,id:\.self) { Text("第 \($0) 节").tag($0) } }
                TextField("上课地点",text:$draft.place)
            }.formStyle(.grouped)
            if draft.end < draft.start { Text("结束节次不能早于开始节次。").foregroundStyle(.red).font(.caption) }
            if conflicts { Label("与该日的课程或固定安排时间重叠，请检查。",systemImage:"exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
            HStack { if meeting.adjusted { Button("恢复原安排") { model.restore(meeting); close() } }; Spacer(); Button("取消") { close() }; Button(conflicts ? "仍然保存" : "保存调整") { let change = Adjustment(courseID:meeting.course.id,originalDay:meeting.originalDay,targetDay:Calendar.current.startOfDay(for:draft.day),start:draft.start,end:draft.end,place:draft.place.trimmingCharacters(in:.whitespacesAndNewlines)); model.save(change); close() }.buttonStyle(.borderedProminent).disabled(draft.end < draft.start || draft.place.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width:490)
    }
}
struct AdjustmentList: View {
    @ObservedObject var model: Schedule
    @State private var selected: Meeting?
    @State private var week: Int

    init(model: Schedule) {
        self.model = model
        _week = State(initialValue: model.week)
    }

    var body: some View {
        if let selected {
            AdjustmentView(model: model, meeting: selected) { self.selected = nil }
        } else {
            let meetings = model.meetings(in: week)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("管理调课").font(.title2.bold())
                    Spacer()
                    Button("完成") { model.showAdjustments = false }
                }
                HStack {
                    Text("选择要调整的一次课").font(.headline)
                    Spacer()
                    Button { week -= 1 } label: { Image(systemName: "chevron.left") }.disabled(week <= 1)
                    Text("第 \(week) 周").monospacedDigit()
                    Button { week += 1 } label: { Image(systemName: "chevron.right") }
                }
                if meetings.isEmpty { Text("本周暂无课程").foregroundStyle(.secondary) }
                if meetings.isEmpty && model.adjustments.isEmpty { Spacer() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(meetings) { meeting in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(meeting.course.name).font(.headline)
                                    Text("\(meeting.day.formatted(.dateTime.month().day().weekday())) · 第 \(meeting.start)–\(meeting.end) 节")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(meeting.adjusted ? "修改" : "调课") { selected = meeting }
                            }.padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9))
                        }
                        if !model.adjustments.isEmpty {
                            Text("已保存的调整").font(.headline).padding(.top, 8)
                            ForEach(model.adjustments) { change in
                                let course = model.allCourses.first { $0.id == change.courseID }
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(course?.name ?? String(change.courseID.split(separator: "|").first ?? "未匹配课程"))
                                            .font(.headline)
                                        Text("\(change.originalDay.formatted(.dateTime.month().day())) → \(change.targetDay.formatted(.dateTime.month().day()))")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let course {
                                        Button("修改") {
                                            selected = Meeting(course: course, originalDay: change.originalDay,
                                                day: change.targetDay, start: change.start, end: change.end,
                                                place: change.place, adjusted: true)
                                        }
                                    }
                                    Button("恢复") {
                                        model.adjustments.removeAll { $0.id == change.id }
                                        model.persistAdjustments()
                                    }
                                }.padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9))
                            }
                        }
                    }
                }
            }.padding(24).frame(width: 560, height: 460)
        }
    }
}

struct CourseDetail: View {
    @ObservedObject var model: Schedule
    let meeting: Meeting
    @AppStorage("workbenchTheme") private var themeName = WorkbenchTheme.ocean.rawValue
    private let starts = ["08:30","09:25","10:30","11:25","14:00","14:55","16:00","16:55","19:00","19:55","20:50","21:45"]
    private let ends = ["09:15","10:10","11:15","12:10","14:45","15:40","16:45","17:40","19:45","20:40","21:35","22:30"]
    private var theme: WorkbenchTheme { WorkbenchTheme(rawValue: themeName) ?? .ocean }
    private var manual: Bool { model.manualCourses.contains(meeting.course) }
    private var time: String {
        guard (1...12).contains(meeting.start), (1...12).contains(meeting.end) else { return "未设置" }
        return "\(starts[meeting.start - 1])–\(ends[meeting.end - 1]) · 第 \(meeting.start)–\(meeting.end) 节"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(manual ? "手动录入" : "教务课表").font(.caption.weight(.semibold))
                    Spacer()
                    Button { model.editing = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 20))
                            .accessibilityLabel("关闭").frame(width: 28, height: 28)
                    }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                }.foregroundStyle(.white.opacity(0.85))
                Text(meeting.course.name).font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                if meeting.adjusted {
                    Label("已调课", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.caption).foregroundStyle(.white)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(17)
                .background(LinearGradient(colors: theme.banner, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 16))
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 15) {
                detail("日期", icon: "calendar", value: meeting.day.formatted(.dateTime.month().day().weekday(.wide)))
                detail("时间", icon: "clock", value: time)
                detail("地点", icon: "mappin.and.ellipse", value: meeting.place.isEmpty ? "未填写" : meeting.place)
                detail("周次", icon: "rectangle.stack", value: meeting.course.weeks + "周")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(17)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            if let note = model.notes[meeting.course.name], !note.isEmpty {
                Text(note).font(.system(size: 16)).frame(maxWidth: .infinity, alignment: .leading).padding(11)
                    .background(theme.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Menu("更多") {
                    Button("课程备注") { openNext { model.noteTarget = meeting.course } }
                    if manual {
                        Button("编辑课程") { openNext { model.editingManual = meeting.course } }
                        Button("删除课程", role: .destructive) { model.confirmDeleteCourse = true }
                    } else {
                        Button("前往教务") { model.openPortal() }
                    }
                }.fixedSize()
                Spacer()
                Button("调整这一次课") { openNext { model.adjustTarget = meeting } }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 555)
            .background(.regularMaterial).tint(theme.tint)
            .alert("删除整门手动课程？", isPresented: $model.confirmDeleteCourse) {
                Button("删除", role: .destructive) {
                    model.manualCourses.removeAll { $0.id == meeting.course.id }
                    model.adjustments.removeAll { $0.courseID == meeting.course.id }
                    model.persist(model.manualCourses, key: "manualCourses")
                    model.persistAdjustments()
                    model.editing = nil
                }
                Button("取消", role: .cancel) {}
            } message: { Text("该课程的所有周次和手动调整都会删除。") }
    }

    private func detail(_ name: String, icon: String, value: String) -> some View {
        GridRow {
            Label(name, systemImage: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
        }
    }

    private func openNext(_ action: @escaping () -> Void) {
        model.editing = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }
}
final class CourseDraft:ObservableObject { @Published var name=""; @Published var place=""; @Published var weeks="1-18"; @Published var day=1; @Published var start=1; @Published var end=2
    init(_ course:Course? = nil) { if let c=course {name=c.name;place=c.place;weeks=c.weeks;day=c.day;start=c.start;end=c.end} }
}
struct ManualCourseView:View {
    @ObservedObject var model:Schedule
    let existing:Course?
    @StateObject var draft:CourseDraft
    init(model:Schedule,existing:Course? = nil) {self.model=model;self.existing=existing;_draft=StateObject(wrappedValue:CourseDraft(existing))}
    func close() { if existing == nil {model.showManual=false} else {model.editingManual=nil} }
    var validWeeks:Bool { let pieces=draft.weeks.split(separator:",",omittingEmptySubsequences:false); return !pieces.isEmpty && pieces.allSatisfy { p in let x=p.split(separator:"-",omittingEmptySubsequences:false); guard (1...2).contains(x.count), let a=Int(x[0]), (1...60).contains(a) else {return false}; if x.count==1{return true}; guard let b=Int(x[1]),b>=a,b<=60 else{return false};return true } }
    var body:some View { VStack(alignment:.leading,spacing:15) { Text(existing == nil ? "手动添加课程" : "编辑手动课程").font(.title2.bold()); Text("课程周次以首页的第一周周一为起点。").font(.caption).foregroundStyle(.secondary); Form { TextField("课程名称",text:$draft.name); TextField("上课地点",text:$draft.place); TextField("上课周次，例如 1-9,11-18",text:$draft.weeks); Picker("星期",selection:$draft.day){ForEach(1...7,id:\.self){Text("周"+["一","二","三","四","五","六","日"][$0-1]).tag($0)}}; Picker("开始节次",selection:$draft.start){ForEach(1...12,id:\.self){Text("第 \($0) 节").tag($0)}}; Picker("结束节次",selection:$draft.end){ForEach(1...12,id:\.self){Text("第 \($0) 节").tag($0)}} }.formStyle(.grouped); if !validWeeks {Text("周次格式示例：1-9,11-18（范围 1–60）。").font(.caption).foregroundStyle(.orange)}; HStack { Spacer();Button("取消"){close()};Button(existing == nil ? "添加" : "保存"){let c=Course(name:draft.name.trimmingCharacters(in:.whitespacesAndNewlines),weeks:draft.weeks,place:draft.place.trimmingCharacters(in:.whitespacesAndNewlines),day:draft.day,start:draft.start,end:draft.end);if let old=existing,let index=model.manualCourses.firstIndex(of:old) { if !model.allCourses.contains(where:{$0.id==c.id && $0.id != old.id}) { model.manualCourses[index]=c;if old.day == c.day && old.start == c.start && old.end == c.end && old.weeks == c.weeks { model.adjustments=model.adjustments.map { $0.courseID == old.id ? Adjustment(courseID:c.id,originalDay:$0.originalDay,targetDay:$0.targetDay,start:$0.start,end:$0.end,place:$0.place) : $0 };model.persistAdjustments() };model.persist(model.manualCourses,key:"manualCourses") } } else if !model.allCourses.contains(c) {model.manualCourses.append(c);model.persist(model.manualCourses,key:"manualCourses")};close()}.buttonStyle(.borderedProminent).disabled(draft.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || draft.place.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || draft.end<draft.start || !validWeeks) } }.padding(24).frame(width:490) }
}

final class GroupDraft:ObservableObject {
    @Published var title="";@Published var place="";@Published var weekday=1;@Published var start=Calendar.current.date(bySettingHour:14,minute:0,second:0,of:Date())!;@Published var end=Calendar.current.date(bySettingHour:15,minute:0,second:0,of:Date())!;@Published var from=Date();@Published var until=Calendar.current.date(byAdding:.month,value:4,to:Date())!;@Published var editingID:UUID?
    func reset(){title="";place="";weekday=1;start=Calendar.current.date(bySettingHour:14,minute:0,second:0,of:Date())!;end=Calendar.current.date(bySettingHour:15,minute:0,second:0,of:Date())!;from=Date();until=Calendar.current.date(byAdding:.month,value:4,to:Date())!;editingID=nil}
    func edit(_ g:FixedEvent){title=g.title;place=g.place;weekday=g.weekday;start=Calendar.current.date(bySettingHour:g.startHour,minute:g.startMinute,second:0,of:Date())!;end=Calendar.current.date(bySettingHour:g.endHour,minute:g.endMinute,second:0,of:Date())!;from=g.from;until=g.until;editingID=g.id}
}
struct GroupView:View {
    @ObservedObject var model:Schedule
    @StateObject var draft=GroupDraft()
    var validTime:Bool {let a=Calendar.current.dateComponents([.hour,.minute],from:draft.start),b=Calendar.current.dateComponents([.hour,.minute],from:draft.end);return (a.hour ?? 0)*60+(a.minute ?? 0)<(b.hour ?? 0)*60+(b.minute ?? 0)}
    var validDates:Bool {let c=Calendar.current;let a=c.startOfDay(for:draft.from),b=c.startOfDay(for:draft.until);let days=c.dateComponents([.day],from:a,to:b).day ?? -1;return (0...1098).contains(days)}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text("固定安排").font(.title2.bold());Spacer();Button("完成"){model.showGroup=false}}
            Text("例如每周组会；设置生效起止日期，不受课程周次限制。").font(.caption).foregroundStyle(.secondary)
            Form {TextField("名称",text:$draft.title);TextField("地点",text:$draft.place);Picker("每周",selection:$draft.weekday){ForEach(1...7,id:\.self){Text("周"+["一","二","三","四","五","六","日"][$0-1]).tag($0)}};DatePicker("开始时间",selection:$draft.start,displayedComponents:.hourAndMinute);DatePicker("结束时间",selection:$draft.end,displayedComponents:.hourAndMinute);DatePicker("生效日期",selection:$draft.from,displayedComponents:.date);DatePicker("结束日期",selection:$draft.until,displayedComponents:.date)}.formStyle(.grouped)
            if !validTime || !validDates {Text("结束时间须晚于开始时间，日期范围最长为三年。").font(.caption).foregroundStyle(.orange)}
            HStack {Spacer();if draft.editingID != nil {Button("取消编辑"){draft.reset()}};Button(draft.editingID == nil ? "添加固定安排" : "保存修改") {
                let c=Calendar.current,a=c.dateComponents([.hour,.minute],from:draft.start),b=c.dateComponents([.hour,.minute],from:draft.end)
                let item=FixedEvent(id:draft.editingID ?? UUID(),title:draft.title.trimmingCharacters(in:.whitespacesAndNewlines),place:draft.place.trimmingCharacters(in:.whitespacesAndNewlines),weekday:draft.weekday,startHour:a.hour!,startMinute:a.minute!,endHour:b.hour!,endMinute:b.minute!,from:c.startOfDay(for:draft.from),until:c.startOfDay(for:draft.until))
                if let id=draft.editingID,let i=model.groups.firstIndex(where:{$0.id==id}){model.groups[i]=item}else{model.groups.append(item)}
                model.persist(model.groups,key:"groups");draft.reset()
            }.buttonStyle(.borderedProminent).disabled(draft.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !validTime || !validDates)}
            ScrollView {VStack {ForEach(model.groups){g in HStack {VStack(alignment:.leading){Text(g.title).bold();Text("每周\(["一","二","三","四","五","六","日"][g.weekday-1]) \(String(format:"%02d:%02d",g.startHour,g.startMinute)) · \(g.place)").font(.caption).foregroundStyle(.secondary)};Spacer();Button("编辑"){draft.edit(g)}.buttonStyle(.plain).font(.caption);Button(role:.destructive){model.groups.removeAll{$0.id==g.id};model.persist(model.groups,key:"groups");if draft.editingID==g.id{draft.reset()}}label:{Image(systemName:"trash")}.buttonStyle(.plain)}.padding(6);Divider()}}}.frame(maxHeight:130)
        }.padding(24).frame(width:520)
    }
}

final class NoteDraft:ObservableObject { @Published var text:String; init(_ text:String){self.text=text} }
struct CourseNoteView:View {
    @ObservedObject var model:Schedule
    let course:Course
    @StateObject var draft:NoteDraft
    init(model:Schedule,course:Course){self.model=model;self.course=course;_draft=StateObject(wrappedValue:NoteDraft(model.notes[course.name] ?? ""))}
    var body:some View {VStack(alignment:.leading,spacing:12){Text("课程备注").font(.title2.bold());Text(course.name).foregroundStyle(.secondary);TextEditor(text:$draft.text).font(.body).frame(minHeight:150).padding(6).overlay(RoundedRectangle(cornerRadius:8).stroke(Color.gray.opacity(0.25)));HStack{Spacer();Button("取消"){model.noteTarget=nil};Button("保存"){model.notes[course.name]=draft.text;model.persist(model.notes,key:"courseNotes");model.noteTarget=nil}.buttonStyle(.borderedProminent)}}.padding(24).frame(width:480)}
}

