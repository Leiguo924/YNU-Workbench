import AppKit
import SwiftUI

struct CampusOfficeView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("workbenchTheme") private var themeName = WorkbenchTheme.ocean.rawValue
    @State private var query = ""
    @State private var category: CampusOfficeCategory?
    @State private var selectedID: CampusOfficeService.ID?
    @FocusState private var searchFocused: Bool

    private var theme: WorkbenchTheme { WorkbenchTheme(rawValue: themeName) ?? .ocean }

    private var results: [CampusOfficeService] {
        let words = query.split(whereSeparator: \.isWhitespace)
        var directMatches: [CampusOfficeService] = []
        var materialMatches: [CampusOfficeService] = []
        for service in CampusOfficeDirectory.services where category == nil || service.category == category {
            if service.matches(words, includingMaterials: false) {
                directMatches.append(service)
            } else if service.matches(words) {
                materialMatches.append(service)
            }
        }
        return directMatches + materialMatches
    }

    var body: some View {
        let visible = results
        let selected = visible.first { $0.id == selectedID } ?? visible.first

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("办事速查")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(WorkbenchPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(WorkbenchButton(kind: .secondary, tint: theme.tint))
                    .keyboardShortcut(.cancelAction)
            }
            searchField
            HStack {
                categoryBar
                Spacer()
                Text("\(visible.count) 项")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(WorkbenchPalette.muted)
            }
            if let selected {
                HStack(alignment: .top, spacing: 12) {
                    resultList(visible, selected: selected.id).id(category)
                    let related = selected.relatedIDs.compactMap { id in
                        CampusOfficeDirectory.services.first { $0.id == id }
                    }
                    CampusOfficeDetail(service: selected, related: related, tint: theme.tint) { id in
                        if !visible.contains(where: { $0.id == id }) {
                            query = ""
                            category = nil
                        }
                        selectedID = id
                    }
                    .id(selected.id)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 23))
                    Text("没有找到相关事项")
                        .font(.system(size: 16, weight: .semibold))
                    Button("清除筛选") {
                        query = ""
                        category = nil
                        searchFocused = true
                    }
                    .buttonStyle(WorkbenchButton(kind: .secondary, tint: theme.tint))
                }
                .foregroundStyle(WorkbenchPalette.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(WorkbenchSurface(radius: 12))
            }
        }
        .padding(22)
        .frame(width: 720, height: 560)
        .background(WorkbenchPalette.canvas)
        .onAppear { searchFocused = true }
    }

    private var categoryBar: some View {
        HStack(spacing: 3) {
            categoryButton(nil, title: "全部")
            ForEach(CampusOfficeCategory.allCases) { item in
                categoryButton(item, title: item.rawValue)
            }
        }
        .fixedSize()
        .padding(4)
        .background(WorkbenchPalette.inset, in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("事项类别")
    }

    private func categoryButton(_ item: CampusOfficeCategory?, title: String) -> some View {
        let selected = category == item
        return Button {
            guard !selected else { return }
            selectedID = nil
            category = item
        } label: {
            Text(title)
                .font(.system(size: 14, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? theme.tint : WorkbenchPalette.ink)
                .frame(width: 82, height: 32)
                .background(selected ? WorkbenchPalette.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? theme.tint.opacity(0.25) : .clear)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WorkbenchPalette.muted)
                .accessibilityHidden(true)
            TextField("搜索事项、校区或部门", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("查找办事事项")
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(WorkbenchPalette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .font(.system(size: 14))
        .padding(11)
        .modifier(WorkbenchSurface(radius: 9))
    }

    private func resultList(_ visible: [CampusOfficeService], selected: CampusOfficeService.ID) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(visible) { service in
                        resultRow(service, selected: service.id == selected).id(service.id)
                    }
                }.padding(6)
            }
            .onChange(of: selected) { id in
                proxy.scrollTo(id)
            }
        }
        .frame(width: 216)
        .frame(maxHeight: .infinity)
        .modifier(WorkbenchSurface(radius: 12))
    }

    private func resultRow(_ service: CampusOfficeService, selected: Bool) -> some View {
        Button {
            selectedID = service.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: service.category.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.tint)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WorkbenchPalette.ink)
                    Text(service.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(WorkbenchPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(selected ? theme.tint.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CampusOfficeDetail: View {
    let service: CampusOfficeService
    let related: [CampusOfficeService]
    let tint: Color
    let openService: (CampusOfficeService.ID) -> Void

    @State private var copiedValue: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                introduction
                Divider()
                materials
                if !service.steps.isEmpty {
                    Divider()
                    steps
                }
                Divider()
                contacts
                if !service.references.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        heading("学校指南与表单")
                        ForEach(service.references) { reference in
                            referenceLink(reference)
                        }
                    }
                }
                if !related.isEmpty {
                    Divider()
                    relatedServices
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .foregroundStyle(WorkbenchPalette.ink)
        .modifier(WorkbenchSurface(radius: 12))
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(service.title)
                .font(.system(size: 22, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(service.directions)
                .font(.system(size: 14))
                .foregroundStyle(WorkbenchPalette.muted)
                .lineSpacing(3)
            Link(destination: service.entry.url) {
                Label(service.entry.title, systemImage: "arrow.up.right")
            }
            .buttonStyle(WorkbenchButton(kind: .primary, tint: tint))
        }
    }

    private var materials: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                heading("准备材料")
                Spacer()
                Button(copiedValue == "materials" ? "已复制" : "复制清单") {
                    let checklist = service.materials.map { "• \($0)" }.joined(separator: "\n")
                    copy("\(service.title)\n\(checklist)", feedback: "materials")
                }
                .buttonStyle(WorkbenchButton(kind: .secondary, tint: tint))
            }
            ForEach(service.materials, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(tint).accessibilityHidden(true)
                    Text(item).lineSpacing(2)
                }
                .font(.system(size: 14))
            }
        }
    }

    private var contacts: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("联系谁")
            ForEach(service.contacts) { contact in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contact.name)
                            .font(.system(size: 14, weight: .medium))
                        if let location = contact.location {
                            Text(location)
                                .font(.system(size: 13))
                                .foregroundStyle(WorkbenchPalette.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    if let phone = contact.phone {
                        Button {
                            copy(phone, feedback: phone)
                        } label: {
                            Label(copiedValue == phone ? "已复制电话" : phone, systemImage: "document.on.document")
                                .monospacedDigit()
                        }
                        .buttonStyle(WorkbenchButton(kind: .secondary, tint: tint))
                        .help("复制办公电话")
                    }
                }
            }
            ForEach(contactDirectories) { directory in
                referenceLink(directory)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("办理步骤")
            ForEach(Array(service.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("\(index + 1).")
                        .foregroundStyle(tint)
                        .monospacedDigit()
                    Text(step).lineSpacing(2)
                }
                .font(.system(size: 14))
            }
        }
    }

    private var relatedServices: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("相关事项")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(related) { item in
                    Button { openService(item.id) } label: {
                        Label(item.title, systemImage: "arrow.right")
                    }
                    .buttonStyle(WorkbenchButton(kind: .secondary, tint: tint))
                }
            }
        }
    }

    private var contactDirectories: [CampusOfficeLink] {
        var seen = Set<URL>()
        return service.contacts.compactMap(\.directory).filter { seen.insert($0.url).inserted }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private func referenceLink(_ link: CampusOfficeLink) -> some View {
        Link(destination: link.url) {
            Label(link.title, systemImage: "arrow.up.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
        }
    }

    private func copy(_ value: String, feedback: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = feedback
    }
}
