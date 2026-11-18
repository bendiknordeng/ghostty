import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted when a shared tab sidebar preference (visibility, grouping, width) changes.
    static let tabSidebarPreferencesDidChange = Notification.Name("com.mitchellh.ghostty.tabSidebarPreferencesDidChange")
}

/// The state behind the vertical tab sidebar of a single terminal window.
///
/// Ghostty tabs are separate NSWindows grouped by AppKit into a native tab group, so
/// every window in a group owns its own model and renders its own copy of the sidebar.
/// Only the selected window is visible, so the copies never appear side by side. Tab
/// metadata comes from the shared `TabSidebarStore`.
@MainActor
class TabSidebarModel: ObservableObject {
    // MARK: Shared preferences

    private static let visibleKey = "TabSidebarVisible"
    private static let groupedKey = "TabSidebarGrouped"
    private static let widthKey = "TabSidebarWidth"
    private static let collapsedKey = "TabSidebarCollapsed"

    static let widthRange: ClosedRange<CGFloat> = 200...480

    /// Whether the sidebar is shown. This is shared by all windows.
    static var isVisible: Bool {
        get { UserDefaults.standard.object(forKey: visibleKey) as? Bool ?? true }
        set { setPreference(newValue, forKey: visibleKey) }
    }

    /// Whether tabs are grouped into a project and issue tree.
    static var isGrouped: Bool {
        get { UserDefaults.standard.object(forKey: groupedKey) as? Bool ?? true }
        set { setPreference(newValue, forKey: groupedKey) }
    }

    static var width: CGFloat {
        get {
            let stored = UserDefaults.standard.object(forKey: widthKey) as? Double ?? 260
            return min(max(CGFloat(stored), widthRange.lowerBound), widthRange.upperBound)
        }
        set { setPreference(Double(newValue), forKey: widthKey) }
    }

    /// The collapsed tree nodes (projects and issues). Shared by all windows so that
    /// switching tabs keeps the tree as it was.
    static var collapsed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? []) }
        set { setPreference(Array(newValue).sorted(), forKey: collapsedKey) }
    }

    /// Whether the native tab bar should be hidden because the sidebar replaces it.
    static var hidesNativeTabBar: Bool { isVisible }

    private static func setPreference(_ value: Any, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: .tabSidebarPreferencesDidChange, object: nil)
    }

    /// Asks the sidebars to re-read their tabs. Call this whenever tabs are added,
    /// removed, reordered or selected.
    static func setNeedsRefresh() {
        TabSidebarStore.shared.setNeedsUpdate()
        refreshAll()
    }

    /// Re-reads the selection of every window's sidebar right away. Switching tabs
    /// changes nothing in the tab metadata, so this can't wait for the store to publish.
    static func refreshAll() {
        for window in NSApp.windows {
            (window.windowController as? TerminalController)?.tabSidebar.refresh()
        }
    }

    // MARK: Per-window state

    @Published private(set) var tabs: [TabInfo] = []
    @Published fileprivate(set) var selectedID: ObjectIdentifier?
    @Published private(set) var isGrouped: Bool = TabSidebarModel.isGrouped
    @Published private(set) var collapsed: Set<String> = TabSidebarModel.collapsed
    @Published var query: String = ""

    /// An ongoing drag of a tab card. `frames` are the other cards' frames when the drag
    /// started; measuring against them instead of the live layout keeps the preview from
    /// feeding back into itself while rows move.
    struct DragState: Equatable {
        let id: ObjectIdentifier
        let frames: [ObjectIdentifier: CGRect]
        var insertBefore: ObjectIdentifier?
    }

    @Published private(set) var drag: DragState?

    /// The latest card frames in the list's coordinate space, reported by the cards.
    var cardFrames: [ObjectIdentifier: CGRect] = [:]

    /// Visibility and width live in their own object so that the terminal next to the
    /// sidebar only re-renders when those change, not on every tab update.
    let frame = TabSidebarFrame()

    /// The window this sidebar belongs to.
    weak var window: NSWindow? {
        didSet { refresh() }
    }

    private var cancellables: Set<AnyCancellable> = []

    /// Observes the tab group's selected window so the highlight follows tab switches
    /// (clicks, ⌘1-9, ⌘⇧[ / ]) in the same run loop turn.
    private var selectionObservation: NSKeyValueObservation?
    private weak var observedTabGroup: NSWindowTabGroup?

    init() {
        TabSidebarStore.shared.$tabs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .tabSidebarPreferencesDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.frame.sync()
                if self.isGrouped != Self.isGrouped {
                    self.isGrouped = Self.isGrouped
                }
                if self.collapsed != Self.collapsed {
                    self.collapsed = Self.collapsed
                }
                self.refresh()
            }
            .store(in: &cancellables)
    }

    private var groupWindows: [NSWindow] {
        guard let window else { return [] }
        return window.tabGroup?.windows ?? [window]
    }

    func refresh() {
        guard window != nil else {
            tabs = []
            return
        }

        let store = TabSidebarStore.shared.tabs
        let next = groupWindows.compactMap { store[ObjectIdentifier($0)] }
        if next != tabs {
            tabs = next
        }

        updateSelection()
        observeSelection()
        syncNativeTabBar()
    }

    private func updateSelection() {
        guard let window else { return }
        let selected = ObjectIdentifier(window.tabGroup?.selectedWindow ?? window)
        if selected != selectedID {
            selectedID = selected
        }
    }

    private func observeSelection() {
        let tabGroup = window?.tabGroup
        guard tabGroup !== observedTabGroup else { return }
        observedTabGroup = tabGroup
        selectionObservation = tabGroup?.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateSelection() }
        }
    }

    /// The sidebar replaces the native tab bar, so collapse the tab bar accessory while
    /// the sidebar is shown. `toggleTabBar` is unreliable for Ghostty windows, so we hide
    /// the accessory AppKit uses for the tab bar instead. TerminalWindow also applies this
    /// when AppKit adds the accessory later.
    private func syncNativeTabBar() {
        guard let window else { return }
        for accessory in window.titlebarAccessoryViewControllers
        where accessory.identifier == TerminalWindow.tabBarIdentifier && accessory.isHidden != Self.hidesNativeTabBar {
            accessory.isHidden = Self.hidesNativeTabBar
        }
    }

    // MARK: Sections

    var filteredTabs: [TabInfo] {
        previewTabs.filter { $0.matches(query) }
    }

    /// The tab order, with the dragged tab already moved to where it would land.
    private var previewTabs: [TabInfo] {
        guard let drag, let moving = tabs.first(where: { $0.id == drag.id }) else { return tabs }
        var rest = tabs.filter { $0.id != drag.id }
        let index = drag.insertBefore.flatMap { before in rest.firstIndex { $0.id == before } } ?? rest.count
        rest.insert(moving, at: index)
        return rest
    }

    // MARK: Dragging

    /// The tab that currently follows the given one in the native order, or nil if it is last.
    private func nextTabID(after id: ObjectIdentifier) -> ObjectIdentifier? {
        guard let index = tabs.firstIndex(where: { $0.id == id }), index + 1 < tabs.count else { return nil }
        return tabs[index + 1].id
    }

    /// Updates the preview while a card is dragged. `y` is in the list's coordinate
    /// space; anywhere below the last card means the end of the list.
    func dragChanged(_ id: ObjectIdentifier, y: CGFloat) {
        if drag?.id != id {
            drag = DragState(
                id: id,
                frames: cardFrames.filter { $0.key != id },
                insertBefore: nextTabID(after: id))
        }

        guard var state = drag else { return }
        let before = state.frames
            .sorted { $0.value.minY < $1.value.minY }
            .first { $0.value.midY > y }?
            .key

        guard before != state.insertBefore else { return }
        state.insertBefore = before
        withAnimation(.easeInOut(duration: 0.15)) {
            drag = state
        }
    }

    func dragEnded() {
        guard let state = drag else { return }
        drag = nil

        guard state.insertBefore != nextTabID(after: state.id) else { return }
        if let before = state.insertBefore {
            move(state.id, to: before, after: false)
        } else if let last = tabs.last(where: { $0.id != state.id }) {
            move(state.id, to: last.id, after: true)
        }
    }

    /// Tabs grouped by Linear project (or repository) and then by Linear issue.
    var sections: [TabSidebarSection] {
        var sections: [TabSidebarSection] = []
        for tab in filteredTabs {
            let sectionID = tab.issue?.project.map { "project:\($0.id)" }
                ?? tab.repoName.map { "repo:\($0)" }
                ?? "other"

            var index = sections.firstIndex { $0.id == sectionID }
            if index == nil {
                sections.append(TabSidebarSection(
                    id: sectionID,
                    title: tab.issue?.project?.name ?? tab.repoName ?? "Other",
                    color: Color(linearHex: tab.issue?.project?.color),
                    isLinearProject: tab.issue?.project != nil,
                    groups: []))
                index = sections.count - 1
            }

            sections[index!].insert(tab)
        }

        return sections
    }

    func isCollapsed(_ id: String) -> Bool {
        collapsed.contains(id)
    }

    func toggleCollapsed(_ id: String) {
        var next = Self.collapsed
        if next.contains(id) {
            next.remove(id)
        } else {
            next.insert(id)
        }
        Self.collapsed = next
    }

    /// Every collapsible node currently in the tree.
    private var treeNodeIDs: Set<String> {
        Set(sections.flatMap { section in
            [section.id] + section.groups.filter { $0.issueKey != nil }.map(\.id)
        })
    }

    /// True when at least one visible node is expanded, so the toolbar offers to collapse.
    var canCollapseAll: Bool {
        !treeNodeIDs.isSubset(of: collapsed)
    }

    func toggleCollapseAll() {
        let nodes = treeNodeIDs
        if canCollapseAll {
            Self.collapsed = Self.collapsed.union(nodes)
        } else {
            Self.collapsed = Self.collapsed.subtracting(nodes)
        }
    }

    // MARK: Actions

    private func window(for id: ObjectIdentifier) -> NSWindow? {
        groupWindows.first { ObjectIdentifier($0) == id }
    }

    func select(_ id: ObjectIdentifier) {
        guard let target = window(for: id) else { return }

        // Move the highlight in every copy of the sidebar before switching, so the
        // window that appears already shows itself as selected.
        for groupWindow in groupWindows {
            (groupWindow.windowController as? TerminalController)?.tabSidebar.selectedID = id
        }

        target.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
    }

    func close(_ id: ObjectIdentifier) {
        guard let target = window(for: id) else { return }
        (target.windowController as? TerminalController)?.closeTab(nil)
    }

    /// Moves a tab before or after another one in the native tab group, which is what
    /// both the sidebar order and ⌘1-9 follow. Like Ghostty's move_tab, this removes
    /// the window from the group and adds it back next to the target.
    func move(_ id: ObjectIdentifier, to targetID: ObjectIdentifier, after: Bool) {
        guard id != targetID,
              let moving = window(for: id),
              let target = window(for: targetID),
              let tabGroup = moving.tabGroup else { return }

        let selected = tabGroup.selectedWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(moving)
        _ = target.addTabbedWindowSafely(moving, ordered: after ? .above : .below)
        if let selected {
            target.tabGroup?.selectedWindow = selected
            selected.makeKey()
        }
        NSAnimationContext.endGrouping()

        (moving.windowController as? TerminalController)?.relabelTabs()
        Self.setNeedsRefresh()
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    func setUnread(_ id: ObjectIdentifier, _ unread: Bool) {
        TabSidebarStore.shared.setUnread(id, unread)
    }

    func openIssue(_ tab: TabInfo) {
        guard let url = tab.issue?.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Tabs in the order the sidebar shows them.
    var orderedTabs: [TabInfo] {
        guard isGrouped else { return filteredTabs }
        return sections.flatMap { section in section.groups.flatMap(\.tabs) }
    }

    /// Selects the tab above (negative offset) or below the selected one, wrapping
    /// around. With `unreadOnly`, skips to the nearest tab that needs attention,
    /// like Slack's ⌥⇧↑/↓.
    func selectAdjacent(_ direction: Int, unreadOnly: Bool) {
        let ordered = orderedTabs
        guard !ordered.isEmpty else { return }

        let current = ordered.firstIndex { $0.id == selectedID } ?? (direction > 0 ? -1 : ordered.count)
        for step in 1...ordered.count {
            let index = ((current + direction * step) % ordered.count + ordered.count) % ordered.count
            let candidate = ordered[index]
            if candidate.id == selectedID { return }
            if !unreadOnly || candidate.needsAttention {
                select(candidate.id)
                return
            }
        }
    }

    func toggleGrouping() {
        Self.isGrouped.toggle()
    }

}

/// The sidebar's visibility and width, observed by the layout around the terminal.
@MainActor
final class TabSidebarFrame: ObservableObject {
    @Published private(set) var isVisible: Bool = TabSidebarModel.isVisible
    @Published private(set) var width: CGFloat = TabSidebarModel.width
    @Published var isResizing = false

    func sync() {
        if isVisible != TabSidebarModel.isVisible {
            isVisible = TabSidebarModel.isVisible
        }
        if width != TabSidebarModel.width {
            width = TabSidebarModel.width
        }
    }

    /// Updates the width while dragging without persisting it.
    func setLiveWidth(_ proposed: CGFloat) {
        let clamped = min(max(proposed, TabSidebarModel.widthRange.lowerBound),
                          TabSidebarModel.widthRange.upperBound).rounded()
        if clamped != width {
            width = clamped
        }
    }

    /// Persists the current width once the drag ends so every window picks it up.
    func commitWidth() {
        TabSidebarModel.width = width
    }
}

/// A project (or repository) in the grouped sidebar.
struct TabSidebarSection: Identifiable {
    /// Tabs that share a Linear issue, or a single tab without one.
    struct Group: Identifiable {
        let id: String
        let issueKey: String?
        let issue: LinearIssue?
        var tabs: [TabInfo]

        /// The issue title from Linear, or from a tab titled after the issue while Linear
        /// is unreachable or not configured.
        var title: String? {
            issue?.title ?? tabs.lazy.compactMap(\.titleAfterIssueKey).first
        }
    }

    let id: String
    let title: String
    let color: Color?
    let isLinearProject: Bool
    var groups: [Group]

    var tabCount: Int { groups.reduce(0) { $0 + $1.tabs.count } }

    mutating func insert(_ tab: TabInfo) {
        guard let key = tab.issueKey else {
            groups.append(Group(id: "tab:\(tab.id.hashValue)", issueKey: nil, issue: nil, tabs: [tab]))
            return
        }

        if let index = groups.firstIndex(where: { $0.issueKey == key }) {
            groups[index].tabs.append(tab)
        } else {
            groups.append(Group(id: "\(id)|issue:\(key)", issueKey: key, issue: tab.issue, tabs: [tab]))
        }
    }
}

/// Places the tab sidebar to the left of the terminal content.
struct TabSidebarLayout<Content: View>: View {
    let model: TabSidebarModel
    @ObservedObject var frame: TabSidebarFrame
    let content: Content

    init(model: TabSidebarModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.frame = model.frame
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if frame.isVisible {
                TabSidebarView(model: model)
                    .acceptsClicksWhileWindowInactive()
                    .frame(width: frame.width)
                    .overlay(alignment: .trailing) {
                        TabSidebarResizeHandle(frame: frame)
                    }
                TabSidebarDivider(frame: frame)
            }

            content
        }
    }
}

private extension View {
    @ViewBuilder
    func acceptsClicksWhileWindowInactive() -> some View {
        if #available(macOS 15.0, *) {
            allowsWindowActivationEvents(true)
        } else {
            self
        }
    }
}

/// Adds sidebar items to the View menu and the tab navigation shortcuts.
@MainActor
final class TabSidebarMenu: NSObject, NSMenuItemValidation {
    private static let shared = TabSidebarMenu()
    private static var installed = false
    private static var keyMonitor: Any?

    private static let upArrowKeyCode: UInt16 = 126
    private static let downArrowKeyCode: UInt16 = 125

    static func install() {
        guard !installed,
              let viewMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else { return }
        installed = true

        let toggle = NSMenuItem(title: "Hide Tab Sidebar", action: #selector(toggleVisible(_:)), keyEquivalent: "")
        toggle.target = shared
        let group = NSMenuItem(title: "Group Tabs by Project", action: #selector(toggleGrouped(_:)), keyEquivalent: "")
        group.target = shared

        let items = [
            toggle,
            group,
            navigationItem("Previous Tab", #selector(previousTab(_:)), arrow: NSUpArrowFunctionKey, shift: false),
            navigationItem("Next Tab", #selector(nextTab(_:)), arrow: NSDownArrowFunctionKey, shift: false),
            navigationItem("Previous Unread Tab", #selector(previousUnreadTab(_:)), arrow: NSUpArrowFunctionKey, shift: true),
            navigationItem("Next Unread Tab", #selector(nextUnreadTab(_:)), arrow: NSDownArrowFunctionKey, shift: true),
            testNotificationItem(),
            NSMenuItem.separator(),
        ]
        for (index, item) in items.enumerated() {
            viewMenu.insertItem(item, at: index)
        }

        installKeyMonitor()
    }

    /// The menu items show the shortcuts, but the terminal consumes arrow keys before
    /// the menu sees them, so a local monitor handles the keys first.
    private static func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let direction: Int
            switch event.keyCode {
            case upArrowKeyCode: direction = -1
            case downArrowKeyCode: direction = 1
            default: return event
            }

            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            let unreadOnly: Bool
            switch flags {
            case [.option]: unreadOnly = false
            case [.option, .shift]: unreadOnly = true
            default: return event
            }

            guard let model = keyModel else { return event }
            model.selectAdjacent(direction, unreadOnly: unreadOnly)
            return nil
        }
    }

    private static var keyModel: TabSidebarModel? {
        (NSApp.keyWindow?.windowController as? TerminalController)?.tabSidebar
    }

    private static func navigationItem(_ title: String, _ action: Selector, arrow: Int, shift: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: String(Character(UnicodeScalar(arrow)!)))
        item.keyEquivalentModifierMask = shift ? [.option, .shift] : [.option]
        item.target = shared
        return item
    }

    private static func testNotificationItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Send Test Agent Notification (in 5s)",
            action: #selector(sendTestNotification(_:)),
            keyEquivalent: "")
        item.target = shared
        return item
    }

    @objc private func sendTestNotification(_ sender: Any?) {
        TabSidebarStore.shared.sendTestNotification()
    }

    @objc private func previousTab(_ sender: Any?) {
        Self.keyModel?.selectAdjacent(-1, unreadOnly: false)
    }

    @objc private func nextTab(_ sender: Any?) {
        Self.keyModel?.selectAdjacent(1, unreadOnly: false)
    }

    @objc private func previousUnreadTab(_ sender: Any?) {
        Self.keyModel?.selectAdjacent(-1, unreadOnly: true)
    }

    @objc private func nextUnreadTab(_ sender: Any?) {
        Self.keyModel?.selectAdjacent(1, unreadOnly: true)
    }

    @objc private func toggleVisible(_ sender: Any?) {
        TabSidebarModel.isVisible.toggle()
    }

    @objc private func toggleGrouped(_ sender: Any?) {
        TabSidebarModel.isGrouped.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleVisible(_:)):
            menuItem.title = TabSidebarModel.isVisible ? "Hide Tab Sidebar" : "Show Tab Sidebar"
        case #selector(toggleGrouped(_:)):
            menuItem.state = TabSidebarModel.isGrouped ? .on : .off
        default:
            break
        }

        return true
    }
}
