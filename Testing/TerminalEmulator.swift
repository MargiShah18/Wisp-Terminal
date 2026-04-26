import Foundation

@MainActor
final class TerminalEmulator: ANSIParserDelegate {
    let grid: TerminalGrid
    private let parser = ANSIParser()

    var onResponse: ((Data) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onPromptMark: (() -> Void)?
    var onCommandMark: (() -> Void)?
    var onCommandFinished: ((Int?) -> Void)?
    var onCwdChange: ((String) -> Void)?
    var onBell: (() -> Void)?

    init(grid: TerminalGrid) {
        self.grid = grid
        parser.delegate = self
    }

    func feed(_ data: Data) {
        parser.feed(data)
    }

    // MARK: - Delegate

    func parser(_ parser: ANSIParser, didReceiveText text: String) {
        for ch in text {
            grid.write(character: ch)
        }
    }

    func parser(_ parser: ANSIParser, didReceiveControl byte: UInt8) {
        switch byte {
        case 0x07:
            onBell?()
        case 0x08:
            grid.backspace()
        case 0x09:
            grid.tab()
        case 0x0A, 0x0B, 0x0C:
            grid.newline()
        case 0x0D:
            grid.carriageReturn()
        default:
            break
        }
    }

    func parser(_ parser: ANSIParser, didReceiveCSI params: [Int], intermediates: String, final: Character, isPrivate: Bool, privatePrefix: Character?) {
        let firstParam = params.first ?? 0

        switch final {
        case "@":
            grid.insertChars(firstParam == 0 ? 1 : firstParam)
        case "A":
            grid.cursorUp(firstParam == 0 ? 1 : firstParam)
        case "B", "e":
            grid.cursorDown(firstParam == 0 ? 1 : firstParam)
        case "C", "a":
            grid.cursorForward(firstParam == 0 ? 1 : firstParam)
        case "D":
            grid.cursorBack(firstParam == 0 ? 1 : firstParam)
        case "E":
            grid.cursorDown(firstParam == 0 ? 1 : firstParam)
            grid.cursorCol = 0
        case "F":
            grid.cursorUp(firstParam == 0 ? 1 : firstParam)
            grid.cursorCol = 0
        case "G", "`":
            let col = max(0, (firstParam == 0 ? 1 : firstParam) - 1)
            grid.cursorCol = min(col, grid.cols - 1)
            grid.markDirty(grid.cursorRow)
        case "H", "f":
            let r = (params.first ?? 1) - 1
            let c = (params.count > 1 ? params[1] : 1) - 1
            grid.moveTo(row: r, col: c)
        case "I":
            for _ in 0..<max(firstParam, 1) { grid.tab() }
        case "J":
            grid.eraseInDisplay(firstParam)
        case "K":
            grid.eraseInLine(firstParam)
        case "L":
            grid.insertLines(firstParam == 0 ? 1 : firstParam)
        case "M":
            grid.deleteLines(firstParam == 0 ? 1 : firstParam)
        case "P":
            grid.deleteChars(firstParam == 0 ? 1 : firstParam)
        case "S":
            grid.scrollUp(firstParam == 0 ? 1 : firstParam)
        case "T":
            grid.scrollDown(firstParam == 0 ? 1 : firstParam)
        case "X":
            grid.eraseCharacters(firstParam == 0 ? 1 : firstParam)
        case "d":
            let row = max(0, (firstParam == 0 ? 1 : firstParam) - 1)
            grid.cursorRow = min(row, grid.rows - 1)
            grid.markDirty(grid.cursorRow)
        case "h":
            handleSetMode(params, isPrivate: isPrivate, set: true)
        case "l":
            handleSetMode(params, isPrivate: isPrivate, set: false)
        case "m":
            grid.applySGR(params.isEmpty ? [0] : params)
        case "r":
            let top = (params.first ?? 1) - 1
            let bottom = (params.count > 1 ? params[1] : grid.rows) - 1
            grid.setScrollRegion(top: top, bottom: bottom)
        case "s":
            grid.saveCursor()
        case "u":
            grid.restoreCursor()
        case "n":
            if firstParam == 6 {
                let response = "\u{1B}[\(grid.cursorRow + 1);\(grid.cursorCol + 1)R"
                if let data = response.data(using: .ascii) {
                    onResponse?(data)
                }
            } else if firstParam == 5 {
                if let data = "\u{1B}[0n".data(using: .ascii) {
                    onResponse?(data)
                }
            }
        case "c":
            if let data = "\u{1B}[?62;1;6c".data(using: .ascii) {
                onResponse?(data)
            }
        case "t":
            // window manipulation - ignore but consume cleanly
            break
        default:
            break
        }
    }

    func parser(_ parser: ANSIParser, didReceiveOSC string: String) {
        guard let semi = string.firstIndex(of: ";") else { return }
        let codeStr = String(string[..<semi])
        let value = String(string[string.index(after: semi)...])

        switch codeStr {
        case "0", "1", "2":
            onTitleChange?(value)
        case "7":
            // file:// URL with cwd info
            if let url = URL(string: value), url.scheme == "file" {
                onCwdChange?(url.path)
            }
        case "133":
            // OSC 133 shell integration: A=prompt, B=command start, C=output, D=command finished
            let parts = value.split(separator: ";")
            guard let kind = parts.first else { return }
            switch kind {
            case "A":
                onPromptMark?()
            case "B", "C":
                onCommandMark?()
            case "D":
                let exit: Int?
                if parts.count > 1, let val = Int(parts[1]) {
                    exit = val
                } else {
                    exit = nil
                }
                onCommandFinished?(exit)
            default:
                break
            }
        default:
            break
        }
    }

    func parser(_ parser: ANSIParser, didReceiveESC final: Character, intermediates: String) {
        switch final {
        case "7":
            grid.saveCursor()
        case "8":
            grid.restoreCursor()
        case "M":
            if grid.cursorRow == grid.scrollTop {
                grid.scrollDown(1)
            } else {
                grid.cursorRow = max(0, grid.cursorRow - 1)
                grid.markDirty(grid.cursorRow)
            }
        case "D":
            grid.cursorDown(1, scroll: true)
        case "E":
            grid.newline()
            grid.cursorCol = 0
        case "c":
            grid.reset()
        default:
            break
        }
    }

    private func handleSetMode(_ params: [Int], isPrivate: Bool, set: Bool) {
        for p in params {
            if isPrivate {
                switch p {
                case 7:
                    grid.autoWrap = set
                case 25:
                    grid.cursorVisible = set
                case 47, 1047, 1049:
                    if set { grid.enterAltScreen() } else { grid.exitAltScreen() }
                case 1048:
                    if set { grid.saveCursor() } else { grid.restoreCursor() }
                case 2004:
                    // bracketed paste — accept silently
                    break
                default:
                    break
                }
            }
        }
    }
}
