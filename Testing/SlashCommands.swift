import AppKit

// MARK: - Context + model

@MainActor
struct SlashContext {
    unowned let workspace: WorkspaceViewController
    unowned let pane: PaneController
}

@MainActor
struct SlashCommand {
    let name: String                // Always starts with "/"
    let aliases: [String]
    let summary: String
    /// Optional display usage (e.g. "/rename-tab <name>"). If nil, `name` is used.
    let usage: String?
    /// Run the command. Any non-nil return becomes a one-line toast shown in a
    /// pseudo-block above the composer.
    let run: (String, SlashContext) -> String?

    var displayUsage: String { usage ?? name }

    /// Does this command's name or any alias begin with the given prefix?
    func matches(prefix: String) -> Bool {
        let p = prefix.lowercased()
        if name.lowercased().hasPrefix(p) { return true }
        for alias in aliases where alias.lowercased().hasPrefix(p) {
            return true
        }
        return false
    }
}

// MARK: - Registry

@MainActor
enum SlashCommandRegistry {

    // The commands the app supports locally (no AI backend). Ordered roughly
    // in UX frequency so the first-match autocomplete picks sensible defaults.
    static let all: [SlashCommand] = [
        // --- Help + discovery ---
        SlashCommand(
            name: "/help",
            aliases: ["/?"],
            summary: "List every slash command",
            usage: "/help",
            run: { _, ctx in
                ctx.pane.showSlashHelp()
                return nil
            }
        ),

        // --- Window / tabs / panes ---
        SlashCommand(
            name: "/new-tab",
            aliases: ["/nt"],
            summary: "Open a new tab",
            usage: "/new-tab",
            run: { _, ctx in
                ctx.workspace.newTab(nil)
                return nil
            }
        ),
        SlashCommand(
            name: "/close-tab",
            aliases: [],
            summary: "Close the current tab",
            usage: "/close-tab",
            run: { _, ctx in
                ctx.workspace.closeTab(nil)
                return nil
            }
        ),
        SlashCommand(
            name: "/rename-tab",
            aliases: [],
            summary: "Rename the current tab",
            usage: "/rename-tab <name>",
            run: { args, ctx in
                let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return "Usage: /rename-tab <name>" }
                ctx.workspace.renameActiveTab(to: trimmed)
                return nil
            }
        ),
        SlashCommand(
            name: "/split-right",
            aliases: ["/sr"],
            summary: "Split the current pane horizontally",
            usage: "/split-right",
            run: { _, ctx in
                ctx.workspace.splitRight(nil)
                return nil
            }
        ),
        SlashCommand(
            name: "/split-down",
            aliases: ["/sd"],
            summary: "Split the current pane vertically",
            usage: "/split-down",
            run: { _, ctx in
                ctx.workspace.splitDown(nil)
                return nil
            }
        ),
        SlashCommand(
            name: "/close-pane",
            aliases: [],
            summary: "Close the current pane",
            usage: "/close-pane",
            run: { _, ctx in
                ctx.workspace.closePane(nil)
                return nil
            }
        ),

        // --- Appearance ---
        SlashCommand(
            name: "/font+",
            aliases: ["/bigger", "/zoom-in"],
            summary: "Increase font size",
            usage: "/font+",
            run: { _, ctx in
                ctx.pane.adjustFontSize(by: 1)
                return "Font size: \(Int(ctx.pane.fontSize))pt"
            }
        ),
        SlashCommand(
            name: "/font-",
            aliases: ["/smaller", "/zoom-out"],
            summary: "Decrease font size",
            usage: "/font-",
            run: { _, ctx in
                ctx.pane.adjustFontSize(by: -1)
                return "Font size: \(Int(ctx.pane.fontSize))pt"
            }
        ),

        // --- Output management ---
        SlashCommand(
            name: "/clear",
            aliases: ["/cls"],
            summary: "Clear scrollback and blocks",
            usage: "/clear",
            run: { _, ctx in
                ctx.pane.clear()
                return nil
            }
        ),
        SlashCommand(
            name: "/copy-last",
            aliases: ["/copy"],
            summary: "Copy the last block's output",
            usage: "/copy-last",
            run: { _, ctx in
                if ctx.pane.copyLastBlockOutput() {
                    return "Copied last block output to clipboard"
                }
                return "No previous block to copy"
            }
        ),
        SlashCommand(
            name: "/rerun-last",
            aliases: ["/rerun", "/r!"],
            summary: "Rerun the last command",
            usage: "/rerun-last",
            run: { _, ctx in
                if !ctx.pane.rerunLastBlock() {
                    return "No previous command to rerun"
                }
                return nil
            }
        ),
        SlashCommand(
            name: "/export-clipboard",
            aliases: ["/ec"],
            summary: "Copy entire session to the clipboard",
            usage: "/export-clipboard",
            run: { _, ctx in
                let bytes = ctx.pane.exportAllToClipboard()
                return "Exported \(bytes) bytes to clipboard"
            }
        ),
        SlashCommand(
            name: "/export-file",
            aliases: ["/ef"],
            summary: "Save session to a file",
            usage: "/export-file <path>",
            run: { args, ctx in
                let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
                let path: String
                if trimmed.isEmpty {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                    path = ("~/Desktop/terminal-\(formatter.string(from: Date())).md" as NSString)
                        .expandingTildeInPath
                } else {
                    path = (trimmed as NSString).expandingTildeInPath
                }
                do {
                    try ctx.pane.exportAllToFile(path: path)
                    return "Wrote session to \(path)"
                } catch {
                    return "Export failed: \(error.localizedDescription)"
                }
            }
        ),

        // --- Navigation ---
        SlashCommand(
            name: "/search",
            aliases: ["/find"],
            summary: "Open in-terminal search",
            usage: "/search <query>",
            run: { args, ctx in
                ctx.pane.paneView.openSearch()
                let q = args.trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty {
                    ctx.pane.paneView.setSearchQuery(q)
                    ctx.pane.paneView.searchNext(direction: .forward)
                }
                return nil
            }
        ),
        SlashCommand(
            name: "/goto",
            aliases: [],
            summary: "Scroll to a specific block",
            usage: "/goto <block-id>",
            run: { args, ctx in
                let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let id = Int(trimmed) else { return "Usage: /goto <block-id>" }
                if ctx.pane.scrollToBlock(id: id) { return nil }
                return "No block with id \(id)"
            }
        ),
        SlashCommand(
            name: "/history",
            aliases: ["/hist"],
            summary: "Show command history",
            usage: "/history",
            run: { _, ctx in
                ctx.pane.showHistoryBlock()
                return nil
            }
        ),
        SlashCommand(
            name: "/bookmark",
            aliases: ["/bm"],
            summary: "Bookmark the last block",
            usage: "/bookmark [label]",
            run: { args, ctx in
                let label = args.trimmingCharacters(in: .whitespacesAndNewlines)
                if ctx.pane.bookmarkLastBlock(label: label.isEmpty ? nil : label) {
                    return label.isEmpty ? "Bookmarked last block" : "Bookmarked as \"\(label)\""
                }
                return "No block to bookmark"
            }
        ),
        SlashCommand(
            name: "/cd",
            aliases: [],
            summary: "Change working directory (shortcut)",
            usage: "/cd <path>",
            run: { args, ctx in
                let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return "Usage: /cd <path>" }
                ctx.pane.submit(command: "cd \(trimmed)")
                return nil
            }
        )
    ]

    /// Parse a full input line into (command, args) if it matches any registered command.
    static func match(_ input: String) -> (command: SlashCommand, args: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        // Split at first whitespace — commands never contain spaces in the name.
        let firstSpace = trimmed.firstIndex(of: " ")
        let head: String
        let tail: String
        if let idx = firstSpace {
            head = String(trimmed[trimmed.startIndex..<idx])
            tail = String(trimmed[trimmed.index(after: idx)...])
        } else {
            head = trimmed
            tail = ""
        }

        let lowered = head.lowercased()
        for cmd in all {
            if cmd.name.lowercased() == lowered { return (cmd, tail) }
            if cmd.aliases.contains(where: { $0.lowercased() == lowered }) { return (cmd, tail) }
        }
        return nil
    }

    /// The best autocomplete suggestion for what the user is currently typing,
    /// or nil if no completion applies (e.g. once the user has typed a space).
    static func bestCompletion(for input: String) -> SlashCommand? {
        guard input.hasPrefix("/"), input.count > 1 else { return nil }
        if input.contains(" ") { return nil } // already into args, don't complete the name
        return all.first { $0.matches(prefix: input) }
    }
}
