import AppKit

@MainActor
final class BlockListView: NSView {
    weak var controller: PaneController?

    let horizontalInsets: CGFloat = 24
    private let cardSpacing: CGFloat = 6
    private let headerHeight: CGFloat = 26
    private let cardPaddingTop: CGFloat = 26   // = headerHeight when there is a header
    private let cardPaddingBottom: CGFloat = 10
    private let cardPaddingHorizontal: CGFloat = 14

    private(set) var metrics = TerminalMetrics(fontSize: 13, lineSpacing: 4)

    private var cardViews: [Int: BlockCardView] = [:]
    private var orderedCardIDs: [Int] = []

    // Search state
    private var searchQuery: String = ""
    private var matches: [SearchMatch] = []
    private var currentMatchIndex: Int = -1

    init(controller: PaneController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        recomputeMetricsAndLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        recomputeLayout()
    }

    func recomputeMetricsAndLayout() {
        let f = controller?.fontSize ?? 13
        let s = controller?.lineSpacing ?? 4
        metrics = TerminalMetrics(fontSize: f, lineSpacing: s)
        for v in cardViews.values {
            v.metrics = metrics
        }
        recomputeLayout()
    }

    func refreshContent() {
        guard let controller else { return }
        rebuildCardsIfNeeded()
        for block in controller.blocks {
            if let card = cardViews[block.id] {
                card.refresh()
            }
        }
        recomputeLayout()
        if !searchQuery.isEmpty {
            runSearch()
        }
        needsDisplay = true
    }

    private func rebuildCardsIfNeeded() {
        guard let controller else { return }

        let currentIDs = controller.blocks.map(\.id)
        let removed = orderedCardIDs.filter { !currentIDs.contains($0) }
        for id in removed {
            cardViews[id]?.removeFromSuperview()
            cardViews.removeValue(forKey: id)
        }

        for block in controller.blocks {
            if cardViews[block.id] == nil {
                let card = BlockCardView(block: block, controller: controller, metrics: metrics)
                cardViews[block.id] = card
                addSubview(card)
            } else {
                cardViews[block.id]?.metrics = metrics
            }
        }

        orderedCardIDs = currentIDs
    }

    func recomputeLayout() {
        guard let controller else { return }
        rebuildCardsIfNeeded()

        let width = max(bounds.width, 200)
        let cardWidth = max(width - horizontalInsets, 200)

        // First pass: measure every card. We need the total content height
        // before we can decide where to place the first one (we bottom-anchor
        // the stack when it's shorter than the viewport, so the newest block
        // always sits right above the composer like a real terminal).
        struct Placement {
            let id: Int
            let height: CGFloat
        }
        var placements: [Placement] = []
        var totalContent: CGFloat = 0
        for block in controller.blocks {
            guard cardViews[block.id] != nil else { continue }

            let lineCount: Int
            if block.isCollapsed {
                lineCount = 0
            } else if let synth = block.syntheticBody {
                lineCount = max(1, synth.components(separatedBy: "\n").count)
            } else {
                lineCount = effectiveLineCount(of: controller.blockLines(for: block))
            }

            let bodyHeight = CGFloat(max(lineCount, 0)) * metrics.lineHeight
            let cardHeight = max(cardPaddingTop + bodyHeight + cardPaddingBottom, headerHeight + 8)
            placements.append(Placement(id: block.id, height: cardHeight))
            totalContent += cardHeight + cardSpacing
        }
        if !placements.isEmpty { totalContent -= cardSpacing } // no trailing gap

        let topMargin: CGFloat = 8
        let bottomMargin: CGFloat = 8
        // Viewport the list is displayed through (the NSScrollView's clip view).
        // When the list is not inside a scroll view yet (e.g. during initial
        // sizing), fall back to our own bounds height.
        let viewportHeight = enclosingScrollView?.contentView.bounds.height ?? bounds.height

        // Pick the starting y: if the whole stack fits in the viewport, push it
        // down so the newest card hugs the bottom. Otherwise stack from the top
        // and let the scroll view handle overflow (auto-scroll-to-bottom is
        // already wired in PaneView.markGridChanged).
        let contentWithMargins = totalContent + topMargin + bottomMargin
        var y: CGFloat
        if contentWithMargins < viewportHeight {
            y = viewportHeight - totalContent - bottomMargin
        } else {
            y = topMargin
        }

        for placement in placements {
            guard let card = cardViews[placement.id] else { continue }
            card.frame = NSRect(
                x: horizontalInsets / 2,
                y: y,
                width: cardWidth,
                height: placement.height
            )
            card.metrics = metrics
            card.contentInsets = NSEdgeInsets(
                top: cardPaddingTop,
                left: cardPaddingHorizontal,
                bottom: cardPaddingBottom,
                right: cardPaddingHorizontal
            )
            card.headerHeight = headerHeight
            card.needsDisplay = true
            y += placement.height + cardSpacing
        }

        // Document height: at least the viewport so the short-stack case still
        // has proper bounds; otherwise the full content + top/bottom padding.
        let documentHeight = max(contentWithMargins, viewportHeight)
        if abs(frame.size.height - documentHeight) > 0.5 {
            frame.size = NSSize(width: width, height: documentHeight)
        }
    }

    func frameForBlock(id: Int) -> NSRect? {
        cardViews[id]?.frame
    }

    private func effectiveLineCount(of lines: [[Cell]]) -> Int {
        var n = lines.count
        while n > 0 {
            let line = lines[n - 1]
            if line.allSatisfy({ $0.character == " " || $0.character == "\u{0}" }) {
                n -= 1
            } else {
                break
            }
        }
        return n
    }

    // MARK: - Search

    func setSearchQuery(_ q: String) {
        searchQuery = q
        currentMatchIndex = -1
        runSearch()
        for card in cardViews.values {
            card.setSearchQuery(q)
        }
        needsDisplay = true
    }

    private func runSearch() {
        guard let controller else { matches = []; return }
        matches.removeAll()
        let needle = searchQuery.lowercased()
        guard !needle.isEmpty else { return }
        for block in controller.blocks {
            let lines = controller.blockLines(for: block)
            for (rowIdx, line) in lines.enumerated() {
                let text = String(line.map(\.character)).lowercased()
                var searchStart = text.startIndex
                while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
                    let col = text.distance(from: text.startIndex, to: range.lowerBound)
                    matches.append(SearchMatch(blockID: block.id, lineIndex: rowIdx, col: col, length: needle.count))
                    searchStart = range.upperBound
                    if matches.count > 5_000 { return }
                }
            }
        }
    }

    struct AdvancedSearchResult {
        var index: Int
        var total: Int
        var rect: NSRect?
    }

    func advanceSearch(direction: SearchDirection) -> AdvancedSearchResult {
        guard !matches.isEmpty else {
            return AdvancedSearchResult(index: 0, total: 0, rect: nil)
        }
        if currentMatchIndex < 0 {
            currentMatchIndex = direction == .forward ? 0 : matches.count - 1
        } else {
            currentMatchIndex = direction == .forward
                ? (currentMatchIndex + 1) % matches.count
                : (currentMatchIndex - 1 + matches.count) % matches.count
        }

        let match = matches[currentMatchIndex]
        for card in cardViews.values {
            card.setActiveMatch(nil)
        }
        if let card = cardViews[match.blockID] {
            card.setActiveMatch(match)
            card.needsDisplay = true
            let rect = card.rectFor(match: match)
            return AdvancedSearchResult(index: currentMatchIndex + 1, total: matches.count, rect: rect)
        }
        return AdvancedSearchResult(index: currentMatchIndex + 1, total: matches.count, rect: nil)
    }
}

// MARK: - Match model

struct SearchMatch: Equatable {
    let blockID: Int
    let lineIndex: Int
    let col: Int
    let length: Int
}

// MARK: - Metrics

struct TerminalMetrics {
    let font: NSFont
    let boldFont: NSFont
    let italicFont: NSFont
    let lineHeight: CGFloat
    let charWidth: CGFloat

    init(fontSize: CGFloat, lineSpacing: CGFloat) {
        let f = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.font = f
        self.boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        if let descriptor = f.fontDescriptor.withSymbolicTraits(.italic) as NSFontDescriptor? {
            self.italicFont = NSFont(descriptor: descriptor, size: fontSize) ?? f
        } else {
            self.italicFont = f
        }
        let charSize = ("M" as NSString).size(withAttributes: [.font: f])
        self.charWidth = ceil(charSize.width)
        let lineH = ceil(f.ascender - f.descender + f.leading) + lineSpacing
        self.lineHeight = lineH
    }
}

// MARK: - Block card view

@MainActor
final class BlockCardView: NSView {
    weak var block: CommandBlock?
    weak var controller: PaneController?

    var metrics: TerminalMetrics
    var contentInsets = NSEdgeInsets(top: 26, left: 14, bottom: 10, right: 14)
    var headerHeight: CGFloat = 26

    private var disclosureRect: NSRect = .zero

    private var searchQuery: String = ""
    private var activeMatch: SearchMatch?

    private var cachedLines: [[Cell]] = []

    init(block: CommandBlock, controller: PaneController, metrics: TerminalMetrics) {
        self.block = block
        self.controller = controller
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func refresh() {
        applyTheme()
        needsDisplay = true
    }

    func setSearchQuery(_ q: String) {
        searchQuery = q
        if q.isEmpty { activeMatch = nil }
        needsDisplay = true
    }

    func setActiveMatch(_ match: SearchMatch?) {
        activeMatch = match
    }

    private func applyTheme() {
        guard let controller, let block else { return }
        let isActive = controller.isBlockActive(block)
        let bg = NSColor(srgbRed: 0.075, green: 0.090, blue: 0.115, alpha: 0.95)
        layer?.backgroundColor = bg.cgColor
        if isActive {
            layer?.borderColor = NSColor(srgbRed: 0.32, green: 0.78, blue: 0.96, alpha: 0.55).cgColor
        } else if block.exitCode == 0 {
            layer?.borderColor = NSColor(srgbRed: 0.30, green: 0.50, blue: 0.36, alpha: 0.40).cgColor
        } else if let code = block.exitCode, code != 0 {
            layer?.borderColor = NSColor(srgbRed: 0.62, green: 0.27, blue: 0.27, alpha: 0.55).cgColor
        } else {
            layer?.borderColor = NSColor(srgbRed: 0.16, green: 0.19, blue: 0.24, alpha: 0.85).cgColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let block else { return }
        applyTheme()

        drawHeader(block: block, isActive: controller.isBlockActive(block))

        if block.isCollapsed { return }

        let bodyOrigin = NSPoint(x: contentInsets.left, y: contentInsets.top)

        // Synthetic (locally-generated) blocks like /help or /history just render
        // their body as plain text.
        if let synth = block.syntheticBody {
            drawSyntheticBody(synth, origin: bodyOrigin)
            return
        }

        let lines = controller.blockLines(for: block)
        cachedLines = lines
        let trimmedCount = effectiveLineCount(of: lines)

        if controller.isBlockActive(block), controller.grid.cursorVisible {
            drawCursorHighlight(block: block, lineCount: trimmedCount, origin: bodyOrigin)
        }

        for rowIdx in 0..<trimmedCount {
            let line = lines[rowIdx]
            let y = bodyOrigin.y + CGFloat(rowIdx) * metrics.lineHeight
            drawRow(line: line, y: y, x: bodyOrigin.x, blockID: block.id, rowIdx: rowIdx)
        }

        if controller.isBlockActive(block), controller.grid.cursorVisible {
            drawCaret(block: block, lineCount: trimmedCount, origin: bodyOrigin)
        }
    }

    private func drawSyntheticBody(_ text: String, origin: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: metrics.font,
            .foregroundColor: NSColor(srgbRed: 0.85, green: 0.90, blue: 0.98, alpha: 1.0)
        ]
        for (idx, line) in text.components(separatedBy: "\n").enumerated() {
            let y = origin.y + CGFloat(idx) * metrics.lineHeight
            (line as NSString).draw(at: NSPoint(x: origin.x, y: y), withAttributes: attrs)
        }
    }

    private func effectiveLineCount(of lines: [[Cell]]) -> Int {
        var n = lines.count
        while n > 0 {
            if lines[n - 1].allSatisfy({ $0.character == " " || $0.character == "\u{0}" }) { n -= 1 } else { break }
        }
        return n
    }

    private func drawHeader(block: CommandBlock, isActive: Bool) {
        let headerRect = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)

        // Subtle header background
        NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.85).setFill()
        NSBezierPath(rect: headerRect).fill()

        // Status dot (smaller, left)
        drawStatusDot(block: block, isActive: isActive, at: NSPoint(x: 12, y: (headerHeight - 8) / 2))

        // Disclosure chevron (clickable to collapse/expand)
        let chevronSize: CGFloat = 14
        let chevronY = (headerHeight - chevronSize) / 2
        let chevronRect = NSRect(x: 26, y: chevronY, width: chevronSize, height: chevronSize)
        disclosureRect = chevronRect
        drawDisclosure(in: chevronRect, expanded: !block.isCollapsed)

        // Command title
        let title = block.command.isEmpty ? "shell" : block.command
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.92, green: 0.95, blue: 0.99, alpha: 1.0)
        ]
        let truncated = title.count > 100 ? String(title.prefix(100)) + "…" : title
        let titlePoint = NSPoint(x: 46, y: (headerHeight - 14) / 2)
        (truncated as NSString).draw(at: titlePoint, withAttributes: titleAttrs)

        // Right-side meta (bookmark · cwd · time · exit · #id)
        var metaPieces: [String] = []
        if let label = block.bookmarkLabel {
            let truncatedLabel = label.count > 24 ? String(label.prefix(24)) + "…" : label
            metaPieces.append("★ \(truncatedLabel)")
        }
        if let cwd = block.cwd {
            let last = (cwd as NSString).lastPathComponent
            metaPieces.append(last.isEmpty ? "/" : last)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        metaPieces.append(formatter.string(from: block.createdAt))
        if let exit = block.exitCode, block.syntheticBody == nil {
            metaPieces.append("exit \(exit)")
        }
        metaPieces.append("#\(block.id)")
        let metaText = metaPieces.joined(separator: " · ")
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.55, green: 0.62, blue: 0.74, alpha: 1.0)
        ]
        let metaSize = (metaText as NSString).size(withAttributes: metaAttrs)
        let metaPoint = NSPoint(x: bounds.width - metaSize.width - 14, y: (headerHeight - metaSize.height) / 2)
        if metaPoint.x > 200 {
            (metaText as NSString).draw(at: metaPoint, withAttributes: metaAttrs)
        }

        // Hairline at bottom of header
        let hairline = NSBezierPath()
        hairline.move(to: NSPoint(x: 0, y: headerHeight))
        hairline.line(to: NSPoint(x: bounds.width, y: headerHeight))
        NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1.0).setStroke()
        hairline.lineWidth = 1
        hairline.stroke()
    }

    private func drawStatusDot(block: CommandBlock, isActive: Bool, at origin: NSPoint) {
        let rect = NSRect(x: origin.x, y: origin.y, width: 8, height: 8)
        let path = NSBezierPath(ovalIn: rect)
        let color: NSColor
        if isActive {
            color = NSColor(srgbRed: 0.32, green: 0.78, blue: 0.96, alpha: 1.0)
        } else if let code = block.exitCode {
            color = code == 0
                ? NSColor(srgbRed: 0.40, green: 0.83, blue: 0.50, alpha: 1.0)
                : NSColor(srgbRed: 0.96, green: 0.40, blue: 0.40, alpha: 1.0)
        } else {
            color = NSColor(srgbRed: 0.55, green: 0.62, blue: 0.74, alpha: 1.0)
        }
        color.setFill()
        path.fill()
    }

    private func drawDisclosure(in rect: NSRect, expanded: Bool) {
        let path = NSBezierPath()
        let inset: CGFloat = 3
        if expanded {
            // Down-pointing chevron ▾
            path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset + 2))
            path.line(to: NSPoint(x: rect.midX,        y: rect.maxY - inset - 1))
            path.line(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset + 2))
        } else {
            // Right-pointing chevron ▸
            path.move(to: NSPoint(x: rect.minX + inset + 2, y: rect.minY + inset))
            path.line(to: NSPoint(x: rect.maxX - inset - 1, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX + inset + 2, y: rect.maxY - inset))
        }
        NSColor(srgbRed: 0.66, green: 0.72, blue: 0.82, alpha: 0.90).setStroke()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawRow(line: [Cell], y: CGFloat, x: CGFloat, blockID: Int, rowIdx: Int) {
        guard !line.isEmpty else { return }
        let runs = collapseRuns(line)

        var cursorX = x
        for run in runs {
            let attrs = attributesFor(cellAttrs: run.attrs)
            let text = run.text as NSString
            let size = text.size(withAttributes: attrs)
            // Background
            if case .default = run.attrs.bg, !run.attrs.inverse {
                // No bg fill needed
            } else {
                let bgColor: NSColor
                if run.attrs.inverse {
                    bgColor = TerminalPalette.nsColor(for: run.attrs.fg, attrs: run.attrs, isBackground: false)
                } else {
                    bgColor = TerminalPalette.nsColor(for: run.attrs.bg, attrs: run.attrs, isBackground: true)
                }
                bgColor.setFill()
                NSRect(x: cursorX, y: y, width: size.width, height: metrics.lineHeight).fill()
            }
            text.draw(at: NSPoint(x: cursorX, y: y + (metrics.lineHeight - size.height) / 2), withAttributes: attrs)
            cursorX += size.width
        }

        if !searchQuery.isEmpty {
            let lowered = String(line.map(\.character)).lowercased()
            let needle = searchQuery.lowercased()
            var startIndex = lowered.startIndex
            while let range = lowered.range(of: needle, range: startIndex..<lowered.endIndex) {
                let col = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
                let highlightX = x + CGFloat(col) * metrics.charWidth
                let highlightWidth = CGFloat(needle.count) * metrics.charWidth
                let isActive = activeMatch?.blockID == blockID && activeMatch?.lineIndex == rowIdx && activeMatch?.col == col
                let color = isActive
                    ? NSColor(srgbRed: 0.96, green: 0.78, blue: 0.30, alpha: 0.55)
                    : NSColor(srgbRed: 0.96, green: 0.85, blue: 0.30, alpha: 0.30)
                color.setFill()
                NSRect(x: highlightX, y: y, width: highlightWidth, height: metrics.lineHeight).fill()
                startIndex = range.upperBound
            }
        }
    }

    private struct StyleRun {
        var text: String
        var attrs: CellAttrs
    }

    private func collapseRuns(_ line: [Cell]) -> [StyleRun] {
        guard let first = line.first else { return [] }
        var runs: [StyleRun] = []
        var current = StyleRun(text: String(first.character), attrs: first.attrs)
        for cell in line.dropFirst() {
            if cell.attrs == current.attrs {
                current.text.append(cell.character)
            } else {
                runs.append(current)
                current = StyleRun(text: String(cell.character), attrs: cell.attrs)
            }
        }
        runs.append(current)
        return runs
    }

    private func attributesFor(cellAttrs: CellAttrs) -> [NSAttributedString.Key: Any] {
        let font: NSFont
        if cellAttrs.italic && cellAttrs.bold {
            if let d = metrics.boldFont.fontDescriptor.withSymbolicTraits(.italic) as NSFontDescriptor? {
                font = NSFont(descriptor: d, size: metrics.boldFont.pointSize) ?? metrics.boldFont
            } else {
                font = metrics.boldFont
            }
        } else if cellAttrs.bold {
            font = metrics.boldFont
        } else if cellAttrs.italic {
            font = metrics.italicFont
        } else {
            font = metrics.font
        }

        let fg: NSColor
        if cellAttrs.inverse {
            fg = TerminalPalette.nsColor(for: cellAttrs.bg, attrs: cellAttrs, isBackground: true) == .clear
                ? TerminalPalette.defaultBackground
                : TerminalPalette.nsColor(for: cellAttrs.bg, attrs: cellAttrs, isBackground: true)
        } else {
            fg = TerminalPalette.nsColor(for: cellAttrs.fg, attrs: cellAttrs, isBackground: false)
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg
        ]
        if cellAttrs.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = fg
        }
        return attrs
    }

    private func drawCursorHighlight(block: CommandBlock, lineCount: Int, origin: NSPoint) {
        guard let controller else { return }
        let cursorGlobal = controller.grid.scrollback.count + controller.grid.cursorRow
        let row = cursorGlobal - block.startGlobalLine
        guard row >= 0, row < lineCount else { return }
        let x = origin.x + CGFloat(controller.grid.cursorCol) * metrics.charWidth
        let y = origin.y + CGFloat(row) * metrics.lineHeight
        NSColor(srgbRed: 0.32, green: 0.78, blue: 0.96, alpha: 0.18).setFill()
        NSRect(x: x, y: y, width: metrics.charWidth, height: metrics.lineHeight).fill()
    }

    private func drawCaret(block: CommandBlock, lineCount: Int, origin: NSPoint) {
        guard let controller else { return }
        let cursorGlobal = controller.grid.scrollback.count + controller.grid.cursorRow
        let row = cursorGlobal - block.startGlobalLine
        guard row >= 0, row < lineCount else { return }
        let x = origin.x + CGFloat(controller.grid.cursorCol) * metrics.charWidth
        let y = origin.y + CGFloat(row) * metrics.lineHeight
        NSColor(srgbRed: 0.40, green: 0.86, blue: 1.00, alpha: 0.85).setFill()
        NSRect(x: x, y: y, width: 2, height: metrics.lineHeight - 2).fill()
    }

    func rectFor(match: SearchMatch) -> NSRect {
        let x = contentInsets.left + CGFloat(match.col) * metrics.charWidth
        let y = contentInsets.top + CGFloat(match.lineIndex) * metrics.lineHeight
        let width = CGFloat(match.length) * metrics.charWidth
        let local = NSRect(x: x, y: y, width: width, height: metrics.lineHeight)
        return convert(local, to: superview)
    }

    // MARK: - Hit testing

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)

        // Single click on the disclosure chevron toggles collapse
        if disclosureRect.insetBy(dx: -4, dy: -4).contains(local) {
            if let block { controller?.toggleCollapse(blockID: block.id) }
            return
        }

        // Activate this pane on click
        if let controller, let workspace = controller.workspace {
            workspace.setActivePane(controller)
        }

        // Double-click on header toggles collapse
        if event.clickCount >= 2, local.y < headerHeight {
            if let block { controller?.toggleCollapse(blockID: block.id) }
            return
        }

        super.mouseDown(with: event)
    }

    // MARK: - Context menu (right-click)

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let block else { return nil }
        let menu = NSMenu()

        let copy = NSMenuItem(title: "Copy Output", action: #selector(menuCopyOutput), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        let copyCmd = NSMenuItem(title: "Copy Command", action: #selector(menuCopyCommand), keyEquivalent: "")
        copyCmd.target = self
        copyCmd.isEnabled = !block.command.isEmpty
        menu.addItem(copyCmd)

        let rerun = NSMenuItem(title: "Rerun", action: #selector(menuRerun), keyEquivalent: "")
        rerun.target = self
        rerun.isEnabled = !block.command.isEmpty
        menu.addItem(rerun)

        menu.addItem(.separator())

        let collapse = NSMenuItem(
            title: block.isCollapsed ? "Expand" : "Collapse",
            action: #selector(menuToggleCollapse),
            keyEquivalent: ""
        )
        collapse.target = self
        menu.addItem(collapse)

        return menu
    }

    @objc private func menuCopyOutput() {
        guard let block, let controller else { return }
        controller.copyBlockOutput(block)
    }

    @objc private func menuCopyCommand() {
        guard let block else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(block.command, forType: .string)
    }

    @objc private func menuRerun() {
        guard let block, let controller else { return }
        controller.rerunBlock(block)
    }

    @objc private func menuToggleCollapse() {
        guard let block, let controller else { return }
        controller.toggleCollapse(blockID: block.id)
    }
}
