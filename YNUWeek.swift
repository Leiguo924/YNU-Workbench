import SwiftUI

struct CampusWeek: View {
    @ObservedObject var schedule: Schedule
    @AppStorage("showUpcoming") private var showUpcoming = true
    @AppStorage("showDatedTasks") private var showDatedTasks = true
    @AppStorage("coloredBanner") private var coloredBanner = true
    @AppStorage("workbenchTheme") private var themeName = WorkbenchTheme.ocean.rawValue
    private var theme: WorkbenchTheme { WorkbenchTheme(rawValue: themeName) ?? .ocean }

    @State private var mergedEntry: Entry?

    private let days = ["一", "二", "三", "四", "五", "六", "日"]
    private let bands = ["上午", "下午", "晚上"]
    private let times = ["08–12", "14–18", "19–22"]
    private let starts = [510,565,630,685,840,895,960,1015,1140,1195,1250,1305]
    private let ends = [555,610,675,730,885,940,1005,1060,1185,1240,1295,1350]
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
                         start: starts[m.start - 1], end: ends[m.end - 1], meeting: m)
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
                : starts[0]
            return Entry(id: task.id.uuidString, day: day, title: task.title, place: "",
                         start: start, end: start, task: task)
        } : []
        return (merged + fixed + tasks).sorted { $0.start < $1.start }
    }

    var body: some View {
        let items = entries()
        let courseNames = Set(schedule.allCourses.map(\.name)).sorted()
        let colorIndex = Dictionary(uniqueKeysWithValues: courseNames.enumerated().map { ($0.element, $0.offset) })
        VStack(alignment: .leading, spacing: 15) {
            header
            if showUpcoming {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    upcoming(now: context.date)
                }
            }
            weekNavigation
            GeometryReader { geometry in
                let occupied = Set(items.map(\.day))
                let available = max(1, geometry.size.width - 81)
                let weights: [CGFloat] = days.indices.map { occupied.contains($0) ? 1.6 : 1.0 }
                let total = weights.reduce(0, +)
                let widths = weights.map { available * $0 / total }
                let counts = bands.indices.map { band in
                    days.indices.map { day in items.filter { $0.band == band && $0.day == day }.count }.max() ?? 0
                }
                let baseHeights = counts.map { $0 == 0 ? 36 : max(92, CGFloat($0) * 83) }
                let headerSpace: CGFloat = 38
                let spare = max(0, geometry.size.height - headerSpace - 15 - baseHeights.reduce(0, +))
                let nonempty = max(1, counts.filter { $0 > 0 }.count)
                VStack(alignment: .leading, spacing: 8) {
                    weekdayHeader(widths: widths)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(bands.indices, id: \.self) { band in
                                bandRow(band, items: items, widths: widths, colors: colorIndex,
                                        height: baseHeights[band] + (counts[band] == 0 ? 0 : spare / CGFloat(nonempty)))
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            }
            if items.isEmpty {
                HStack(spacing: 11) {
                    Image(systemName: "calendar.badge.plus").font(.system(size: 19))
                    Text(schedule.allCourses.isEmpty ? schedule.status : "本周暂无安排")
                        .font(.callout)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
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

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("课程表").font(.system(size: 29, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button("手动添加课程") { schedule.showManual = true }
                Button("添加固定安排") { schedule.showGroup = true }
                Button("添加待办事项") { schedule.openTodo() }
            } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32).accessibilityLabel("添加")
                    .background(theme.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }.menuStyle(.borderlessButton).fixedSize()
            Button { schedule.showImport = true } label: {
                Label("导入课表", systemImage: "arrow.down.to.line")
                    .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 11).frame(height: 32)
                    .background(theme.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)

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
            }.buttonStyle(.plain).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func weekdayHeader(widths: [CGFloat]) -> some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 46)
            ForEach(days.indices, id: \.self) { day in
                let target = date(schedule.week, offset: day)
                let today = calendar.isDateInToday(target)
                HStack(spacing: 4) {
                    Text("周" + days[day]).font(.system(size: 13, weight: .semibold))
                    Text("\(calendar.component(.day, from: target))")
                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(today ? Color.teal : .secondary)
                }.frame(width: widths[day], height: 25)
                    .background(today ? Color.teal.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
            }
        }.frame(height: 25)
    }

    private func bandRow(_ band: Int, items: [Entry], widths: [CGFloat], colors: [String: Int], height: CGFloat) -> some View {
        let matching = items.filter { $0.band == band }
        let cells = days.indices.map { day in matching.filter { $0.day == day } }
        return HStack(alignment: .top, spacing: 5) {
            VStack(alignment: .leading, spacing: 4) {
                Text(bands[band]).font(.system(size: 13, weight: .semibold))
                Text(times[band]).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }.frame(width: 46, alignment: .leading).padding(.top, 9)
            ForEach(days.indices, id: \.self) { day in
                let cellItems = cells[day]
                let placements = placements(for: cellItems, band: band, height: max(1, height - 6))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(cellItems.indices, cellItems)), id: \.1.id) { index, item in
                        let slot = placements[index]
                        card(item, index: colors[item.title] ?? 0, height: slot.height)
                            .offset(y: slot.top)
                    }
                }
                .frame(width: max(1, widths[day] - 6), height: max(1, height - 6), alignment: .topLeading)
                .padding(3)
                .clipped()
                .background(calendar.isDateInToday(date(schedule.week, offset: day))
                            ? Color.teal.opacity(0.06) : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 7))
            }
        }.padding(.bottom, 5)
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

    private func card(_ item: Entry, index: Int, height: CGFloat) -> some View {
        let hue = (0.52 + Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1)
        let courseTint = item.meeting == nil ? Color.orange : Color(hue: hue, saturation: 0.78, brightness: 0.80)
        let tint = item.task.map { $0.done ? Color.teal : $0.overdue ? .red : .accentColor } ?? courseTint
        let timeLabel = item.task.map { $0.hasTime == true ? clock(item.start) : "当天" }
            ?? "\(clock(item.start))–\(clock(item.end))"
        return Button {
            if let task = item.task { schedule.openTodo(task) }
            else if let meeting = item.meeting {
                if item.segments.isEmpty { schedule.editing = meeting }
                else { mergedEntry = item }
            }
            else { schedule.showGroup = true }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.task == nil ? timeLabel : "待办 · " + timeLabel)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.84)
                    .foregroundStyle(.primary.opacity(0.72))
                Text(item.title).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.88))
                    .strikethrough(item.task?.done == true).lineLimit(height >= 68 ? 2 : 1)
                if height >= 61 && !item.place.isEmpty {
                    Text(item.place).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height, alignment: .topLeading)
            .clipped()
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                Capsule().fill(tint).frame(width: 2).padding(.vertical, 5)
            }
        }.buttonStyle(.plain)
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
            return calendar.date(byAdding: .minute, value: ends[meeting.end - 1], to: meeting.day) ?? meeting.day > now
        }
        return Group {
            if let meeting = candidate, (1...12).contains(meeting.start) {
                Button { schedule.editing = meeting } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "clock").font(.system(size: 18, weight: .medium))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("接下来").font(.system(size: 13, weight: .medium)).opacity(0.85)
                            Text(meeting.course.name).font(.system(size: 21, weight: .semibold)).lineLimit(1)
                        }
                        Spacer()
                        Text("\(Self.dayLabel(meeting.day, relativeTo: now))  \(clock(starts[meeting.start - 1]))")
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        if !meeting.place.isEmpty { Text(meeting.place).font(.system(size: 16, weight: .medium)).lineLimit(1) }
                        Image(systemName: "chevron.right").font(.system(size: 13))
                    }
                    .padding(.horizontal, 17).padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        if coloredBanner {
                            RoundedRectangle(cornerRadius: 16).fill(LinearGradient(
                                colors: theme.banner,
                                startPoint: .leading, endPoint: .trailing))
                        }
                    }
                    .foregroundStyle(coloredBanner ? Color.white : Color.primary)
                    .modifier(WorkbenchGlass(radius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)))
                }.buttonStyle(.plain)
            }
        }
    }
}
