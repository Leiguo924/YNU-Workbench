import SwiftUI

struct CampusWeek: View {
    @ObservedObject var schedule: Schedule
    @AppStorage("showUpcoming") private var showUpcoming = true
    @AppStorage("showDatedTasks") private var showDatedTasks = true
    @AppStorage("coloredBanner") private var coloredBanner = true
    @AppStorage("workbenchTheme") private var themeName = WorkbenchTheme.ocean.rawValue
    private var theme: WorkbenchTheme { WorkbenchTheme(rawValue: themeName) ?? .ocean }

    var desktopAgendaVisible = false
    var toggleDesktopAgenda: (() -> Void)? = nil
    @State private var mergedEntry: Entry?

    private let days = ["一", "二", "三", "四", "五", "六", "日"]
    private let bands = ["上午", "下午", "晚上"]
    private let times = ["08–12", "14–18", "19–22"]
    static let starts = [510,565,630,685,840,895,960,1015,1140,1195,1250,1305]
    static let ends = [555,610,675,730,885,940,1005,1060,1185,1240,1295,1350]
    private var calendar: Calendar { .current }
    private var monday: Date { date(schedule.week, offset: 0) }

    private func date(_ week: Int, offset: Int) -> Date {
        calendar.date(byAdding: .day, value: (week - 1) * 7 + offset,
                      to: calendar.startOfDay(for: schedule.firstMonday)) ?? schedule.firstMonday
    }

    private struct Entry: Identifiable {
        let id: String
        let day: Int
        let title: String
        let place: String
        let start: Int
        var end: Int
        var meeting: Meeting? = nil
        var task: TodoItem? = nil
        var segments: [Meeting] = []
        var lastPeriod: Int { segments.last?.end ?? meeting?.end ?? 0 }

        var band: Int { start < 12 * 60 + 30 ? 0 : start < 18 * 60 + 30 ? 1 : 2 }
    }

    private func entries() -> [Entry] {
        let meetings = schedule.meetings(in: schedule.week).compactMap { m -> Entry? in
            guard (1...12).contains(m.start), (1...12).contains(m.end),
                  let day = calendar.dateComponents([.day], from: monday, to: m.day).day,
                  (0...6).contains(day) else { return nil }
            return Entry(id: m.id, day: day, title: m.course.name, place: m.place,
                         start: Self.starts[m.start - 1], end: Self.ends[m.end - 1], meeting: m)
        }
        let orderedMeetings = meetings.sorted { lhs, rhs in
            (lhs.day, lhs.title, lhs.place, lhs.start) < (rhs.day, rhs.title, rhs.place, rhs.start)
        }
        var merged: [Entry] = []
        for item in orderedMeetings {
            if let last = merged.last, last.day == item.day, last.band == item.band,
               last.title == item.title, last.place == item.place, let segment = item.meeting,
               segment.start == last.lastPeriod + 1 {
                merged[merged.count - 1].end = item.end
                merged[merged.count - 1].segments.append(segment)
            } else {
                merged.append(item)
            }
        }
        let fixed = schedule.groups.compactMap { event -> Entry? in
            guard (1...7).contains(event.weekday) else { return nil }
            let day = event.weekday - 1
            let target = date(schedule.week, offset: day)
            guard target >= calendar.startOfDay(for: event.from),
                  target <= calendar.startOfDay(for: event.until) else { return nil }
            return Entry(id: event.id.uuidString, day: day, title: event.title, place: event.place,
                         start: event.startHour * 60 + event.startMinute,
                         end: event.endHour * 60 + event.endMinute, meeting: nil)
        }
        let tasks: [Entry] = showDatedTasks ? schedule.todos.compactMap { task in
            guard let due = task.due,
                  let day = calendar.dateComponents([.day], from: monday, to: calendar.startOfDay(for: due)).day,
                  days.indices.contains(day) else { return nil }
            let start = task.hasTime == true
                ? calendar.component(.hour, from: due) * 60 + calendar.component(.minute, from: due)
                : Self.starts[0]
            return Entry(id: task.id.uuidString, day: day, title: task.title, place: "",
                         start: start, end: start, task: task)
        } : []
        return (merged + fixed + tasks).sorted { $0.start < $1.start }
    }

    var body: some View {
        let items = entries()
        let courseNames = Set(schedule.allCourses.map(\.name)).sorted()
        let colorIndex = Dictionary(uniqueKeysWithValues: courseNames.enumerated().map { ($0.element, $0.offset) })
        VStack(alignment: .leading, spacing: 13) {
            header
            if showUpcoming {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    upcoming(now: context.date)
                }
            }
            weekNavigation
            if items.isEmpty {
                emptyWeek
            } else {
                GeometryReader { geometry in
                    let occupied = Set(items.map(\.day))
                    let available = max(1, geometry.size.width - 62)
                    let weights: [CGFloat] = days.indices.map { occupied.contains($0) ? 1.55 : 1.0 }
                    let total = weights.reduce(0, +)
                    let widths = weights.map { available * $0 / total }
                    let counts = bands.indices.map { band in
                        days.indices.map { day in items.filter { $0.band == band && $0.day == day }.count }.max() ?? 0
                    }
                    let baseHeights = counts.map { $0 == 0 ? 46 : max(92, CGFloat($0) * 83) }
                    let spare = max(0, geometry.size.height - 41 - baseHeights.reduce(0, +))
                    let nonempty = max(1, counts.filter { $0 > 0 }.count)
                    VStack(alignment: .leading, spacing: 0) {
                        weekdayHeader(widths: widths, leading: 62)
                        Rectangle().fill(WorkbenchPalette.line).frame(height: 1).padding(.leading, 62)
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(bands.indices, id: \.self) { band in
                                    bandRow(band, items: items, widths: widths, colors: colorIndex,
                                            height: baseHeights[band] + (counts[band] == 0 ? 0 : spare / CGFloat(nonempty)))
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 12).fill(WorkbenchPalette.surface)
                            .padding(.leading, 62)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(WorkbenchPalette.line)
                            .padding(.leading, 62).allowsHitTesting(false)
                    }
                }
            }
        }.padding(22)
        .sheet(item: $mergedEntry) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text(item.title).font(.title2.weight(.semibold))
                Text("\(clock(item.start))–\(clock(item.end))  ·  \(item.place)")
                    .foregroundStyle(.secondary)
                ForEach([item.meeting].compactMap { $0 } + item.segments) { segment in
                    Button("查看第 \(segment.start)–\(segment.end) 节") {
                        mergedEntry = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { schedule.editing = segment }
                    }
                }
                Button("关闭") { mergedEntry = nil }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 390, alignment: .leading)
        }
    }

    private var emptyWeek: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width / CGFloat(days.count))
            VStack(spacing: 0) {
                weekdayHeader(widths: Array(repeating: width, count: days.count), leading: 0)
                Rectangle().fill(WorkbenchPalette.line).frame(height: 1)
                VStack(spacing: 9) {
                    Image(systemName: "calendar").font(.system(size: 22, weight: .medium))
                        .foregroundStyle(theme.tint)
                        .frame(width: 46, height: 46)
                        .background(theme.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                    Text("本周暂无安排").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(WorkbenchPalette.ink)
                    if schedule.allCourses.isEmpty {
                        Button("导入课表") { schedule.showImport = true }
                            .buttonStyle(WorkbenchButton(kind: .secondary, tint: theme.tint))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.modifier(WorkbenchSurface(radius: 12))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("课程表").font(.system(size: 27, weight: .semibold)).foregroundStyle(WorkbenchPalette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let toggleDesktopAgenda {
                Button(action: toggleDesktopAgenda) {
                    Image(systemName: "macwindow").font(.system(size: 16))
                        .frame(width: 34, height: 32)
                }.buttonStyle(.plain)
                    .foregroundStyle(desktopAgendaVisible ? theme.tint : .secondary)
                    .accessibilityLabel(desktopAgendaVisible ? "隐藏桌面课表" : "显示桌面课表")
                    .help(desktopAgendaVisible ? "隐藏桌面课表" : "显示桌面课表")
            }
            Menu {
                Button("手动添加课程") { schedule.showManual = true }
                Button("添加固定安排") { schedule.showGroup = true }
                Button("添加待办事项") { schedule.openTodo() }
            } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32).accessibilityLabel("添加")
                    .background(theme.tint.opacity(0.085), in: RoundedRectangle(cornerRadius: 7))
            }.menuStyle(.borderlessButton).fixedSize()
            Button { schedule.showImport = true } label: {
                Label("导入课表", systemImage: "arrow.down.to.line")
            }.buttonStyle(WorkbenchButton(kind: .primary, tint: theme.tint))

        }
    }

    private var weekNavigation: some View {
        let now = Date()
        let isCurrentWeek = now >= monday && now < date(schedule.week, offset: 7)
        return HStack(spacing: 10) {
            Text("第 \(schedule.week) 周").font(.system(size: 15, weight: .semibold)).monospacedDigit()
            Text("\(monday.formatted(.dateTime.month().day())) – \(date(schedule.week, offset: 6).formatted(.dateTime.month().day()))")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 0) {
                Button { schedule.week = max(1, schedule.week - 1) } label: {
                    Image(systemName: "chevron.left").frame(width: 32, height: 32)
                }.help("上一周").disabled(schedule.week <= 1)
                Button { schedule.goToday() } label: {
                    Text(isCurrentWeek ? "本周" : "第 \(schedule.week) 周")
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .frame(minWidth: 66, minHeight: 32)
                }.help("返回本周")
                Button { schedule.week += 1 } label: {
                    Image(systemName: "chevron.right").frame(width: 32, height: 32)
                }.help("下一周")
            }.buttonStyle(.plain).modifier(WorkbenchSurface(radius: 8))
        }
    }

    private func weekdayHeader(widths: [CGFloat], leading: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leading, height: 40)
            ForEach(days.indices, id: \.self) { day in
                let target = date(schedule.week, offset: day)
                let today = calendar.isDateInToday(target)
                HStack(spacing: 6) {
                    Text("周" + days[day]).font(.system(size: 13, weight: .medium))
                    Text("\(calendar.component(.day, from: target))")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(today ? theme.tint : WorkbenchPalette.muted)
                }.frame(width: widths[day], height: 40)
                    .foregroundStyle(WorkbenchPalette.ink)
                    .background(today ? theme.tint.opacity(0.07) : .clear)
            }
        }.frame(height: 40)
            .background(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(WorkbenchPalette.inset.opacity(0.45)).padding(.leading, leading)
            }
    }

    private func bandRow(_ band: Int, items: [Entry], widths: [CGFloat], colors: [String: Int], height: CGFloat) -> some View {
        let matching = items.filter { $0.band == band }
        let cells = days.indices.map { day in matching.filter { $0.day == day } }
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(bands[band]).font(.system(size: 13, weight: .semibold))
                Text(times[band]).font(.system(size: 11).monospacedDigit()).foregroundStyle(WorkbenchPalette.muted)
            }.foregroundStyle(WorkbenchPalette.muted)
                .padding(.top, 8).frame(width: 62, alignment: .topLeading)
            ForEach(days.indices, id: \.self) { day in
                let cellItems = cells[day]
                let innerHeight = max(1, height - 8)
                let placements = placements(for: cellItems, band: band, height: innerHeight)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(cellItems.indices, cellItems)), id: \.1.id) { index, item in
                        let slot = placements[index]
                        card(item, index: colors[item.title] ?? 0, height: slot.height)
                            .offset(y: slot.top)
                    }
                }
                .frame(width: max(1, widths[day] - 8), height: innerHeight, alignment: .topLeading)
                .padding(4)
                .clipped()
                .background(calendar.isDateInToday(date(schedule.week, offset: day))
                            ? theme.tint.opacity(0.035) : .clear)
                .overlay(alignment: .leading) {
                    Rectangle().fill(WorkbenchPalette.line.opacity(0.72)).frame(width: 1)
                        .allowsHitTesting(false)
                }
            }
        }.overlay(alignment: .bottom) {
            if band < bands.count - 1 {
                Rectangle().fill(WorkbenchPalette.line.opacity(0.82)).frame(height: 1)
                    .padding(.leading, 62).allowsHitTesting(false)
            }
        }
    }

    private func placements(for items: [Entry], band: Int, height: CGFloat) -> [(top: CGFloat, height: CGFloat)] {
        let bounds = [(510, 730), (840, 1060), (1140, 1350)][band]
        let span = CGFloat(bounds.1 - bounds.0)
        let gap: CGFloat = 4
        let lateSingle = items.count == 1 && CGFloat((items.first?.start ?? bounds.0) - bounds.0) / span >= 0.35
        let singleMinimum = lateSingle ? height * 0.75 : min(64, height * 0.70)
        let minimum = items.count == 1 ? singleMinimum : min(62, height / CGFloat(max(1, items.count)) - gap)
        var occupied: CGFloat = 0
        return items.enumerated().map { index, item in
            let remaining = CGFloat(items.count - index - 1)
            let limit = height - remaining * (minimum + gap)
            let preferredTop = height * CGFloat(max(0, item.start - bounds.0)) / span
            let preferredEnd = height * CGFloat(max(0, item.end - bounds.0)) / span
            let top = min(max(occupied, preferredTop), max(occupied, limit - minimum))
            let size = min(limit - top, max(minimum, preferredEnd - top))
            occupied = top + size + gap
            return (top, size)
        }
    }

    private func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    private struct CourseColor {
        let background: Color
        let border: Color
        let text: Color

        init(light: UInt32, dark: UInt32, accent: UInt32, lightText: UInt32, darkText: UInt32) {
            background = WorkbenchPalette.adaptive(light: light, dark: dark)
            border = WorkbenchPalette.adaptive(light: accent, dark: accent)
            text = WorkbenchPalette.adaptive(light: lightText, dark: darkText)
        }
    }

    private static let courseColors = [
        CourseColor(light: 0xdce6ff, dark: 0x2d3b63, accent: 0x6689d6, lightText: 0x293e75, darkText: 0xdce6ff),
        CourseColor(light: 0xd1eee5, dark: 0x25453f, accent: 0x419c89, lightText: 0x195249, darkText: 0xd4f2e9),
        CourseColor(light: 0xeadff9, dark: 0x473555, accent: 0xa276bf, lightText: 0x59366f, darkText: 0xf0dfff),
        CourseColor(light: 0xd4eaf9, dark: 0x284457, accent: 0x548fb2, lightText: 0x254b65, darkText: 0xd8edff),
        CourseColor(light: 0xf8e1e4, dark: 0x553940, accent: 0xbd7481, lightText: 0x723b47, darkText: 0xffe1e8)
    ]

    private func card(_ item: Entry, index: Int, height: CGFloat) -> some View {
        let course = item.meeting == nil ? nil : Self.courseColors[index % Self.courseColors.count]
        let tint = item.task.map { $0.done ? Color.teal : $0.overdue ? .red : theme.tint } ?? .orange
        let titleInk = course?.text ?? WorkbenchPalette.ink
        let detailInk = course?.text.opacity(0.83) ?? WorkbenchPalette.muted
        let timeLabel = item.task.map { $0.hasTime == true ? clock(item.start) : "当天" }
            ?? "\(clock(item.start))–\(clock(item.end))"
        let displayTitle = item.meeting == nil ? item.title
            : item.title.replacingOccurrences(of: #"\s*\[\d+\]$"#, with: "", options: .regularExpression)
        return Button {
            if let task = item.task { schedule.openTodo(task) }
            else if let meeting = item.meeting {
                if item.segments.isEmpty { schedule.editing = meeting }
                else { mergedEntry = item }
            }
            else { schedule.showGroup = true }
        } label: {
            VStack(alignment: .center, spacing: 3) {
                Text(displayTitle).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(titleInk)
                    .strikethrough(item.task?.done == true)
                    .lineLimit(height >= 74 ? 2 : 1)
                Text(item.task == nil ? timeLabel : "待办 · " + timeLabel)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(detailInk).lineLimit(1).minimumScaleFactor(0.84)
                if height >= 66 && !item.place.isEmpty {
                    Text(item.place).font(.system(size: 12)).foregroundStyle(detailInk).lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            .background(course?.background ?? tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7).strokeBorder((course?.border ?? tint).opacity(0.65)).allowsHitTesting(false)
            }
        }.buttonStyle(.plain)
            .accessibilityLabel([item.title, timeLabel, item.place].filter { !$0.isEmpty }.joined(separator: " · "))
            .help([item.title, timeLabel, item.place].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    static func dayLabel(_ date: Date, relativeTo today: Date, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: today)
        let target = calendar.startOfDay(for: date)
        let daysUntil = calendar.dateComponents([.day], from: start, to: target).day ?? 0
        switch daysUntil {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default:
            let todayIndex = (calendar.component(.weekday, from: start) + 5) % 7
            let targetIndex = (calendar.component(.weekday, from: target) + 5) % 7
            let weekday = "周" + ["一", "二", "三", "四", "五", "六", "日"][targetIndex]
            let offset = todayIndex + daysUntil
            if (0..<7).contains(offset) { return weekday }
            if (7..<14).contains(offset) { return "下" + weekday }
            return date.formatted(.dateTime.month().day())
        }
    }

    private func upcoming(now: Date) -> some View {
        let current = max(1, schedule.weekNumber(for: now))
        let candidate = (current...current + 2).lazy.flatMap { schedule.meetings(in: $0) }.first { meeting in
            guard (1...12).contains(meeting.end) else { return false }
            return calendar.date(byAdding: .minute, value: Self.ends[meeting.end - 1], to: meeting.day) ?? meeting.day > now
        }
        let mainInk = coloredBanner ? Color.white : WorkbenchPalette.ink
        let detailInk = coloredBanner ? Color.white.opacity(0.83) : WorkbenchPalette.muted
        return Group {
            if let meeting = candidate, (1...12).contains(meeting.start) {
                Button { schedule.editing = meeting } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock").font(.system(size: 15, weight: .medium))
                            .foregroundStyle(coloredBanner ? .white : theme.tint).frame(width: 33, height: 33)
                            .background(coloredBanner ? Color.white.opacity(0.18) : theme.tint.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("接下来").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(detailInk)
                            Text(meeting.course.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(Self.dayLabel(meeting.day, relativeTo: now))  \(clock(Self.starts[meeting.start - 1]))")
                                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            if !meeting.place.isEmpty {
                                Text(meeting.place).font(.system(size: 12)).foregroundStyle(detailInk).lineLimit(1)
                            }
                        }.fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(detailInk)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(mainInk)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: 10)
                        if coloredBanner {
                            shape.fill(LinearGradient(colors: theme.bannerColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        } else {
                            shape.fill(WorkbenchPalette.surface)
                            shape.strokeBorder(WorkbenchPalette.line)
                        }
                    }
                }.buttonStyle(.plain)
            }
        }
    }
}
