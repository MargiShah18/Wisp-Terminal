import AppKit

@MainActor
final class CommandBlock {
    let id: Int
    var command: String
    let createdAt: Date
    var finishedAt: Date?
    var exitCode: Int?
    var isCollapsed: Bool = false
    var cwd: String?
    var bookmarkLabel: String?
    /// Pseudo-block content produced locally by slash commands (e.g. /help).
    /// When non-nil, the BlockCardView renders this instead of grid lines.
    var syntheticBody: String?

    /// Inclusive global line index in the grid (scrollback + screen) where this block starts.
    var startGlobalLine: Int
    /// Inclusive global line index where the block ends (nil while open).
    var endGlobalLine: Int?

    var cachedHeight: CGFloat?
    var cachedAttributedContent: NSAttributedString?
    var cachedSearchHighlights: [(NSRange, Int)] = []

    init(id: Int, command: String, startGlobalLine: Int, cwd: String?) {
        self.id = id
        self.command = command
        self.createdAt = Date()
        self.startGlobalLine = startGlobalLine
        self.cwd = cwd
    }

    var isOpen: Bool { endGlobalLine == nil }
}

@MainActor
final class PaneController {
    let id = UUID()
    weak var workspace: WorkspaceViewController?

    let session = PTYSession()
    let grid: TerminalGrid
    let emulator: TerminalEmulator

    private(set) var blocks: [CommandBlock] = []
    private var nextBlockID = 1
    private var activeBlock: CommandBlock?
    var cwd: String?

    private(set) var commandHistory: [String] = []
    private var historyIndex: Int? = nil
    private(set) var isAlive: Bool = true

    private var lastResizeCols: Int = 0
    private var lastResizeRows: Int = 0

    var fontSize: CGFloat = 13
    var lineSpacing: CGFloat = 4

    private var pendingRefresh: Bool = false
    private var cwdPollWorkItem: DispatchWorkItem?

    lazy var paneView: PaneView = PaneView(controller: self)

    init(workspace: WorkspaceViewController) {
        self.workspace = workspace
        let initialGrid = TerminalGrid(rows: 24, cols: 80)
        self.grid = initialGrid
        self.emulator = TerminalEmulator(grid: initialGrid)
        self.fontSize = SessionRestore.fontSize
        self.lineSpacing = SessionRestore.lineSpacing
        self.commandHistory = SessionRestore.recentCommands()
        configureCallbacks()
    }

    private func configureCallbacks() {
        session.onOutput = { [weak self] data in
            guard let self else { return }
            self.handlePTYOutput(data)
        }
        session.onExit = { [weak self] _ in
            guard let self else { return }
            self.isAlive = false
            self.handlePTYOutput(Data("\r\n[Process exited]\r\n".utf8))
        }
        emulator.onResponse = { [weak self] data in
            self?.session.write(data)
        }
        emulator.onTitleChange = { [weak self] title in
            guard let self, let workspace = self.workspace, let tab = workspace.activeTab else { return }
            workspace.updateTitle(for: tab, title)
        }
        emulator.onCwdChange = { [weak self] cwd in
            self?.applyCwdChange(cwd)
        }
        emulator.onCommandFinished = { [weak self] exit in
            self?.activeBlock?.exitCode = exit
            self?.activeBlock?.finishedAt = Date()
        }
    }

    private func handlePTYOutput(_ data: Data) {
        emulator.feed(data)
        adjustBlockIndicesForScrollbackTrim()
        invalidateActiveBlockCache()
        scheduleRefresh()
        schedulePidCwdPoll()
    }

    func start() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let homeDir = NSHomeDirectory()
        let cols = max(grid.cols, 80)
        let rows = max(grid.rows, 24)
        session.start(
            shellPath: shell,
            arguments: [],
            cols: cols,
            rows: rows,
            workingDirectory: homeDir
        )
        applyCwdChange(homeDir)
    }

    func close() {
        session.stop()
    }

    func resize(cols: Int, rows: Int) {
        let c = max(cols, 20)
        let r = max(rows, 4)
        guard c != lastResizeCols || r != lastResizeRows else { return }
        lastResizeCols = c
        lastResizeRows = r
        grid.resize(rows: r, cols: c)
        session.resize(cols: c, rows: r)
        invalidateAllBlockCaches()
        scheduleRefresh()
    }

    func submit(command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            session.write("\r")
            return
        }
        commandHistory.removeAll { $0 == trimmed }
        commandHistory.append(trimmed)
        if commandHistory.count > 512 {
            commandHistory.removeFirst(commandHistory.count - 512)
        }
        SessionRestore.appendRecentCommand(trimmed)
        historyIndex = nil

        // Cursor is currently at the prompt the shell drew. We capture that row,
        // close the previous block one row above (excluding the prompt), and open
        // the new block one row below (where the echo lands after \r\n).
        let promptRow = grid.scrollback.count + grid.cursorRow
        closeActiveBlock(endingAt: promptRow - 1)
        startNewBlock(forCommand: trimmed, startingAt: promptRow + 1)

        session.write(trimmed + "\r")
        paneView.requestScrollToBottom()
        scheduleRefresh()
    }

    func sendInterrupt() {
        session.sendInterrupt()
    }

    func clear() {
        grid.reset()
        blocks.removeAll()
        nextBlockID = 1
        activeBlock = nil
        scheduleRefresh()
    }

    func adjustFontSize(by delta: CGFloat) {
        let newSize = max(10, min(28, fontSize + delta))
        guard newSize != fontSize else { return }
        fontSize = newSize
        SessionRestore.fontSize = newSize
        invalidateAllBlockCaches()
        paneView.fontDidChange()
    }

    func sendRawData(_ data: Data) {
        session.write(data)
    }

    func sendRawString(_ s: String) {
        session.write(s)
    }

    // MARK: - Blocks

    private func startNewBlock(forCommand command: String, startingAt start: Int) {
        let block = CommandBlock(id: nextBlockID, command: command, startGlobalLine: max(0, start), cwd: cwd)
        nextBlockID += 1
        blocks.append(block)
        activeBlock = block
    }

    private func closeActiveBlock(endingAt end: Int) {
        guard let active = activeBlock else { return }
        // IMPORTANT: do NOT clamp to `startGlobalLine` here. Commands that
        // produce no output at all (`cd`, `export`, `true`, anything silent)
        // will have `end < start` because the shell draws the very next
        // prompt on the row we reserved for output. Clamping would force
        // that next-prompt row into this block's body, showing garbage
        // like `user@host ~ % <next command>`. `blockLines(for:)` already
        // handles `start > end` as "empty body", so just let the caller's
        // number through.
        active.endGlobalLine = end
        active.cachedAttributedContent = nil
        active.cachedHeight = nil
        activeBlock = nil
    }

    func toggleCollapse(blockID: Int) {
        if let block = blocks.first(where: { $0.id == blockID }) {
            block.isCollapsed.toggle()
            paneView.invalidateLayout()
        }
    }

    func copyBlockOutput(_ block: CommandBlock) {
        let text = plainText(for: block)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func rerunBlock(_ block: CommandBlock) {
        guard !block.command.isEmpty else { return }
        submit(command: block.command)
    }

    /// Plain-text extraction of a block's contents (synthetic body or grid lines).
    func plainText(for block: CommandBlock) -> String {
        if let synth = block.syntheticBody {
            return synth
        }
        let lines = blockLines(for: block)
        let raw = lines.map { line -> String in
            String(line.map(\.character))
        }
        let trimmedRows = raw.map { $0.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
        return trimmedRows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Slash command helpers

    /// Returns the block the user would most likely consider "the last command".
    /// Prefers the most recent closed block (with a command); falls back to the
    /// currently active one if that's the only thing we've got.
    private var lastUserBlock: CommandBlock? {
        for block in blocks.reversed() where !block.command.isEmpty {
            return block
        }
        return nil
    }

    @discardableResult
    func copyLastBlockOutput() -> Bool {
        guard let block = lastUserBlock else { return false }
        copyBlockOutput(block)
        return true
    }

    @discardableResult
    func rerunLastBlock() -> Bool {
        guard let block = lastUserBlock else { return false }
        rerunBlock(block)
        return true
    }

    @discardableResult
    func bookmarkLastBlock(label: String?) -> Bool {
        guard let block = lastUserBlock else { return false }
        block.bookmarkLabel = label ?? block.command
        block.cachedAttributedContent = nil
        scheduleRefresh()
        return true
    }

    @discardableResult
    func scrollToBlock(id: Int) -> Bool {
        guard blocks.contains(where: { $0.id == id }) else { return false }
        paneView.scrollToBlock(id: id)
        return true
    }

    @discardableResult
    func exportAllToClipboard() -> Int {
        let text = composeFullTranscript()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return text.utf8.count
    }

    func exportAllToFile(path: String) throws {
        let text = composeFullTranscript()
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func composeFullTranscript() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out: [String] = []
        out.append("# Terminal transcript — \(formatter.string(from: Date()))\n")
        for block in blocks {
            let header = block.command.isEmpty ? "(session)" : block.command
            out.append("## \(header)")
            if let cwd = block.cwd { out.append("- cwd: `\(cwd)`") }
            if let exit = block.exitCode { out.append("- exit: \(exit)") }
            out.append("")
            out.append("```")
            out.append(plainText(for: block))
            out.append("```")
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// Insert a synthetic block showing the full slash-command help.
    func showSlashHelp() {
        let body = SlashCommandRegistry.all
            .map { cmd in
                let padded = cmd.displayUsage.padding(toLength: max(24, cmd.displayUsage.count + 2), withPad: " ", startingAt: 0)
                return "  \(padded) \(cmd.summary)"
            }
            .joined(separator: "\n")

        let text = "Slash commands — type / in the composer, Tab to accept, Enter to run\n\n\(body)\n"
        appendSyntheticBlock(title: "/help", body: text)
    }

    func showHistoryBlock() {
        let recent = commandHistory.suffix(40)
        let lines = recent.enumerated().map { idx, cmd in
            String(format: "  %3d  %@", commandHistory.count - recent.count + idx + 1, cmd)
        }
        let body = lines.isEmpty ? "No commands yet." : lines.joined(separator: "\n")
        appendSyntheticBlock(title: "/history", body: body)
    }

    /// Shows a small toast block with a transient message (used for command feedback).
    func showToast(_ message: String) {
        appendSyntheticBlock(title: "/", body: message)
    }

    /// Record a slash command in the up/down history so the user can recall it
    /// with the arrow keys like any other command.
    func recordSlashCommandInHistory(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commandHistory.removeAll { $0 == trimmed }
        commandHistory.append(trimmed)
        if commandHistory.count > 512 {
            commandHistory.removeFirst(commandHistory.count - 512)
        }
        SessionRestore.appendRecentCommand(trimmed)
        historyIndex = nil
    }

    private func appendSyntheticBlock(title: String, body: String) {
        let start = grid.scrollback.count + grid.cursorRow
        // Close any open block so history sequencing stays clean.
        closeActiveBlock(endingAt: max((activeBlock?.startGlobalLine ?? start), start - 1))

        let block = CommandBlock(id: nextBlockID, command: title, startGlobalLine: start, cwd: cwd)
        block.syntheticBody = body
        block.endGlobalLine = start - 1   // no grid content
        block.exitCode = 0
        block.finishedAt = Date()
        nextBlockID += 1
        blocks.append(block)
        paneView.requestScrollToBottom()
        scheduleRefresh()
    }

    func blockLines(for block: CommandBlock) -> [[Cell]] {
        let start = max(block.startGlobalLine, 0)

        // Work out the end-of-block line. For closed blocks we trust the stored
        // end index. For OPEN (active) blocks the shell has already drawn its
        // next prompt right at the cursor — so we clip the block to one line
        // above the cursor, which is the cleanest possible signal of "where
        // the real command output ended".
        let rawEnd: Int
        if let explicit = block.endGlobalLine {
            rawEnd = explicit
        } else {
            let cursorGlobal = grid.scrollback.count + grid.cursorRow
            rawEnd = cursorGlobal - 1
        }
        let end = min(rawEnd, max(grid.totalLineCount - 1, 0))
        guard start <= end else { return [] }

        var result: [[Cell]] = []
        result.reserveCapacity(end - start + 1)
        for i in start...end {
            result.append(grid.line(at: i))
        }
        return trimShellNoise(from: result, command: block.command)
    }

    /// Strip the redundant "chrome" the shell draws around every command:
    ///
    ///   1. A leading line that merely echoes the command we just submitted
    ///      (the block header already shows it, so seeing e.g. `ls` above
    ///      the actual `ls` output is pure noise).
    ///   2. Trailing blank lines (the grid pads to row count).
    ///   3. ONE trailing prompt-looking line (defense-in-depth against shell
    ///      setups whose prompt doesn't sit on the cursor row — e.g. multi-
    ///      line prompts, starship's two-line style, or precmd hooks that
    ///      print an extra status line after the command).
    private func trimShellNoise(from lines: [[Cell]], command: String) -> [[Cell]] {
        var out = lines

        if let first = out.first {
            let text = cellsToTrimmedString(first)
            if text == command.trimmingCharacters(in: .whitespaces) {
                out.removeFirst()
            }
        }

        // Trailing blank lines: unlimited — they're never real output.
        while let last = out.last, cellsToTrimmedString(last).isEmpty {
            out.removeLast()
        }

        // Trailing prompt line: at most one. The terminators below cover the
        // common shells and popular custom prompts (starship's `❯`, oh-my-zsh
        // style `➜`, etc.). Capping at one keeps us from ever stripping more
        // than a single line of real output in the pathological case.
        if let last = out.last, isPromptLine(last) {
            out.removeLast()
            while let next = out.last, cellsToTrimmedString(next).isEmpty {
                out.removeLast()
            }
        }

        return out
    }

    private func cellsToTrimmedString(_ cells: [Cell]) -> String {
        var s = String(cells.map(\.character))
        while let c = s.last, c == "\u{0}" {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func isPromptLine(_ cells: [Cell]) -> Bool {
        let text = cellsToTrimmedString(cells)
        guard !text.isEmpty, let last = text.last else { return false }
        return "%$#>❯➜→▶»".contains(last)
    }

    func isBlockActive(_ block: CommandBlock) -> Bool {
        block === activeBlock
    }

    var liveBlock: CommandBlock? { activeBlock }

    // MARK: - History

    func historyPrevious(currentInput: String) -> String? {
        guard !commandHistory.isEmpty else { return nil }
        if historyIndex == nil {
            historyIndex = commandHistory.count - 1
        } else if let idx = historyIndex, idx > 0 {
            historyIndex = idx - 1
        }
        return commandHistory[historyIndex!]
    }

    func historyNext() -> String? {
        guard let idx = historyIndex else { return nil }
        if idx < commandHistory.count - 1 {
            historyIndex = idx + 1
            return commandHistory[historyIndex!]
        }
        historyIndex = nil
        return ""
    }

    // MARK: - Refresh throttling

    private func scheduleRefresh() {
        if pendingRefresh { return }
        pendingRefresh = true
        let interval: TimeInterval = 1.0 / 60.0
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            self.pendingRefresh = false
            self.paneView.markGridChanged()
        }
    }

    private func adjustBlockIndicesForScrollbackTrim() {
        let trim = grid.lastScrollbackTrim
        if trim == 0 { return }
        if trim == Int.max {
            for b in blocks {
                b.startGlobalLine = 0
                if b.endGlobalLine != nil { b.endGlobalLine = 0 }
                b.cachedAttributedContent = nil
                b.cachedHeight = nil
            }
            grid.clearDirty()
            return
        }
        for b in blocks {
            b.startGlobalLine = max(0, b.startGlobalLine - trim)
            if let e = b.endGlobalLine {
                b.endGlobalLine = max(0, e - trim)
            }
        }
        grid.clearDirty()
    }

    private func invalidateActiveBlockCache() {
        activeBlock?.cachedAttributedContent = nil
        activeBlock?.cachedHeight = nil
    }

    private func invalidateAllBlockCaches() {
        for b in blocks {
            b.cachedAttributedContent = nil
            b.cachedHeight = nil
        }
    }

    // MARK: - CWD tracking
    //
    // OSC 7 is the nice path (shell emits file:// on every prompt), but most
    // default zsh setups outside Apple's Terminal.app don't emit it. We
    // supplement by asking the kernel for the shell's real cwd whenever PTY
    // output goes quiet, with a short debounce so we don't hammer syscalls.

    private func applyCwdChange(_ newCwd: String) {
        if cwd == newCwd { return }
        cwd = newCwd
        paneView.updateCwd(newCwd)
        FrecencyStore.bump(newCwd)
    }

    private func schedulePidCwdPoll() {
        cwdPollWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pollPidCwd()
        }
        cwdPollWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func pollPidCwd() {
        let pid = session.childPid
        guard pid > 0, let newCwd = ProcInfo.cwd(ofPid: pid) else { return }
        applyCwdChange(newCwd)
    }
}
