import AppKit

@MainActor
final class SearchOverlayView: NSView {
    weak var controller: PaneController?

    private let textField = SearchTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton(title: "‹", target: nil, action: nil)
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)

    init(controller: PaneController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.13, blue: 0.18, alpha: 0.96).cgColor
        layer?.borderColor = NSColor(srgbRed: 0.20, green: 0.26, blue: 0.34, alpha: 0.95).cgColor
        layer?.borderWidth = 1
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let icon = NSTextField(labelWithString: "🔍")
        icon.font = .systemFont(ofSize: 13)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textField.textColor = NSColor(srgbRed: 0.94, green: 0.96, blue: 0.99, alpha: 1.0)
        textField.placeholderString = "Find in scrollback…"
        textField.target = self
        textField.action = #selector(searchSubmitted)
        textField.delegate = self
        textField.overlay = self
        addSubview(textField)

        countLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor(srgbRed: 0.66, green: 0.72, blue: 0.82, alpha: 1.0)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .right
        addSubview(countLabel)

        styleArrow(prevButton, action: #selector(prevPressed))
        styleArrow(nextButton, action: #selector(nextPressed))
        styleArrow(closeButton, action: #selector(closePressed))

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            textField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -8),

            countLabel.trailingAnchor.constraint(equalTo: prevButton.leadingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),

            prevButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -2),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 26),
            prevButton.heightAnchor.constraint(equalToConstant: 26),

            nextButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 26),
            nextButton.heightAnchor.constraint(equalToConstant: 26),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 26),
            closeButton.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    private func styleArrow(_ button: NSButton, action: Selector) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 16, weight: .medium)
        button.contentTintColor = NSColor(srgbRed: 0.78, green: 0.85, blue: 0.95, alpha: 1.0)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
    }

    func becomeKey() {
        window?.makeFirstResponder(textField)
        textField.currentEditor()?.selectAll(nil)
    }

    func updateMatchInfo(current: Int, total: Int) {
        if total == 0 {
            countLabel.stringValue = "no matches"
        } else {
            countLabel.stringValue = "\(current)/\(total)"
        }
    }

    @objc private func searchSubmitted() {
        controller?.paneView.setSearchQuery(textField.stringValue)
        controller?.paneView.searchNext(direction: .forward)
    }

    @objc private func prevPressed() {
        controller?.paneView.setSearchQuery(textField.stringValue)
        controller?.paneView.searchNext(direction: .backward)
    }

    @objc private func nextPressed() {
        controller?.paneView.setSearchQuery(textField.stringValue)
        controller?.paneView.searchNext(direction: .forward)
    }

    @objc func closePressed() {
        controller?.paneView.closeSearch()
    }
}

extension SearchOverlayView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        controller?.paneView.setSearchQuery(textField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closePressed()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            searchSubmitted()
            return true
        }
        return false
    }
}

@MainActor
final class SearchTextField: NSTextField {
    weak var overlay: SearchOverlayView?

    override func keyDown(with event: NSEvent) {
        // Cmd+G next, Cmd+Shift+G prev
        if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "g" {
                if event.modifierFlags.contains(.shift) {
                    overlay?.controller?.paneView.searchNext(direction: .backward)
                } else {
                    overlay?.controller?.paneView.searchNext(direction: .forward)
                }
                return
            }
            if chars == "f" {
                // Already open — re-focus
                overlay?.becomeKey()
                return
            }
        }
        if event.keyCode == 53 { // Esc
            overlay?.closePressed()
            return
        }
        super.keyDown(with: event)
    }
}
