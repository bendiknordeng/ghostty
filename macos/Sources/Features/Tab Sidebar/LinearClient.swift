import Foundation
import SwiftUI

/// A Linear issue as shown in the tab sidebar.
struct LinearIssue: Equatable {
    struct Project: Equatable {
        let id: String
        let name: String
        let color: String?
    }

    let identifier: String
    let title: String
    let url: URL?
    let stateName: String
    let stateType: String
    let stateColor: String?
    let project: Project?
}

/// Looks up Linear issues by identifier (e.g. `PRO-5740`) for the tab sidebar.
///
/// The API key is read from `~/.config/ghostty/linear-api-key`. Without a key every lookup
/// returns nil and the sidebar falls back to grouping by repository. Results are cached for
/// the lifetime of the app and refreshed every few minutes.
final class LinearClient {
    static let shared = LinearClient()

    /// Matches Linear identifiers such as `PRO-5740` or `cor-1756`.
    static let identifierPattern = try? NSRegularExpression(pattern: "\\b([A-Za-z]{2,10})-(\\d{1,6})\\b")

    private struct CacheEntry {
        let issue: LinearIssue?
        let date: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: Set<String> = []
    private let refreshInterval: TimeInterval = 300
    private var apiKeyCache: (key: String?, date: Date)?

    /// Called on the main thread whenever a lookup finishes.
    var onUpdate: (() -> Void)?

    private static var apiKeyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/linear-api-key")
    }

    private var apiKey: String? {
        if let apiKeyCache, Date().timeIntervalSince(apiKeyCache.date) < 30 {
            return apiKeyCache.key
        }

        let key = (try? String(contentsOf: Self.apiKeyURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = (key?.isEmpty ?? true) ? nil : key
        apiKeyCache = (usable, Date())
        return usable
    }

    var isConfigured: Bool { apiKey != nil }

    /// Finds the first Linear-looking identifier in the given strings, uppercased.
    static func identifier(in candidates: [String?]) -> String? {
        guard let identifierPattern else { return nil }
        for candidate in candidates {
            guard let candidate else { continue }
            let range = NSRange(candidate.startIndex..., in: candidate)
            guard let match = identifierPattern.firstMatch(in: candidate, range: range),
                  let matchRange = Range(match.range, in: candidate) else { continue }
            return candidate[matchRange].uppercased()
        }

        return nil
    }

    /// Returns the cached issue and schedules a fetch when it is missing or stale.
    func issue(_ identifier: String) -> LinearIssue? {
        let entry = cache[identifier]
        let isStale = entry.map { Date().timeIntervalSince($0.date) > refreshInterval } ?? true
        if isStale {
            fetch(identifier)
        }

        return entry?.issue
    }

    private func fetch(_ identifier: String) {
        guard !inFlight.contains(identifier), let apiKey else { return }
        inFlight.insert(identifier)

        let query = """
        query($id: String!) {
          issue(id: $id) {
            identifier title url
            state { name type color }
            project { id name color }
          }
        }
        """

        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": ["id": identifier],
        ])

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            let issue = error == nil ? data.flatMap(Self.parse) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(identifier)

                // Keep the last good result if a refresh fails.
                if issue != nil || self.cache[identifier] == nil {
                    self.cache[identifier] = CacheEntry(issue: issue, date: Date())
                }

                self.onUpdate?()
            }
        }.resume()
    }

    private static func parse(_ data: Data) -> LinearIssue? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let issue = payload["issue"] as? [String: Any],
              let identifier = issue["identifier"] as? String,
              let title = issue["title"] as? String else { return nil }

        let state = issue["state"] as? [String: Any]
        let project = (issue["project"] as? [String: Any]).flatMap { project -> LinearIssue.Project? in
            guard let id = project["id"] as? String, let name = project["name"] as? String else { return nil }
            return LinearIssue.Project(id: id, name: name, color: project["color"] as? String)
        }

        return LinearIssue(
            identifier: identifier,
            title: title,
            url: (issue["url"] as? String).flatMap(URL.init(string:)),
            stateName: state?["name"] as? String ?? "",
            stateType: state?["type"] as? String ?? "",
            stateColor: state?["color"] as? String,
            project: project)
    }
}

extension Color {
    /// Parses `#RRGGBB` colors as returned by the Linear API.
    init?(linearHex: String?) {
        guard let linearHex else { return nil }
        let hex = linearHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
