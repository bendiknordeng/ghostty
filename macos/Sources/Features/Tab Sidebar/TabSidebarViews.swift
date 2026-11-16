import SwiftUI

/// Claude's brand orange, used for the Claude avatar and working indicator.
private let claudeColor = Color(red: 0.85, green: 0.47, blue: 0.34)

/// Horizontal space each tree level is indented by.
private let treeIndent: CGFloat = 16

struct TabSidebarView: View {
    @ObservedObject var model: TabSidebarModel

    var body: some View {
        VStack(spacing: 0) {
            TabSidebarHeader(model: model)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if model.isGrouped {
                        ForEach(model.sections) { section in
                            TabSidebarSectionView(model: model, section: section)
                        }
                    } else {
                        ForEach(model.filteredTabs) { tab in
                            TabCard(model: model, tab: tab)
                        }
                    }

                    if model.filteredTabs.isEmpty {
                        Text(model.query.isEmpty ? "No tabs" : "No matching tabs")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .background(.regularMaterial)
    }
}

private struct TabSidebarHeader: View {
    @ObservedObject var model: TabSidebarModel

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("Search tabs…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            if model.isGrouped {
                TabSidebarIconButton(
                    systemImage: model.canCollapseAll ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                    help: model.canCollapseAll ? "Collapse All" : "Expand All",
                    action: model.toggleCollapseAll)
            }

            TabSidebarIconButton(
                systemImage: model.isGrouped ? "list.bullet.indent" : "list.bullet",
                help: model.isGrouped ? "Show as List" : "Group by Project and Issue",
                action: model.toggleGrouping)

            TabSidebarIconButton(systemImage: "plus", help: "New Tab", action: model.newTab)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

private struct TabSidebarIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isHovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

// MARK: Tree

/// A collapsible tree node: a header row with a chevron and its children indented
/// below it, joined by a thin guide line.
private struct TreeNode<Label: View, Children: View>: View {
    @ObservedObject var model: TabSidebarModel
    let id: String
    let label: Label
    let children: Children

    @State private var isHovering = false

    private var isExpanded: Bool { !model.isCollapsed(id) }

    init(
        model: TabSidebarModel,
        id: String,
        @ViewBuilder label: () -> Label,
        @ViewBuilder children: () -> Children
    ) {
        self.model = model
        self.id = id
        self.label = label()
        self.children = children()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                model.toggleCollapsed(id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 12)

                    label
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(isHovering ? 0.05 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    children
                }
                .padding(.leading, treeIndent)
                .overlay(alignment: .leading) {
                    // Line up the guide with the center of the chevron above.
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)
                        .padding(.leading, 9.5)
                        .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct TabSidebarSectionView: View {
    @ObservedObject var model: TabSidebarModel
    let section: TabSidebarSection

    var body: some View {
        TreeNode(model: model, id: section.id) {
            if section.isLinearProject {
                RoundedRectangle(cornerRadius: 3)
                    .fill(section.color ?? .secondary)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text(section.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            TreeCount(count: section.tabCount)
        } children: {
            ForEach(section.groups) { group in
                if group.issueKey != nil {
                    TabSidebarIssueNode(model: model, group: group)
                } else {
                    ForEach(group.tabs) { tab in
                        TabCard(model: model, tab: tab)
                    }
                }
            }
        }
    }
}

private struct TabSidebarIssueNode: View {
    @ObservedObject var model: TabSidebarModel
    let group: TabSidebarSection.Group

    var body: some View {
        TreeNode(model: model, id: group.id) {
            Circle()
                .strokeBorder(Color(linearHex: group.issue?.stateColor) ?? .secondary, lineWidth: 1.5)
                .frame(width: 10, height: 10)

            Text(group.issueKey ?? "")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()

            if let title = group.issue?.title {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if group.tabs.count > 1 {
                TreeCount(count: group.tabs.count)
            }
        } children: {
            ForEach(group.tabs) { tab in
                TabCard(model: model, tab: tab, showsIssue: false)
            }
        }
        .help(group.issue.map { "\($0.identifier) · \($0.stateName)\n\($0.title)" } ?? (group.issueKey ?? ""))
    }
}

private struct TreeCount: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.tertiary)
    }
}

// MARK: Card

private struct TabCard: View {
    @ObservedObject var model: TabSidebarModel
    let tab: TabInfo
    var showsIssue: Bool = true

    @State private var isHovering = false

    private var isSelected: Bool { model.selectedID == tab.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TabAvatar(agent: tab.agent, needsAttention: tab.needsAttention)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tab.title)
                        .font(.system(size: 12, weight: tab.needsAttention ? .bold : .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    trailingAccessory
                }

                if let pwd = tab.displayPwd {
                    Text(pwd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                metadataRow
                statusRow
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(backgroundOpacity)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { model.select(tab.id) }
        .onHover { isHovering = $0 }
        .contextMenu {
            if tab.issue?.url != nil {
                Button("Open \(tab.issueKey ?? "Issue") in Linear") { model.openIssue(tab) }
            }
            if let pwd = tab.pwd {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pwd, forType: .string)
                }
            }
            Divider()
            Button("Close Tab") { model.close(tab.id) }
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if isHovering {
            Button {
                model.close(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close Tab")
        } else if let shortcut = tab.shortcut {
            Text(shortcut)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var metadataRow: some View {
        let issueKey = showsIssue ? tab.issueKey : nil
        if tab.branch != nil || issueKey != nil {
            HStack(spacing: 6) {
                if let branch = tab.branch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                        Text(branch)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let issueKey {
                    Text(issueKey)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill((Color(linearHex: tab.issue?.stateColor) ?? .secondary).opacity(0.2)))
                        .help(tab.issue.map { "\($0.title)\n\($0.stateName)" } ?? issueKey)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if tab.agent != nil || tab.resources != nil {
            HStack(spacing: 5) {
                agentStatus

                Spacer(minLength: 4)

                if let resources = tab.resources {
                    TabResourceLabel(usage: resources)
                }
            }
            .font(.system(size: 11))
        }
    }

    @ViewBuilder
    private var agentStatus: some View {
        if let agent = tab.agent {
            HStack(spacing: 5) {
                if tab.isWorking {
                    TabWorkingDot()
                    Text("Working")
                        .foregroundStyle(.secondary)
                } else if tab.needsAttention {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text("Ready for you")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(agent.name) · idle")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11))
        }
    }

    private var backgroundOpacity: Double {
        if isSelected { return 0.11 }
        if isHovering { return 0.07 }
        return 0.035
    }

    private var borderColor: Color {
        if tab.needsAttention { return Color.accentColor.opacity(0.7) }
        if isSelected { return Color.primary.opacity(0.18) }
        return Color.primary.opacity(0.06)
    }
}

/// Memory and CPU used by the processes in a tab. Turns orange and then red when a tab
/// gets heavy, with the heaviest processes in the tooltip.
private struct TabResourceLabel: View {
    let usage: TabResourceUsage

    var body: some View {
        HStack(spacing: 6) {
            Text(Self.format(usage.memory))
                .foregroundStyle(memoryColor)
            Text("\(Int(usage.cpu))%")
                .foregroundStyle(cpuColor)
        }
        .font(.system(size: 10, design: .monospaced))
        .help(tooltip)
    }

    private var memoryColor: Color {
        let gigabyte: UInt64 = 1024 * 1024 * 1024
        if usage.memory >= 4 * gigabyte { return .red }
        if usage.memory >= 2 * gigabyte { return .orange }
        return .secondary
    }

    private var cpuColor: Color {
        if usage.cpu >= 200 { return .red }
        if usage.cpu >= 80 { return .orange }
        return .secondary
    }

    private var tooltip: String {
        let header = "Memory \(Self.format(usage.memory)) · CPU \(Int(usage.cpu))%"
        let lines = usage.top.map { "\($0.name)  \(Self.format($0.memory))  \(Int($0.cpu))%" }
        return ([header] + lines).joined(separator: "\n")
    }

    static func format(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1024 / 1024
        if megabytes < 1024 {
            return "\(Int(megabytes.rounded())) MB"
        }
        return String(format: "%.1f GB", megabytes / 1024)
    }
}

/// The round icon at the start of a card, with a dot when the agent is waiting for you.
private struct TabAvatar: View {
    let agent: TabAgent?
    let needsAttention: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)

            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(agent == nil ? Color.secondary : Color.white)
        }
        .frame(width: 26, height: 26)
        .overlay(alignment: .topTrailing) {
            if needsAttention {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: -2)
            }
        }
    }

    private var symbol: String {
        switch agent {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case nil: "terminal"
        }
    }

    private var fill: Color {
        switch agent {
        case .claude: claudeColor
        case .codex: Color(red: 0.2, green: 0.2, blue: 0.22)
        case nil: Color.primary.opacity(0.08)
        }
    }
}

/// A small dot that slowly breathes while the agent works.
private struct TabWorkingDot: View {
    @State private var isDim = false

    var body: some View {
        Circle()
            .fill(claudeColor)
            .frame(width: 6, height: 6)
            .opacity(isDim ? 0.35 : 1)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: isDim)
            .onAppear { isDim = true }
    }
}

// MARK: Resize

/// The grab area along the sidebar's trailing edge. It sits inside the sidebar because
/// the terminal view next to it receives all mouse events over its own frame. The drag
/// is measured in global coordinates because the handle moves with the width, and the
/// width is only persisted when the drag ends.
struct TabSidebarResizeHandle: View {
    @ObservedObject var frame: TabSidebarFrame
    @State private var startWidth: CGFloat?

    static let hitWidth: CGFloat = 10

    var body: some View {
        Color.clear
            .frame(width: Self.hitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else if startWidth == nil {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? frame.width
                        if startWidth == nil {
                            startWidth = start
                            frame.isResizing = true
                        }
                        frame.setLiveWidth(start + value.translation.width)
                        NSCursor.resizeLeftRight.set()
                    }
                    .onEnded { _ in
                        startWidth = nil
                        frame.isResizing = false
                        frame.commitWidth()
                    })
    }
}

/// The 1pt line between the sidebar and the terminal, highlighted while resizing.
struct TabSidebarDivider: View {
    @ObservedObject var frame: TabSidebarFrame

    var body: some View {
        Rectangle()
            .fill(frame.isResizing ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08))
            .frame(width: 1)
    }
}
