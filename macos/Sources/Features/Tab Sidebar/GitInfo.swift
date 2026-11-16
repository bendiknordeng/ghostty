import Foundation

/// Reads the repository and branch for a directory straight from the `.git` metadata so
/// the sidebar never has to spawn `git`. Results are cached briefly per directory because
/// the sidebar polls frequently.
enum GitInfo {
    struct Result: Equatable {
        let repoName: String
        let branch: String?

        /// The top of the working tree that contains the directory.
        let root: String

        /// The repository's shared git dir (`<repo>/.git`), also for linked worktrees.
        let commonGitDir: String

        /// True for worktrees added with `git worktree add`, false for the main checkout.
        let isLinkedWorktree: Bool

        var worktreeName: String { URL(fileURLWithPath: root).lastPathComponent }
    }

    private struct CacheEntry<Value> {
        let value: Value
        let date: Date
    }

    private static var cache: [String: CacheEntry<Result?>] = [:]
    private static var worktreeCache: [String: CacheEntry<[String]>] = [:]
    private static let ttl: TimeInterval = 3
    private static let worktreeTTL: TimeInterval = 10

    static func lookup(_ path: String) -> Result? {
        if let entry = cache[path], Date().timeIntervalSince(entry.date) < ttl {
            return entry.value
        }

        let result = read(path)
        cache[path] = CacheEntry(value: result, date: Date())
        return result
    }

    /// The paths of the repository's linked worktrees, read from `<repo>/.git/worktrees`.
    static func worktrees(commonGitDir: String) -> [String] {
        if let entry = worktreeCache[commonGitDir], Date().timeIntervalSince(entry.date) < worktreeTTL {
            return entry.value
        }

        let directory = URL(fileURLWithPath: commonGitDir).appendingPathComponent("worktrees")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let paths = names.compactMap { name -> String? in
            // `gitdir` holds the path of the worktree's `.git` file.
            let file = directory.appendingPathComponent(name).appendingPathComponent("gitdir")
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let dotGit = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dotGit.isEmpty else { return nil }
            let path = URL(fileURLWithPath: dotGit).deletingLastPathComponent().path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }

        worktreeCache[commonGitDir] = CacheEntry(value: paths, date: Date())
        return paths
    }

    private static func read(_ path: String) -> Result? {
        let fileManager = FileManager.default
        var dir = URL(fileURLWithPath: path).standardizedFileURL

        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDir = isDirectory.boolValue ? dotGit : linkedGitDir(dotGit, base: dir)
                guard let gitDir else { return nil }
                let commonGitDir = commonGitDir(gitDir)
                return Result(
                    repoName: repoName(worktreeRoot: dir, gitDir: gitDir),
                    branch: branch(gitDir),
                    root: dir.path,
                    commonGitDir: commonGitDir.path,
                    isLinkedWorktree: !isDirectory.boolValue && commonGitDir != gitDir)
            }

            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    /// Linked worktrees and submodules use a `.git` file that points at the real git dir.
    private static func linkedGitDir(_ file: URL, base: URL) -> URL? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8),
              let line = contents.split(separator: "\n").first,
              line.hasPrefix("gitdir:") else { return nil }

        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }

    /// A linked worktree's git dir has a `commondir` file pointing at the shared git dir.
    private static func commonGitDir(_ gitDir: URL) -> URL {
        let file = gitDir.appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return gitDir }
        let path = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, relativeTo: gitDir).standardizedFileURL
    }

    private static func branch(_ gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else {
            return nil
        }

        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }

        // Detached HEAD, show the short commit.
        return String(trimmed.prefix(7))
    }

    /// A linked worktree's git dir is `<repo>/.git/worktrees/<name>`, so the repository
    /// is named after the directory that holds `.git` rather than the worktree folder.
    private static func repoName(worktreeRoot: URL, gitDir: URL) -> String {
        let components = gitDir.pathComponents
        if let index = components.lastIndex(of: ".git"), index > 0 {
            return components[index - 1]
        }

        return worktreeRoot.lastPathComponent
    }
}

/// Lines added and removed in a working tree compared with the default branch,
/// including commits and uncommitted changes.
struct GitDiffSummary: Equatable {
    let added: Int
    let removed: Int
}

/// Computes `git diff --shortstat` against the merge base with the default branch in
/// the background and caches it per working tree, because it needs to spawn `git`.
@MainActor
final class GitDiffStats {
    static let shared = GitDiffStats()

    private struct Entry {
        let summary: GitDiffSummary?
        let date: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private let refreshInterval: TimeInterval = 10

    /// Called on the main thread when a summary changes.
    var onUpdate: (() -> Void)?

    /// Returns the cached summary and refreshes it in the background when stale.
    func summary(for root: String) -> GitDiffSummary? {
        let entry = cache[root]
        let isStale = entry.map { Date().timeIntervalSince($0.date) > refreshInterval } ?? true
        if isStale && !inFlight.contains(root) {
            inFlight.insert(root)
            DispatchQueue.global(qos: .utility).async {
                let summary = Self.compute(root)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.inFlight.remove(root)
                        let changed = self.cache[root]?.summary != summary
                        self.cache[root] = Entry(summary: summary, date: Date())
                        if changed {
                            self.onUpdate?()
                        }
                    }
                }
            }
        }

        return entry?.summary
    }

    nonisolated private static func compute(_ root: String) -> GitDiffSummary? {
        let base = ["origin/HEAD", "origin/main", "origin/master", "main", "master"]
            .lazy
            .compactMap { git(root, ["merge-base", "HEAD", $0]) }
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base, !base.isEmpty,
              let output = git(root, ["diff", "--shortstat", base]) else { return nil }

        return GitDiffSummary(
            added: number(before: "insertion", in: output),
            removed: number(before: "deletion", in: output))
    }

    /// Reads the number in front of e.g. "insertions(+)" in `--shortstat` output.
    nonisolated private static func number(before word: String, in output: String) -> Int {
        let parts = output.components(separatedBy: ",")
        guard let part = parts.first(where: { $0.contains(word) }) else { return 0 }
        return Int(part.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0
    }

    nonisolated private static func git(_ root: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root, "--no-optional-locks"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
