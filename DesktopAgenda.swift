import SwiftUI

struct DesktopAgenda: View {
    @ObservedObject var schedule: Schedule
    let open: () -> Void
    let close: () -> Void

    @AppStorage("workbenchTheme") private var themeName = WorkbenchTheme.ocean.rawValue
    @State private var tomorrow = false
    private let calendar = Calendar.current
    private var theme: WorkbenchTheme { WorkbenchTheme(rawValue: themeName) ?? .ocean }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = calendar.startOfDay(for: context.date)
            let date = calendar.date(byAdding: .day, value: tomorrow ? 1 : 0, to: today) ?? today
            VStack(alignment: .leading, spacing: 0) {
                header(date)
                Rectangle().fill(WorkbenchPalette.line).frame(height: 1)
                agenda(for: date)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(WorkbenchSurface(radius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func header(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("桌面课表", systemImage: "calendar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WorkbenchPalette.ink)
                Spacer()
                panelButton("打开工作台", icon: "arrow.up.right", action: open)
                panelButton("隐藏桌面课表", icon: "xmark", action: close)
            }
            HStack {
                HStack(spacing: 3) {
                    dayButton("今天", next: false)
                    dayButton("明天", next: true)
                }.padding(3)
                    .background(WorkbenchPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                Text(date.formatted(.dateTime.month().day().weekday(.abbreviated)))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WorkbenchPalette.muted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(theme.tint.opacity(0.08))
    }

    private func panelButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .foregroundStyle(WorkbenchPalette.muted).frame(width: 25, height: 25)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).help(label)
    }

    private func dayButton(_ label: String, next: Bool) -> some View {
        Button { tomorrow = next } label: {
            Text(label).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tomorrow == next ? theme.tint : WorkbenchPalette.muted)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(tomorrow == next ? theme.tint.opacity(0.11) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(tomorrow == next ? .isSelected : [])
    }

    private func agenda(for date: Date) -> some View {
        let first = calendar.startOfDay(for: schedule.firstMonday)
        let courses = date < first ? [] : schedule.meetings(in: schedule.weekNumber(for: date))
            .filter { calendar.isDate($0.day, inSameDayAs: date) }
        let tasks = schedule.todos.filter { task in
            guard !task.done, let due = task.due else { return false }
            return calendar.isDate(due, inSameDayAs: date)
        }.sorted { ($0.due ?? date) < ($1.due ?? date) }

        return Group {
            if courses.isEmpty && tasks.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "calendar.badge.checkmark").font(.system(size: 20)).foregroundStyle(theme.tint)
                    Text("暂无安排").font(.system(size: 14, weight: .medium)).foregroundStyle(WorkbenchPalette.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(courses) { course in
                            agendaRow(title: course.course.name, detail: course.place,
                                      when: lessonTime(course.start), icon: "book")
                        }
                        ForEach(tasks) { task in
                            let time = task.hasTime == true ? task.due?.formatted(.dateTime.hour().minute()) : nil
                            agendaRow(title: task.title, detail: "待办", when: time ?? "当天", icon: "checkmark.circle")
                        }
                    }.padding(12)
                }
            }
        }
    }

    private func lessonTime(_ period: Int) -> String {
        guard CampusWeek.starts.indices.contains(period - 1) else { return "第 \(period) 节" }
        let minutes = CampusWeek.starts[period - 1]
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func agendaRow(title: String, detail: String, when: String, icon: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(when).font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.tint).frame(width: 46)
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(theme.tint)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WorkbenchPalette.ink).lineLimit(2)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(WorkbenchPalette.muted).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 8).padding(.vertical, 8)
            .background(WorkbenchPalette.inset.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}
