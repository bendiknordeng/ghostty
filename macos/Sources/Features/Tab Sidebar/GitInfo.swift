import Foundation

/// Reads the repository and branch for a directory straight from the `.git` metadata so
/// the sidebar never has to spawn `git`. Results are cached briefly per directory because
/// the sidebar polls frequently.
enum GitInfo {
    struct Result: Equatable {
        let repoName: String
        let branch: String?
    }

    private struct CacheEntry {
        let result: Result?
        let date: Date
    }

    private static var cache: [String: CacheEntry] = [:]
    private static let ttl: TimeInterval = 3

    static func lookup(_ path: String) -> Result? {
        if let entry = cache[path], Date().timeIntervalSince(entry.date) < ttl {
            return entry.result
        }

        let result = read(path)
        cache[path] = CacheEntry(result: result, date: Date())
        return result
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
                return Result(
                    repoName: repoName(worktreeRoot: dir, gitDir: gitDir),
                    branch: branch(gitDir))
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
