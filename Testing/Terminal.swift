import AppKit

// MARK: - Color model

enum TermColor: Equatable, Hashable {
    case `default`
    case palette(Int)            // 0..255 (0..15 = ANSI, 16..231 = 6x6x6 cube, 232..255 = grayscale)
    case rgb(UInt8, UInt8, UInt8)
}

struct CellAttrs: Equatable, Hashable {
    var fg: TermColor = .default
    var bg: TermColor = .default
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var inverse: Bool = false
    var faint: Bool = false

    static let `default` = CellAttrs()
}

struct Cell: Equatable {
    var character: Character
    var attrs: CellAttrs

    static let blank = Cell(character: " ", attrs: .default)
}

// MARK: - Palette helpers (UI thread only)

@MainActor
enum TerminalPalette {
    static let defaultForeground = NSColor(srgbRed: 0.92, green: 0.94, blue: 0.96, alpha: 1.0)
    static let defaultBackground = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
    static let dimForeground = NSColor(srgbRed: 0.62, green: 0.66, blue: 0.71, alpha: 1.0)

    private static let ansi16: [NSColor] = [
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0), // 0  black
        NSColor(srgbRed: 0.92, green: 0.36, blue: 0.36, alpha: 1.0), // 1  red
        NSColor(srgbRed: 0.40, green: 0.83, blue: 0.45, alpha: 1.0), // 2  green
        NSColor(srgbRed: 0.95, green: 0.78, blue: 0.36, alpha: 1.0), // 3  yellow
        NSColor(srgbRed: 0.40, green: 0.62, blue: 0.96, alpha: 1.0), // 4  blue
        NSColor(srgbRed: 0.81, green: 0.51, blue: 0.94, alpha: 1.0), // 5  magenta
        NSColor(srgbRed: 0.36, green: 0.83, blue: 0.86, alpha: 1.0), // 6  cyan
        NSColor(srgbRed: 0.86, green: 0.88, blue: 0.90, alpha: 1.0), // 7  white
        NSColor(srgbRed: 0.46, green: 0.50, blue: 0.55, alpha: 1.0), // 8  bright black
        NSColor(srgbRed: 1.00, green: 0.50, blue: 0.50, alpha: 1.0), // 9  bright red
        NSColor(srgbRed: 0.62, green: 0.95, blue: 0.55, alpha: 1.0), // 10 bright green
        NSColor(srgbRed: 1.00, green: 0.88, blue: 0.50, alpha: 1.0), // 11 bright yellow
        NSColor(srgbRed: 0.55, green: 0.78, blue: 1.00, alpha: 1.0), // 12 bright blue
        NSColor(srgbRed: 0.92, green: 0.69, blue: 1.00, alpha: 1.0), // 13 bright magenta
        NSColor(srgbRed: 0.55, green: 0.94, blue: 0.96, alpha: 1.0), // 14 bright cyan
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1.0)  // 15 bright white
    ]

    static func nsColor(for color: TermColor, attrs: CellAttrs, isBackground: Bool) -> NSColor {
        switch color {
        case .default:
            if isBackground {
                return NSColor.clear
            }
            if attrs.bold {
                return NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            }
            return attrs.faint ? dimForeground : defaultForeground
        case .palette(let i):
            return paletteColor(i, attrs: attrs)
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1.0)
        }
    }

    private static func paletteColor(_ index: Int, attrs: CellAttrs) -> NSColor {
        let i = max(0, min(index, 255))
        if i < 16 {
            // Apply bold->bright shift like xterm
            if attrs.bold && i < 8 {
                return ansi16[i + 8]
            }
            return ansi16[i]
        }
        if i < 232 {
            let n = i - 16
            let r = n / 36
            let g = (n / 6) % 6
            let b = n % 6
            let comp: (Int) -> CGFloat = { c in c == 0 ? 0.0 : CGFloat(55 + 40 * c) / 255.0 }
            return NSColor(srgbRed: comp(r), green: comp(g), blue: comp(b), alpha: 1.0)
        }
        let v = CGFloat(8 + 10 * (i - 232)) / 255.0
        return NSColor(srgbRed: v, green: v, blue: v, alpha: 1.0)
    }
}

// MARK: - Terminal grid

@MainActor
final class TerminalGrid {
    private(set) var rows: Int
    private(set) var cols: Int

    private(set) var lines: [[Cell]]
    private(set) var scrollback: [[Cell]] = []

    var cursorRow: Int = 0
    var cursorCol: Int = 0
    var attrs: CellAttrs = .default

    var scrollTop: Int = 0
    var scrollBottom: Int

    var maxScrollback: Int = 10_000
    var pendingWrap: Bool = false
    var autoWrap: Bool = true
    var cursorVisible: Bool = true

    private var savedCursorRow: Int = 0
    private var savedCursorCol: Int = 0
    private var savedAttrs: CellAttrs = .default

    private var inAlternate: Bool = false
    private var savedMainLines: [[Cell]]?
    private var savedMainCursor: (Int, Int) = (0, 0)
    private var savedMainAttrs: CellAttrs = .default

    private(set) var dirtyAll: Bool = true
    private(set) var dirtyScreenRows: Set<Int> = []
    private(set) var generation: UInt64 = 0
    private(set) var lastScrollbackTrim: Int = 0

    var isInAlternateScreen: Bool { inAlternate }

    init(rows: Int, cols: Int) {
        let r = max(rows, 1)
        let c = max(cols, 1)
        self.rows = r
        self.cols = c
        self.scrollBottom = r - 1
        self.lines = Array(repeating: Self.blankLine(c), count: r)
    }

    private static func blankLine(_ cols: Int) -> [Cell] {
        Array(repeating: .blank, count: cols)
    }

    private func bumpGeneration() {
        generation &+= 1
    }

    func markFullRedraw() {
        dirtyAll = true
        dirtyScreenRows.removeAll(keepingCapacity: true)
        bumpGeneration()
    }

    func markDirty(_ row: Int) {
        if !dirtyAll {
            dirtyScreenRows.insert(row)
        }
        bumpGeneration()
    }

    func clearDirty() {
        dirtyAll = false
        dirtyScreenRows.removeAll(keepingCapacity: true)
        lastScrollbackTrim = 0
    }

    // MARK: - Resize

    func resize(rows newRows: Int, cols newCols: Int) {
        let r = max(newRows, 1)
        let c = max(newCols, 1)
        guard r != rows || c != cols else { return }

        for i in 0..<lines.count {
            adjust(line: &lines[i], to: c)
        }
        for i in 0..<scrollback.count {
            adjust(line: &scrollback[i], to: c)
        }

        if r > lines.count {
            let need = r - lines.count
            lines.append(contentsOf: Array(repeating: Self.blankLine(c), count: need))
        } else if r < lines.count {
            let trim = lines.count - r
            // When we drop rows from the top of the screen, shove them into scrollback
            // so users can still see history.
            if !inAlternate {
                let prefix = Array(lines.prefix(trim))
                scrollback.append(contentsOf: prefix)
                lastScrollbackTrim += 0 // append doesn't change indices
            }
            lines.removeFirst(trim)
            cursorRow = max(0, cursorRow - trim)
        }

        rows = r
        cols = c
        scrollTop = 0
        scrollBottom = r - 1
        cursorRow = min(cursorRow, r - 1)
        cursorCol = min(cursorCol, c - 1)
        pendingWrap = false
        trimScrollback()
        markFullRedraw()
    }

    private func adjust(line: inout [Cell], to width: Int) {
        if line.count < width {
            line.append(contentsOf: Array(repeating: .blank, count: width - line.count))
        } else if line.count > width {
            line = Array(line.prefix(width))
        }
    }

    private func trimScrollback() {
        if scrollback.count > maxScrollback {
            let drop = scrollback.count - maxScrollback
            scrollback.removeFirst(drop)
            lastScrollbackTrim += drop
        }
    }

    // MARK: - Writing

    func write(character ch: Character) {
        if pendingWrap && autoWrap {
            cursorCol = 0
            cursorDown(1, scroll: true)
            pendingWrap = false
        }
        if cursorCol >= cols { cursorCol = cols - 1 }
        if cursorRow >= rows { cursorRow = rows - 1 }
        let cell = Cell(character: ch, attrs: attrs)
        if lines[cursorRow][cursorCol] != cell {
            lines[cursorRow][cursorCol] = cell
            markDirty(cursorRow)
        }
        if cursorCol + 1 >= cols {
            pendingWrap = true
        } else {
            cursorCol += 1
        }
    }

    func newline() {
        pendingWrap = false
        cursorDown(1, scroll: true)
    }

    func carriageReturn() {
        pendingWrap = false
        cursorCol = 0
        markDirty(cursorRow)
    }

    func backspace() {
        pendingWrap = false
        if cursorCol > 0 { cursorCol -= 1 }
        markDirty(cursorRow)
    }

    func tab() {
        pendingWrap = false
        let next = ((cursorCol / 8) + 1) * 8
        cursorCol = min(next, cols - 1)
        markDirty(cursorRow)
    }

    // MARK: - Cursor motion

    func cursorUp(_ n: Int) {
        pendingWrap = false
        let target = cursorRow - max(n, 1)
        cursorRow = max(scrollTop, target)
        markDirty(cursorRow)
    }

    func cursorDown(_ n: Int, scroll: Bool = false) {
        pendingWrap = false
        let target = cursorRow + max(n, 1)
        if scroll && target > scrollBottom {
            let amount = target - scrollBottom
            scrollUp(amount)
            cursorRow = scrollBottom
        } else {
            cursorRow = min(target, rows - 1)
        }
        markDirty(cursorRow)
    }

    func cursorForward(_ n: Int) {
        pendingWrap = false
        cursorCol = min(cols - 1, cursorCol + max(n, 1))
        markDirty(cursorRow)
    }

    func cursorBack(_ n: Int) {
        pendingWrap = false
        cursorCol = max(0, cursorCol - max(n, 1))
        markDirty(cursorRow)
    }

    func moveTo(row: Int, col: Int) {
        pendingWrap = false
        cursorRow = max(0, min(row, rows - 1))
        cursorCol = max(0, min(col, cols - 1))
        markDirty(cursorRow)
    }

    func saveCursor() {
        savedCursorRow = cursorRow
        savedCursorCol = cursorCol
        savedAttrs = attrs
    }

    func restoreCursor() {
        cursorRow = min(savedCursorRow, rows - 1)
        cursorCol = min(savedCursorCol, cols - 1)
        attrs = savedAttrs
        pendingWrap = false
        markDirty(cursorRow)
    }

    // MARK: - Scrolling

    func scrollUp(_ n: Int) {
        let count = max(n, 1)
        for _ in 0..<count {
            if scrollTop == 0 && scrollBottom == rows - 1 && !inAlternate {
                scrollback.append(lines[0])
            }
            lines.remove(at: scrollTop)
            lines.insert(Self.blankLine(cols), at: scrollBottom)
        }
        trimScrollback()
        markFullRedraw()
    }

    func scrollDown(_ n: Int) {
        let count = max(n, 1)
        for _ in 0..<count {
            lines.remove(at: scrollBottom)
            lines.insert(Self.blankLine(cols), at: scrollTop)
        }
        markFullRedraw()
    }

    // MARK: - Erasing

    func eraseInDisplay(_ mode: Int) {
        let blank = Cell(character: " ", attrs: attrs)
        switch mode {
        case 0:
            for c in cursorCol..<cols { lines[cursorRow][c] = blank }
            for r in (cursorRow + 1)..<rows {
                lines[r] = Array(repeating: blank, count: cols)
            }
        case 1:
            for r in 0..<cursorRow {
                lines[r] = Array(repeating: blank, count: cols)
            }
            for c in 0...min(cursorCol, cols - 1) {
                lines[cursorRow][c] = blank
            }
        case 2:
            for r in 0..<rows {
                lines[r] = Array(repeating: blank, count: cols)
            }
        case 3:
            scrollback.removeAll()
            lastScrollbackTrim = Int.max
        default:
            break
        }
        markFullRedraw()
    }

    func eraseInLine(_ mode: Int) {
        let blank = Cell(character: " ", attrs: attrs)
        switch mode {
        case 0:
            for c in cursorCol..<cols { lines[cursorRow][c] = blank }
        case 1:
            for c in 0...min(cursorCol, cols - 1) { lines[cursorRow][c] = blank }
        case 2:
            lines[cursorRow] = Array(repeating: blank, count: cols)
        default:
            break
        }
        markDirty(cursorRow)
    }

    func eraseCharacters(_ n: Int) {
        let blank = Cell(character: " ", attrs: attrs)
        let count = max(n, 1)
        let end = min(cursorCol + count, cols)
        for c in cursorCol..<end { lines[cursorRow][c] = blank }
        markDirty(cursorRow)
    }

    func insertLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = max(n, 1)
        for _ in 0..<count {
            lines.insert(Self.blankLine(cols), at: cursorRow)
            if scrollBottom + 1 < lines.count {
                lines.remove(at: scrollBottom + 1)
            }
        }
        markFullRedraw()
    }

    func deleteLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = max(n, 1)
        for _ in 0..<count {
            lines.remove(at: cursorRow)
            lines.insert(Self.blankLine(cols), at: scrollBottom)
        }
        markFullRedraw()
    }

    func insertChars(_ n: Int) {
        let count = max(n, 1)
        let blank = Cell(character: " ", attrs: attrs)
        for _ in 0..<count where cursorCol < cols {
            lines[cursorRow].insert(blank, at: cursorCol)
            if lines[cursorRow].count > cols { lines[cursorRow].removeLast() }
        }
        markDirty(cursorRow)
    }

    func deleteChars(_ n: Int) {
        let count = max(n, 1)
        let blank = Cell(character: " ", attrs: attrs)
        for _ in 0..<count where cursorCol < lines[cursorRow].count {
            lines[cursorRow].remove(at: cursorCol)
            lines[cursorRow].append(blank)
        }
        markDirty(cursorRow)
    }

    // MARK: - Scroll region

    func setScrollRegion(top: Int, bottom: Int) {
        let t = max(0, top)
        let b = min(rows - 1, bottom)
        if t < b {
            scrollTop = t
            scrollBottom = b
            cursorRow = scrollTop
            cursorCol = 0
            pendingWrap = false
            markFullRedraw()
        }
    }

    // MARK: - Alt screen

    func enterAltScreen() {
        if inAlternate { return }
        savedMainLines = lines
        savedMainCursor = (cursorRow, cursorCol)
        savedMainAttrs = attrs
        lines = Array(repeating: Self.blankLine(cols), count: rows)
        cursorRow = 0
        cursorCol = 0
        attrs = .default
        pendingWrap = false
        inAlternate = true
        markFullRedraw()
    }

    func exitAltScreen() {
        if !inAlternate { return }
        if let saved = savedMainLines {
            lines = saved
        } else {
            lines = Array(repeating: Self.blankLine(cols), count: rows)
        }
        cursorRow = min(savedMainCursor.0, rows - 1)
        cursorCol = min(savedMainCursor.1, cols - 1)
        attrs = savedMainAttrs
        savedMainLines = nil
        pendingWrap = false
        inAlternate = false
        markFullRedraw()
    }

    // MARK: - SGR

    func applySGR(_ params: [Int]) {
        if params.isEmpty {
            attrs = .default
            return
        }
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                attrs = .default
            case 1:
                attrs.bold = true
            case 2:
                attrs.faint = true
            case 3:
                attrs.italic = true
            case 4:
                attrs.underline = true
            case 7:
                attrs.inverse = true
            case 22:
                attrs.bold = false
                attrs.faint = false
            case 23:
                attrs.italic = false
            case 24:
                attrs.underline = false
            case 27:
                attrs.inverse = false
            case 30...37:
                attrs.fg = .palette(p - 30)
            case 38:
                if i + 1 < params.count {
                    if params[i + 1] == 5, i + 2 < params.count {
                        attrs.fg = .palette(max(0, min(params[i + 2], 255)))
                        i += 2
                    } else if params[i + 1] == 2, i + 4 < params.count {
                        let r = UInt8(clamping: params[i + 2])
                        let g = UInt8(clamping: params[i + 3])
                        let b = UInt8(clamping: params[i + 4])
                        attrs.fg = .rgb(r, g, b)
                        i += 4
                    }
                }
            case 39:
                attrs.fg = .default
            case 40...47:
                attrs.bg = .palette(p - 40)
            case 48:
                if i + 1 < params.count {
                    if params[i + 1] == 5, i + 2 < params.count {
                        attrs.bg = .palette(max(0, min(params[i + 2], 255)))
                        i += 2
                    } else if params[i + 1] == 2, i + 4 < params.count {
                        let r = UInt8(clamping: params[i + 2])
                        let g = UInt8(clamping: params[i + 3])
                        let b = UInt8(clamping: params[i + 4])
                        attrs.bg = .rgb(r, g, b)
                        i += 4
                    }
                }
            case 49:
                attrs.bg = .default
            case 90...97:
                attrs.fg = .palette(p - 90 + 8)
            case 100...107:
                attrs.bg = .palette(p - 100 + 8)
            default:
                break
            }
            i += 1
        }
    }

    // MARK: - Snapshot helpers

    var totalLineCount: Int { scrollback.count + rows }

    func line(at index: Int) -> [Cell] {
        if index < scrollback.count { return scrollback[index] }
        let r = index - scrollback.count
        if r >= 0 && r < lines.count { return lines[r] }
        return []
    }

    /// Resets the entire grid and scrollback to a clean state.
    func reset() {
        lines = Array(repeating: Self.blankLine(cols), count: rows)
        scrollback.removeAll(keepingCapacity: true)
        cursorRow = 0
        cursorCol = 0
        attrs = .default
        scrollTop = 0
        scrollBottom = rows - 1
        pendingWrap = false
        lastScrollbackTrim = Int.max
        markFullRedraw()
    }
}
