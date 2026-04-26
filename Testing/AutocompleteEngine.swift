import AppKit

// MARK: - Frecency store
//
// "Frecency" = frequency * recency. We keep a tiny persistent map of
// `absolutePath → (count, lastUsed)` so paths the user has recently and
// repeatedly touched (typically via `cd`) bubble to the top of autocomplete
// suggestions. Scores decay exponentially with a one-week half-life so
// stale bookmarks fall out of the way without being forgotten forever.

@MainActor
enum FrecencyStore {
    private static let key = "SwiftMiniTerm.pathFrecency.v1"
    private static let halfLife: TimeInterval = 7 * 24 * 3600
    private static let maxEntries = 512

    struct Entry: Codable {
        var count: Int
        var lastUsed: TimeInterval
    }

    private static var cache: [String: Entry]?

    private static func load() -> [String: Entry] {
        if let cache { return cache }
        let data = UserDefaults.standard.data(forKey: key) ?? Data()
        let decoded = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        cache = decoded
        return decoded
    }

    private static func save(_ map: [String: Entry]) {
        cache = map
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Record one additional usage of `path` at the current time.
    static func bump(_ path: String) {
        guard !path.isEmpty else { return }
        var map = load()
        var entry = map[path] ?? Entry(count: 0, lastUsed: 0)
        entry.count += 1
        entry.lastUsed = Date().timeIntervalSince1970
        map[path] = entry

        if map.count > maxEntries {
            let now = Date().timeIntervalSince1970
            let ranked = map
                .map { (path: $0.key, score: scoreOf($0.value, now: now)) }
                .sorted { $0.score < $1.score }
            for (p, _) in ranked.prefix(map.count - maxEntries) {
                map.removeValue(forKey: p)
            }
        }
        save(map)
    }

    /// Current frecency score for `path`, or 0 if never seen.
    static func score(for path: String) -> Double {
        let map = load()
        guard let entry = map[path] else { return 0 }
        return scoreOf(entry, now: Date().timeIntervalSince1970)
    }

    private static func scoreOf(_ entry: Entry, now: TimeInterval) -> Double {
        let age = max(0, now - entry.lastUsed)
        return Double(entry.count) * exp(-age / halfLife)
    }
}

// MARK: - Match model

/// A single autocomplete result. `ghostSuffix` is the text we'd append to the
/// user's current input if they accept (Tab); `hint` is dim secondary text we
/// can render after the ghost to describe what we're offering.
@MainActor
struct AutocompleteMatch {
    enum Kind {
        case slash(SlashCommand)
        case history
        case path(isDirectory: Bool, absolutePath: String)
    }

    let kind: Kind
    let prefix: String            // The portion of the input we're extending.
    let completedToken: String    // prefix + ghostSuffix
    let ghostSuffix: String
    let hint: String?
}

// MARK: - Engine

@MainActor
enum AutocompleteEngine {

    /// The best completion for the user's current input, or nil if nothing fits.
    /// We try, in order: slash commands (only when input starts with "/"), path
    /// completion on the last token, then fish-style history prefix match.
    static func bestCompletion(for input: String,
                               cwd: String?,
                               history: [String]) -> AutocompleteMatch? {

        // 1) Slash commands.
        if input.hasPrefix("/"), !input.contains(" "),
           let cmd = SlashCommandRegistry.bestCompletion(for: input) {
            let suffix = String(cmd.name.dropFirst(input.count))
            guard !suffix.isEmpty else { return nil }
            return AutocompleteMatch(
                kind: .slash(cmd),
                prefix: input,
                completedToken: cmd.name,
                ghostSuffix: suffix,
                hint: "  — \(cmd.summary)  (⇥)"
            )
        }

        guard !input.isEmpty else { return nil }

        // 2) Path completion on the trailing token. Runs whenever there is a
        //    space in the input (i.e. the user has typed at least one argument
        //    to some command). Also runs when the entire input starts with a
        //    path-ish character like "./", "/", or "~".
        if let pathMatch = pathCompletion(for: input, cwd: cwd) {
            return pathMatch
        }

        // 3) History completion (fish/zsh style). Find the most recent command
        //    in history that begins with exactly what the user has typed and
        //    suggest completing to it.
        if let hm = historyCompletion(for: input, history: history) {
            return hm
        }

        return nil
    }

    // MARK: - History

    private static func historyCompletion(for input: String, history: [String]) -> AutocompleteMatch? {
        guard input.count >= 2 else { return nil }
        for cmd in history.reversed() where cmd != input && cmd.hasPrefix(input) {
            let suffix = String(cmd.dropFirst(input.count))
            guard !suffix.isEmpty else { continue }
            return AutocompleteMatch(
                kind: .history,
                prefix: input,
                completedToken: cmd,
                ghostSuffix: suffix,
                hint: "  ↶ recent"
            )
        }
        return nil
    }

    // MARK: - Path

    private struct PathToken {
        /// The full last token the user has typed (e.g. "~/De", "foo/bar", "D").
        let token: String
        /// Everything up to and including the last "/" in the token — preserved
        /// verbatim in the suggestion ("~/", "foo/", "/", or "" if none).
        let tokenLeader: String
        /// The filesystem directory we should enumerate.
        let baseDir: String
        /// The filename prefix we're filtering entries by (may be empty).
        let filenamePrefix: String
    }

    private static func lastTokenRange(of input: String) -> Range<String.Index>? {
        // Where does the trailing token start? Scan back until we hit a space
        // or tab. If the token IS the whole input, allow it only when it looks
        // path-ish so we don't e.g. path-complete plain command names like "ls".
        var idx = input.endIndex
        while idx > input.startIndex {
            let prev = input.index(before: idx)
            let c = input[prev]
            if c == " " || c == "\t" { break }
            idx = prev
        }
        let token = input[idx...]
        if idx == input.startIndex {
            // No whitespace — only treat as a path if it starts path-like.
            if token.hasPrefix("/") || token.hasPrefix("./") || token.hasPrefix("../") || token.hasPrefix("~") {
                return idx..<input.endIndex
            }
            return nil
        }
        return idx..<input.endIndex
    }

    private static func parsePathToken(_ token: String, cwd: String?) -> PathToken {
        let leader: String
        let namePrefix: String
        if let lastSlash = token.lastIndex(of: "/") {
            leader = String(token[...lastSlash])
            namePrefix = String(token[token.index(after: lastSlash)...])
        } else {
            leader = ""
            namePrefix = token
        }
        let expandedLeader = (leader as NSString).expandingTildeInPath
        let baseDir: String
        if leader.isEmpty {
            baseDir = cwd ?? FileManager.default.currentDirectoryPath
        } else if expandedLeader.hasPrefix("/") {
            baseDir = expandedLeader
        } else {
            let cwdPath = cwd ?? FileManager.default.currentDirectoryPath
            baseDir = (cwdPath as NSString).appendingPathComponent(expandedLeader)
        }
        return PathToken(token: token, tokenLeader: leader, baseDir: baseDir, filenamePrefix: namePrefix)
    }

    private static func pathCompletion(for input: String, cwd: String?) -> AutocompleteMatch? {
        guard let range = lastTokenRange(of: input) else { return nil }
        let token = String(input[range])
        guard !token.isEmpty else { return nil }

        let parsed = parsePathToken(token, cwd: cwd)

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: parsed.baseDir) else {
            return nil
        }

        struct Candidate {
            let name: String
            let isDir: Bool
            let score: Double
        }

        var candidates: [Candidate] = []
        let showHidden = parsed.filenamePrefix.hasPrefix(".")

        for name in entries {
            if !showHidden && name.hasPrefix(".") { continue }
            guard name.hasPrefix(parsed.filenamePrefix) else { continue }
            // Skip self-match when there's nothing left to add.
            if name == parsed.filenamePrefix { continue }

            let fullPath = (parsed.baseDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            let sc = FrecencyStore.score(for: fullPath)
            candidates.append(Candidate(name: name, isDir: isDir.boolValue, score: sc))
        }

        guard !candidates.isEmpty else { return nil }

        candidates.sort { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            if a.score != b.score { return a.score > b.score }
            return a.name.lowercased() < b.name.lowercased()
        }

        guard let best = candidates.first else { return nil }

        var completedName = best.name
        if best.isDir { completedName += "/" }
        let completedToken = parsed.tokenLeader + completedName
        guard completedToken.hasPrefix(token), completedToken.count > token.count else {
            return nil
        }
        let suffix = String(completedToken.dropFirst(token.count))

        let absolutePath = (parsed.baseDir as NSString).appendingPathComponent(best.name)
        let kindHint: String? = {
            if candidates.count > 1 {
                return best.isDir ? "  +\(candidates.count - 1) more  (⇥)" : "  +\(candidates.count - 1) more  (⇥)"
            }
            return best.isDir ? "  dir  (⇥)" : "  file  (⇥)"
        }()

        return AutocompleteMatch(
            kind: .path(isDirectory: best.isDir, absolutePath: absolutePath),
            prefix: token,
            completedToken: completedToken,
            ghostSuffix: suffix,
            hint: kindHint
        )
    }
}
