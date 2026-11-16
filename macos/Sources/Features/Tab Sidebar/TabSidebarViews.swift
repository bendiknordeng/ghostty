import SwiftUI

/// Claude's brand orange, used for the Claude avatar and working indicator.
private let claudeColor = Color(red: 0.85, green: 0.47, blue: 0.34)

struct TabSidebarView: View {
    @ObservedObject var model: TabSidebarModel

    var body: some View {
        VStack(spacing: 0) {
            TabSidebarHeader(model: model)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) {
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
                .padding(.vertical, 8)
            }
        }
        .background(.regularMaterial)
    }
}

private struct TabSidebarHeader: View {
    @ObservedObject var model: TabSidebarModel

    var body: some View {
        HStack(spacing: 6) {
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

            TabSidebarIconButton(
                systemImage: model.isGrouped ? "list.bullet.indent" : "list.bullet",
                help: model.isGrouped ? "Show as list" : "Group by project and issue",
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

private struct TabSidebarSectionView: View {
    @ObservedObject var model: TabSidebarModel
    let section: TabSidebarSection

    private var isCollapsed: Bool { model.collapsedSections.contains(section.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.toggleSection(section.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 10)

                    if section.isLinearProject {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(section.color ?? .secondary)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                    }

                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("\(section.tabCount)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(section.groups) { group in
                    if group.issueKey != nil {
                        TabSidebarIssueGroup(model: model, group: group)
                    } else {
                        ForEach(group.tabs) { tab in
                            TabCard(model: model, tab: tab)
                        }
                    }
                }
            }
        }
    }
}

private struct TabSidebarIssueGroup: View {
    @ObservedObject var model: TabSidebarModel
    let group: TabSidebarSection.Group

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(Color(linearHex: group.issue?.stateColor) ?? .secondary, lineWidth: 1.5)
                    .frame(width: 9, height: 9)

                Text(group.issueKey ?? "")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let title = group.issue?.title {
                    Text(title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .help(group.issue.map { "\($0.identifier) · \($0.stateName)\n\($0.title)" } ?? (group.issueKey ?? ""))

            VStack(spacing: 4) {
                ForEach(group.tabs) { tab in
                    TabCard(model: model, tab: tab, showsIssue: false)
                }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1)
                    .padding(.leading, 10)
                    .offset(x: -6)
            }
        }
        .padding(.top, 2)
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
            TabAvatar(agent: tab.agent, isWorking: tab.isWorking, needsAttention: tab.needsAttention)

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
        .animation(.easeInOut(duration: 0.15), value: isSelected)
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
        if let agent = tab.agent {
            HStack(spacing: 4) {
                if tab.isWorking {
                    Text("\(agent.name) is working…")
                        .foregroundStyle(claudeColor)
                } else if tab.needsAttention {
                    Text("\(agent.name) is ready for you")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(agent.name) · idle")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11, weight: .medium))
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

/// The round icon at the start of a card. Agents get their own mark, a spinning ring
/// while they work and a dot when they are waiting for you.
private struct TabAvatar: View {
    let agent: TabAgent?
    let isWorking: Bool
    let needsAttention: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)

            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(agent == nil ? Color.secondary : Color.white)

            if isWorking {
                TabWorkingRing()
            }
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

private struct TabWorkingRing: View {
    @State private var isRotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.3)
            .stroke(claudeColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .padding(-3)
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isRotating)
            .onAppear { isRotating = true }
    }
}

// MARK: Resize

struct TabSidebarResizeHandle: View {
    @ObservedObject var model: TabSidebarModel
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = startWidth ?? model.width
                                startWidth = start
                                let proposed = start + value.translation.width
                                model.width = min(max(proposed, TabSidebarModel.widthRange.lowerBound),
                                                  TabSidebarModel.widthRange.upperBound)
                            }
                            .onEnded { _ in
                                startWidth = nil
                                model.commitWidth()
                            })
            }
    }
}
