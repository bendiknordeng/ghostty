import AppKit
import Combine
import Darwin
import UserNotifications

/// A coding agent running in a tab.
enum TabAgent: Equatable {
    case claude
    case codex

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Everything the sidebar shows about a single tab.
struct TabInfo: Equatable, Identifiable {
    let id: ObjectIdentifier
    var title: String
    var pwd: String?
    var repoName: String?
    var branch: String?
    var shortcut: String?
    var agent: TabAgent?
    var isWorking: Bool
    var needsAttention: Bool
    var issueKey: String?
    var issue: LinearIssue?
    var resources: TabResourceUsage?

    /// The pwd with the home directory shortened to `~`.
    var displayPwd: String? {
        guard let pwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if pwd == home { return "~" }
        if pwd.hasPrefix(home + "/") { return "~" + pwd.dropFirst(home.count) }
        return pwd
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [title, pwd, branch, repoName, issueKey, issue?.title, issue?.project?.name, agent?.name]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// Tracks metadata and agent activity for every terminal tab in the app.
///
/// Tabs are polled twice a second, which is cheap (in-memory surface state, a cached
/// `.git` read and a `proc_pidpath` call per surface) and far more reliable than trying
/// to observe every source of change. The store also turns an agent finishing its turn
/// in a background tab into a notification and an "needs attention" badge.
@MainActor
final class TabSidebarStore: ObservableObject {
    static let shared = TabSidebarStore()

    @Published private(set) var tabs: [ObjectIdentifier: TabInfo] = [:]

    private struct AgentState {
        var workStartedAt: Date?
        var lastWorkingAt: Date?
        var wasWorking = false
        var wasSeen = false
        var needsAttention = false
    }

    private var agentStates: [ObjectIdentifier: AgentState] = [:]
    private var timer: Timer?

    private let processStats = ProcessStats()
    private var resources: [ObjectIdentifier: TabResourceUsage] = [:]
    private var lastResourceSample: Date?

    /// Process trees are walked less often than the rest because CPU usage needs a
    /// meaningful interval between samples anyway.
    private let resourceInterval: TimeInterval = 2

    /// Claude Code briefly clears its progress report between tool calls, so a tab keeps
    /// counting as working for this long after the last progress report.
    private let workingGrace: TimeInterval = 3

    /// Turns shorter than this never notify, which filters out progress flickers.
    private let minimumTurnForNotification: TimeInterval = 3

    /// Tabs whose agent finished or asked for input while you were elsewhere. This feeds
    /// the Dock badge together with Ghostty's own bell count.
    private(set) var agentAttentionCount = 0

    private var didRequestNotificationAuthorization = false

    private init() {
        LinearClient.shared.onUpdate = { [weak self] in
            MainActor.assumeIsolated { self?.update() }
        }

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Re-reads every tab right away instead of waiting for the next poll.
    func setNeedsUpdate() {
        update()
    }

    private func update() {
        let now = Date()
        let sampleResources = lastResourceSample.map { now.timeIntervalSince($0) >= resourceInterval } ?? true
        if sampleResources {
            lastResourceSample = now
        }

        var next: [ObjectIdentifier: TabInfo] = [:]
        for window in NSApp.windows {
            guard let controller = window.windowController as? TerminalController else { continue }
            let id = ObjectIdentifier(window)
            if sampleResources {
                resources[id] = sampleUsage(controller: controller, now: now)
            }

            var tabInfo = info(for: window, controller: controller, now: now)
            tabInfo.resources = resources[id]
            next[id] = tabInfo
        }

        if sampleResources {
            processStats.finishRound()
        }

        agentStates = agentStates.filter { next[$0.key] != nil }
        resources = resources.filter { next[$0.key] != nil }
        if next != tabs {
            tabs = next
        }

        if !next.isEmpty {
            requestNotificationAuthorization()
        }

        let attentionCount = agentStates.values.filter(\.needsAttention).count
        if attentionCount != agentAttentionCount {
            agentAttentionCount = attentionCount
            (NSApp.delegate as? AppDelegate)?.syncDockBadge()
        }
    }

    /// Ghostty only asks for notification permission when a program sends a desktop
    /// notification escape sequence, which agents rarely do, so ask once up front.
    private func requestNotificationAuthorization() {
        guard !didRequestNotificationAuthorization else { return }
        didRequestNotificationAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                Ghostty.logger.warning("tab sidebar notification authorization failed: \(error, privacy: .public)")
            }
        }
    }

    /// Called when a program in a surface posts its own desktop notification, such as
    /// Claude Code asking for permission. Marks the tab as needing attention unless you
    /// are looking at it.
    func surfaceDidPostNotification(_ surface: Ghostty.SurfaceView) {
        guard let window = surface.window,
              window.windowController is TerminalController,
              !(NSApp.isActive && window.isKeyWindow) else { return }

        let id = ObjectIdentifier(window)
        var state = agentStates[id] ?? AgentState()
        state.needsAttention = true
        agentStates[id] = state
        update()
    }

    func setUnread(_ id: ObjectIdentifier, _ unread: Bool) {
        var state = agentStates[id] ?? AgentState()
        state.needsAttention = unread
        agentStates[id] = state
        update()
    }

    /// Posts a sample notification for the selected tab after a short delay, so you can
    /// switch away and check that notifications and the Dock badge work.
    func sendTestNotification() {
        guard let window = NSApp.keyWindow,
              let controller = window.windowController as? TerminalController,
              let surface = controller.focusedSurface,
              let info = tabs[ObjectIdentifier(window)] else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notifyFinished(agent: info.agent ?? .claude, info: info, surface: surface)
                self.surfaceDidPostNotification(surface)
            }
        }
    }

    private func info(for window: NSWindow, controller: TerminalController, now: Date) -> TabInfo {
        let id = ObjectIdentifier(window)
        let surfaces = Array(controller.surfaceTree)
        let focused = controller.focusedSurface ?? surfaces.first
        let pwd = focused?.pwd
        let git = pwd.flatMap(GitInfo.lookup)
        let rawTitle = window.title

        let agent = surfaces.lazy.compactMap(Self.agent(for:)).first ?? Self.agent(fromTitle: rawTitle)
        let reportsProgress = surfaces.contains { surface in
            guard let report = surface.progressReport else { return false }
            return report.state != .remove
        }

        var state = agentStates[id] ?? AgentState()
        if agent != nil && (reportsProgress || Self.isSpinner(rawTitle.first)) {
            if state.workStartedAt == nil {
                state.workStartedAt = now
            }
            state.lastWorkingAt = now
        }

        let isWorking = state.lastWorkingAt.map { now.timeIntervalSince($0) < workingGrace } ?? false
        let isSeen = NSApp.isActive && window.isKeyWindow
        let issueKey = LinearClient.identifier(in: [git?.branch, rawTitle, pwd])
        let title = Self.displayTitle(rawTitle, pwd: pwd)

        var info = TabInfo(
            id: id,
            title: title,
            pwd: pwd,
            repoName: git?.repoName,
            branch: git?.branch,
            shortcut: (window as? TerminalWindow)?.keyEquivalent,
            agent: agent,
            isWorking: isWorking,
            needsAttention: false,
            issueKey: issueKey,
            issue: issueKey.flatMap { LinearClient.shared.issue($0) })

        if state.wasWorking && !isWorking {
            let turnLength = state.workStartedAt.map { now.timeIntervalSince($0) } ?? 0
            if !isSeen && turnLength >= minimumTurnForNotification, let agent, let focused {
                state.needsAttention = true
                notifyFinished(agent: agent, info: info, surface: focused)
            }
            state.workStartedAt = nil
        }

        // Like Slack, a tab becomes read when you switch to it. Marking the tab you are
        // looking at as unread sticks until you leave it and come back.
        if isWorking || (isSeen && !state.wasSeen) {
            state.needsAttention = false
        }

        state.wasWorking = isWorking
        state.wasSeen = isSeen
        agentStates[id] = state

        // A ringing bell also counts as unread so ⌥⇧↑/↓ can jump to it.
        info.needsAttention = state.needsAttention || (controller.bell && !isSeen)
        return info
    }

    /// Usage of everything Ghostty started for the tab's surfaces (the shell and its children).
    private func sampleUsage(controller: TerminalController, now: Date) -> TabResourceUsage? {
        let roots = Set(controller.surfaceTree.compactMap { surface -> pid_t? in
            guard let foreground = surface.surfaceModel?.foregroundPID else { return nil }
            return ProcessStats.rootPID(fromForeground: pid_t(foreground))
        })
        guard !roots.isEmpty else { return nil }
        return processStats.usage(roots: Array(roots), now: now).rounded()
    }

    private func notifyFinished(agent: TabAgent, info: TabInfo, surface: Ghostty.SurfaceView) {
        let issue = info.issue.map { "\($0.identifier) \($0.title)" } ?? info.issueKey
        let body = [issue, info.repoName, info.branch]
            .compactMap { $0 }
            .joined(separator: " · ")

        // We only notify for tabs you are not looking at, so don't let Ghostty suppress
        // the banner based on surface focus.
        surface.showUserNotification(
            title: "\(agent.name) is ready for you",
            body: body.isEmpty ? (info.displayPwd ?? info.title) : body,
            requireFocus: false)

        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: Detection

    /// Agents are often started through wrappers (shell functions, proxies, node or python
    /// launchers), so the foreground process is not necessarily the agent itself. Search
    /// the foreground process and a few levels of its descendants.
    private static func agent(for surface: Ghostty.SurfaceView) -> TabAgent? {
        guard let foreground = surface.surfaceModel?.foregroundPID else { return nil }

        var queue: [(pid: pid_t, depth: Int)] = [(pid_t(foreground), 0)]
        while !queue.isEmpty {
            let (pid, depth) = queue.removeFirst()
            if let agent = agent(forPID: pid) {
                return agent
            }

            if depth < 4 {
                queue.append(contentsOf: ProcessStats.childPIDs(of: pid).map { ($0, depth + 1) })
            }
        }

        return nil
    }

    private static func agent(forPID pid: pid_t) -> TabAgent? {
        // Claude Code installs versioned binaries such as ~/.local/share/claude/versions/2.1.0,
        // so the process name alone is just a version number.
        guard let path = ProcessStats.path(pid)?.lowercased() else { return nil }
        if path.contains("/claude/versions/") || path.hasSuffix("/claude") {
            return .claude
        }

        if path.hasSuffix("/codex") || path.contains("/codex/") {
            return .codex
        }

        return nil
    }

    /// Claude Code prefixes the terminal title with ✳ while it is running.
    private static func agent(fromTitle title: String) -> TabAgent? {
        title.hasPrefix("✳") ? .claude : nil
    }

    /// Spinner glyphs that agents put at the start of the title while busy.
    private static func isSpinner(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        if (0x2800...0x28FF).contains(scalar.value) { return true }
        return "◐◓◑◒".unicodeScalars.contains(scalar)
    }

    /// Drops agent status glyphs from the title and replaces the default
    /// `user@host:path` shell title with the directory name.
    private static func displayTitle(_ title: String, pwd: String?) -> String {
        var result = Substring(title)
        while let first = result.first,
              !first.isLetter, !first.isNumber, !"~/.([".contains(first),
              result.dropFirst().first == " " {
            result = result.dropFirst(2)
        }

        let trimmed = result.trimmingCharacters(in: .whitespaces)
        if let pwd, trimmed.contains("@"), trimmed.contains(":"), !trimmed.contains(" ") {
            return URL(fileURLWithPath: pwd).lastPathComponent
        }

        return trimmed.isEmpty ? "👻" : trimmed
    }
}
