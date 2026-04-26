import AppKit

@MainActor
enum SessionRestore {
    private static let windowFrameKey = "SwiftMiniTerm.windowFrame.v2"
    private static let recentCommandsKey = "SwiftMiniTerm.recentCommands"
    private static let scrollbackKey = "SwiftMiniTerm.lastScrollback"
    private static let themeKey = "SwiftMiniTerm.theme"
    private static let fontSizeKey = "SwiftMiniTerm.fontSize"
    private static let lineHeightKey = "SwiftMiniTerm.lineHeight"

    // MARK: - Window frame

    static func saveWindowFrame(_ frame: NSRect) {
        let dict: [String: CGFloat] = [
            "x": frame.origin.x,
            "y": frame.origin.y,
            "w": frame.size.width,
            "h": frame.size.height
        ]
        UserDefaults.standard.set(dict, forKey: windowFrameKey)
    }

    static func loadWindowFrame() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: windowFrameKey) as? [String: CGFloat],
              let x = dict["x"], let y = dict["y"], let w = dict["w"], let h = dict["h"] else {
            return nil
        }
        return NSRect(x: x, y: y, width: max(w, 600), height: max(h, 400))
    }

    // MARK: - Recent commands

    static func appendRecentCommand(_ command: String) {
        var items = recentCommands()
        items.removeAll { $0 == command }
        items.append(command)
        if items.count > 256 {
            items.removeFirst(items.count - 256)
        }
        UserDefaults.standard.set(items, forKey: recentCommandsKey)
    }

    static func recentCommands() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentCommandsKey) ?? []
    }

    static func clearRecentCommands() {
        UserDefaults.standard.removeObject(forKey: recentCommandsKey)
    }

    // MARK: - Theme & typography

    static var theme: String {
        get { UserDefaults.standard.string(forKey: themeKey) ?? "midnight" }
        set { UserDefaults.standard.set(newValue, forKey: themeKey) }
    }

    static var fontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: fontSizeKey)
            return v > 0 ? CGFloat(v) : 13
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: fontSizeKey) }
    }

    static var lineSpacing: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: lineHeightKey)
            return v > 0 ? CGFloat(v) : 4
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: lineHeightKey) }
    }

    // MARK: - Last scrollback (small recent transcript)

    struct ScrollbackBlock: Codable {
        let id: Int
        let command: String
        let date: Date
        let cwd: String?
    }

    static func saveScrollbackBlocks(_ blocks: [ScrollbackBlock]) {
        do {
            let data = try JSONEncoder().encode(blocks.suffix(40))
            UserDefaults.standard.set(data, forKey: scrollbackKey)
        } catch {
            // ignore
        }
    }

    static func loadScrollbackBlocks() -> [ScrollbackBlock] {
        guard let data = UserDefaults.standard.data(forKey: scrollbackKey) else { return [] }
        return (try? JSONDecoder().decode([ScrollbackBlock].self, from: data)) ?? []
    }
}
