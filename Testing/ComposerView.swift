import AppKit

@MainActor
final class ComposerView: NSView {
    weak var controller: PaneController?

    private let inputField = ComposerTextField()
    private let ghostField = NSTextField(labelWithString: "")
    private let promptLabel = NSTextField(labelWithString: "❯")
    private let cwdLabel = NSTextField(labelWithString: "")
    private let rawModeBadge = NSTextField(labelWithString: "RAW")
    private var rawModeActive: Bool = false

    /// The un-typed suffix currently being offered as ghost autocomplete, or ""
    /// when there is no suggestion.
    private(set) var currentGhostSuffix: String = ""
    /// The match the ghost is currently representing (slash command, history
    /// entry, or filesystem path). Used to decide post-accept behaviour.
    private(set) var currentMatch: AutocompleteMatch?

    init(controller: PaneController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 44)
    }

    private func setup() {
        layer?.backgroundColor = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 1.0).cgColor

        let topLine = NSView()
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.15, blue: 0.20, alpha: 1.0).cgColor
        topLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topLine)

        cwdLabel.translatesAutoresizingMaskIntoConstraints = false
        cwdLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        cwdLabel.textColor = NSColor(srgbRed: 0.55, green: 0.62, blue: 0.74, alpha: 1.0)
        cwdLabel.lineBreakMode = .byTruncatingMiddle
        cwdLabel.maximumNumberOfLines = 1
        // Hug tightly for normal content, but compress (truncate) before the
        // input field does so we never push the composer off-screen.
        cwdLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        cwdLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(cwdLabel)

        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
        promptLabel.textColor = NSColor(srgbRed: 0.36, green: 0.85, blue: 0.66, alpha: 1.0)
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(promptLabel)

        rawModeBadge.translatesAutoresizingMaskIntoConstraints = false
        rawModeBadge.font = .systemFont(ofSize: 9, weight: .heavy)
        rawModeBadge.textColor = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
        rawModeBadge.wantsLayer = true
        rawModeBadge.layer?.cornerRadius = 4
        rawModeBadge.layer?.backgroundColor = NSColor(srgbRed: 0.96, green: 0.78, blue: 0.30, alpha: 1.0).cgColor
        rawModeBadge.alignment = .center
        rawModeBadge.isHidden = true
        rawModeBadge.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(rawModeBadge)

        // Ghost field sits BEHIND the input field and shows the full suggested
        // command with the user's typed prefix drawn invisible (alpha 0) so the
        // remaining characters appear to float right after the caret.
        ghostField.translatesAutoresizingMaskIntoConstraints = false
        ghostField.isSelectable = false
        ghostField.isEditable = false
        ghostField.isBezeled = false
        ghostField.isBordered = false
        ghostField.drawsBackground = false
        ghostField.focusRingType = .none
        ghostField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        ghostField.textColor = .clear
        ghostField.lineBreakMode = .byClipping
        ghostField.maximumNumberOfLines = 1
        ghostField.alphaValue = 1
        addSubview(ghostField)

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.isBordered = false
        inputField.isBezeled = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        inputField.textColor = NSColor(srgbRed: 0.93, green: 0.96, blue: 0.99, alpha: 1.0)
        inputField.placeholderString = "Type a command and press ⏎ (start with / for commands)"
        inputField.composer = self
        inputField.delegate = self
        addSubview(inputField)

        NSLayoutConstraint.activate([
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),

            cwdLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            cwdLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            cwdLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),

            promptLabel.leadingAnchor.constraint(equalTo: cwdLabel.trailingAnchor, constant: 8),
            promptLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            inputField.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: 8),
            inputField.trailingAnchor.constraint(equalTo: rawModeBadge.leadingAnchor, constant: -10),
            inputField.centerYAnchor.constraint(equalTo: centerYAnchor),
            inputField.heightAnchor.constraint(equalToConstant: 24),

            ghostField.leadingAnchor.constraint(equalTo: inputField.leadingAnchor),
            ghostField.trailingAnchor.constraint(equalTo: inputField.trailingAnchor),
            ghostField.centerYAnchor.constraint(equalTo: inputField.centerYAnchor),
            ghostField.heightAnchor.constraint(equalTo: inputField.heightAnchor),

            rawModeBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            rawModeBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            rawModeBadge.widthAnchor.constraint(equalToConstant: 38),
            rawModeBadge.heightAnchor.constraint(equalToConstant: 16)
        ])

        applyFontSize()
        updateGhostSuggestion()
    }

    func applyFontSize() {
        let f = controller?.fontSize ?? 13
        let size = max(13, f + 1)
        inputField.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        ghostField.font = .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(inputField)
        return false
    }

    func setIsActive(_ active: Bool) {
        promptLabel.textColor = active
            ? NSColor(srgbRed: 0.36, green: 0.85, blue: 0.66, alpha: 1.0)
            : NSColor(srgbRed: 0.32, green: 0.42, blue: 0.55, alpha: 1.0)
    }

    func setCwd(_ cwd: String) {
        // Show the full abbreviated path. The label truncates middle if it
        // grows past its width cap, so e.g. a deeply-nested repo shows as
        // `~/Work/.../feature-branch` with the full path on hover.
        let display = (cwd as NSString).abbreviatingWithTildeInPath
        cwdLabel.stringValue = display.isEmpty ? "/" : display
        cwdLabel.toolTip = cwd
        // Re-evaluate the ghost suggestion: the cwd might have changed
        // mid-editing (e.g. `cd /tmp` just finished while the user was typing
        // the next command), which shifts what paths are valid completions.
        updateGhostSuggestion()
    }

    func setRawMode(_ active: Bool) {
        if rawModeActive == active { return }
        rawModeActive = active
        rawModeBadge.isHidden = !active
        promptLabel.stringValue = active ? "▷" : "❯"
        inputField.placeholderString = active
            ? "(Raw mode — keystrokes go to PTY, ⌘. to interrupt)"
            : "Type a command and press ⏎ (start with / for commands)"
        if active {
            clearGhost()
        } else {
            updateGhostSuggestion()
        }
    }

    var isRawMode: Bool { rawModeActive }

    var input: String {
        get { inputField.stringValue }
        set {
            inputField.stringValue = newValue
            inputField.currentEditor()?.selectedRange = NSRange(location: newValue.count, length: 0)
            updateGhostSuggestion()
        }
    }

    func submit() {
        let value = inputField.stringValue
        guard !value.isEmpty || rawModeActive else {
            controller?.submit(command: value) // passes through to shell (just "\r")
            return
        }

        // Slash commands are dispatched locally and never sent to the shell.
        if !rawModeActive, let (cmd, args) = SlashCommandRegistry.match(value),
           let controller, let workspace = controller.workspace {
            let ctx = SlashContext(workspace: workspace, pane: controller)
            if let toast = cmd.run(args, ctx), !toast.isEmpty {
                controller.showToast(toast)
            }
            controller.recordSlashCommandInHistory(value)
            inputField.stringValue = ""
            clearGhost()
            return
        }

        controller?.submit(command: value)
        inputField.stringValue = ""
        clearGhost()
    }

    func handleHistoryUp() {
        guard let controller else { return }
        if let prev = controller.historyPrevious(currentInput: input) {
            input = prev
        }
    }

    func handleHistoryDown() {
        guard let controller else { return }
        if let next = controller.historyNext() {
            input = next
        }
    }

    // MARK: - Ghost autocomplete
    //
    // Inline "ghost" autocomplete: we layer a secondary text field behind the
    // live one, render the user's already-typed prefix invisible (alpha 0),
    // and paint the remaining characters dim. Pressing Tab extends the input
    // by that remaining portion — same idea fish/zsh have popularized.

    /// Recompute the ghost suggestion for the current input + cwd + history.
    func updateGhostSuggestion() {
        guard !rawModeActive else {
            clearGhost()
            return
        }

        let text = inputField.stringValue
        let history = controller?.commandHistory ?? []
        guard let match = AutocompleteEngine.bestCompletion(
            for: text,
            cwd: controller?.cwd,
            history: history
        ) else {
            clearGhost()
            return
        }

        currentGhostSuffix = match.ghostSuffix
        currentMatch = match

        let attr = NSMutableAttributedString()
        let mainFont = inputField.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let suffixColor = NSColor(srgbRed: 0.55, green: 0.62, blue: 0.74, alpha: 0.48)
        let hintFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let hintColor = NSColor(srgbRed: 0.45, green: 0.50, blue: 0.60, alpha: 0.55)

        if !text.isEmpty {
            attr.append(NSAttributedString(
                string: text,
                attributes: [.font: mainFont, .foregroundColor: NSColor.clear]
            ))
        }
        attr.append(NSAttributedString(
            string: match.ghostSuffix,
            attributes: [.font: mainFont, .foregroundColor: suffixColor]
        ))
        if let hint = match.hint {
            attr.append(NSAttributedString(
                string: hint,
                attributes: [.font: hintFont, .foregroundColor: hintColor]
            ))
        }
        ghostField.attributedStringValue = attr
        ghostField.isHidden = false
    }

    /// Accept the current ghost suggestion: extend the input text with the ghost
    /// suffix. Returns true if a suggestion was accepted.
    @discardableResult
    func acceptGhostSuggestion() -> Bool {
        guard !currentGhostSuffix.isEmpty, let match = currentMatch else { return false }
        var completed = inputField.stringValue + currentGhostSuffix

        // For slash commands that take arguments, drop a trailing space after
        // accept so the user can immediately start typing the argument.
        if case .slash(let cmd) = match.kind,
           cmd.usage != cmd.name, (cmd.usage?.contains("<") ?? false) {
            completed += " "
        }

        inputField.stringValue = completed
        inputField.currentEditor()?.selectedRange = NSRange(location: completed.count, length: 0)

        // After accepting a directory completion (ends with "/") we want the
        // ghost to immediately re-arm against the new trailing token so the
        // user can just keep typing child names. Slash-command and file
        // acceptances reset to "no suggestion".
        switch match.kind {
        case .path(let isDirectory, _) where isDirectory:
            updateGhostSuggestion()
        default:
            clearGhost()
        }
        return true
    }

    private func clearGhost() {
        currentGhostSuffix = ""
        currentMatch = nil
        ghostField.attributedStringValue = NSAttributedString(string: "")
        ghostField.isHidden = true
    }

    func handleRawKey(_ event: NSEvent) -> Bool {
        guard rawModeActive, let controller else { return false }

        if event.modifierFlags.contains(.command) { return false }

        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            let key = chars.unicodeScalars.first!.value
            switch Int(key) {
            case NSUpArrowFunctionKey:    controller.sendRawString("\u{1B}[A"); return true
            case NSDownArrowFunctionKey:  controller.sendRawString("\u{1B}[B"); return true
            case NSRightArrowFunctionKey: controller.sendRawString("\u{1B}[C"); return true
            case NSLeftArrowFunctionKey:  controller.sendRawString("\u{1B}[D"); return true
            case NSF1FunctionKey:         controller.sendRawString("\u{1B}OP"); return true
            case NSF2FunctionKey:         controller.sendRawString("\u{1B}OQ"); return true
            case NSF3FunctionKey:         controller.sendRawString("\u{1B}OR"); return true
            case NSF4FunctionKey:         controller.sendRawString("\u{1B}OS"); return true
            case 0x7F:                    controller.sendRawData(Data([0x7F])); return true
            case 0x0D, 0x03:              controller.sendRawData(Data([UInt8(key)])); return true
            default: break
            }
        }
        if let chars = event.characters, !chars.isEmpty {
            controller.sendRawString(chars)
            return true
        }
        return false
    }
}

// MARK: - Text field delegate (wires controlTextDidChange to ghost updates)

extension ComposerView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateGhostSuggestion()
    }

    /// While a field is being edited, AppKit routes special keys to the field
    /// editor which asks the delegate via `doCommandBy:`. Returning `true` here
    /// tells the field editor "I handled it, don't do the default thing".
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Tab → accept the ghost autocomplete if present.
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            if !currentGhostSuffix.isEmpty {
                acceptGhostSuggestion()
                return true
            }
            return false // let AppKit do its normal tab-to-next-view behaviour
        }

        // Enter/Return → submit. Using the delegate path avoids races with
        // textDidEndEditing and keeps focus inside the field afterward.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit()
            return true
        }

        // Up/Down arrow → walk command history.
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            handleHistoryUp()
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            handleHistoryDown()
            return true
        }

        // Escape → clear the ghost hint (but not the user's text).
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !currentGhostSuffix.isEmpty {
                clearGhost()
                return true
            }
        }

        return false
    }
}

// Internal text field that knows how to pass keys to the composer
@MainActor
final class ComposerTextField: NSTextField {
    weak var composer: ComposerView?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            currentEditor()?.selectedRange = NSRange(location: stringValue.count, length: 0)
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if let composer, composer.isRawMode {
            if composer.handleRawKey(event) { return }
        }

        // Tab accepts the current ghost autocomplete suggestion (if any).
        if event.keyCode == 48, let composer, !composer.currentGhostSuffix.isEmpty {
            composer.acceptGhostSuggestion()
            return
        }

        // Escape clears any ghost hint but leaves the input alone.
        if event.keyCode == 53, let composer, !composer.currentGhostSuffix.isEmpty {
            composer.updateGhostSuggestion() // redundant safety; just refresh state
            return
        }

        if event.keyCode == 126 { // Up arrow
            composer?.handleHistoryUp()
            return
        }
        if event.keyCode == 125 { // Down arrow
            composer?.handleHistoryDown()
            return
        }

        super.keyDown(with: event)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)

        let movement = notification.userInfo?["NSTextMovement"] as? Int ?? 0
        if movement == NSReturnTextMovement {
            composer?.submit()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }
}
