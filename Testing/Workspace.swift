import AppKit

// MARK: - Tab model

@MainActor
final class WorkspaceTab {
    let id = UUID()
    var title: String
    /// Root view containing either a single pane or a split tree.
    fileprivate(set) var rootView: NSView
    fileprivate(set) var activePane: PaneController

    init(title: String, rootView: NSView, activePane: PaneController) {
        self.title = title
        self.rootView = rootView
        self.activePane = activePane
    }
}

// MARK: - Workspace controller

@MainActor
final class WorkspaceViewController: NSViewController {
    private let tabBar = TabBarView()
    private let contentContainer = NSView()
    private(set) var tabs: [WorkspaceTab] = []
    private(set) var activeTabIndex: Int = -1

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 760))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(srgbRed: 0.04, green: 0.05, blue: 0.07, alpha: 1.0).cgColor
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        view.addSubview(tabBar)
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 40),

            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onAdd = { [weak self] in self?.newTab(nil) }

        newTab(nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let pane = activePane {
            view.window?.makeFirstResponder(pane.paneView.composer)
        }
    }

    // MARK: - Tab management

    @IBAction func newTab(_ sender: Any?) {
        let pane = PaneController(workspace: self)
        let tab = WorkspaceTab(title: defaultTabTitle(), rootView: pane.paneView, activePane: pane)
        tabs.append(tab)
        rebuildTabBar()
        selectTab(at: tabs.count - 1)
        pane.start()
    }

    @IBAction func closeTab(_ sender: Any?) {
        closeTab(at: activeTabIndex)
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        forEachPane(under: tab.rootView) { $0.close() }
        tabs.remove(at: index)
        rebuildTabBar()

        if tabs.isEmpty {
            view.window?.close()
            return
        }
        let newIndex = min(index, tabs.count - 1)
        selectTab(at: newIndex)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let tab = tabs[index]
        tab.rootView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(tab.rootView)
        NSLayoutConstraint.activate([
            tab.rootView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            tab.rootView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            tab.rootView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            tab.rootView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        activeTabIndex = index
        tabBar.activeIndex = index
        view.window?.title = "\(tab.title) — SwiftMiniTerm"
        view.window?.makeFirstResponder(tab.activePane.paneView.composer)
    }

    @IBAction func nextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let next = (activeTabIndex + 1) % tabs.count
        selectTab(at: next)
    }

    @IBAction func previousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let prev = (activeTabIndex - 1 + tabs.count) % tabs.count
        selectTab(at: prev)
    }

    @IBAction func selectTab1(_ sender: Any?) { selectTab(at: 0) }
    @IBAction func selectTab2(_ sender: Any?) { selectTab(at: 1) }
    @IBAction func selectTab3(_ sender: Any?) { selectTab(at: 2) }
    @IBAction func selectTab4(_ sender: Any?) { selectTab(at: 3) }
    @IBAction func selectTab5(_ sender: Any?) { selectTab(at: 4) }
    @IBAction func selectTab6(_ sender: Any?) { selectTab(at: 5) }
    @IBAction func selectTab7(_ sender: Any?) { selectTab(at: 6) }
    @IBAction func selectTab8(_ sender: Any?) { selectTab(at: 7) }
    @IBAction func selectTab9(_ sender: Any?) { selectTab(at: 8) }

    func updateTitle(for tab: WorkspaceTab, _ title: String) {
        tab.title = title
        rebuildTabBar()
        if let active = activeTab, active === tab {
            view.window?.title = "\(title) — SwiftMiniTerm"
        }
    }

    /// Rename the currently active tab (used by the `/rename-tab` slash command).
    func renameActiveTab(to title: String) {
        guard let tab = activeTab else { return }
        updateTitle(for: tab, title)
    }

    private func defaultTabTitle() -> String {
        let n = tabs.count + 1
        return n == 1 ? "shell" : "shell \(n)"
    }

    private func rebuildTabBar() {
        tabBar.tabs = tabs.map { $0.title }
        tabBar.activeIndex = activeTabIndex
    }

    var activeTab: WorkspaceTab? {
        tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
    }

    var activePane: PaneController? { activeTab?.activePane }

    func setActivePane(_ pane: PaneController) {
        guard let tab = activeTab else { return }
        tab.activePane = pane
        forEachPane(under: tab.rootView) { p in
            p.paneView.setIsActive(p === pane)
        }
        view.window?.makeFirstResponder(pane.paneView.composer)
    }

    // MARK: - Splits

    @IBAction func splitRight(_ sender: Any?) {
        splitActive(orientation: .vertical)   // vertical divider, side-by-side
    }

    @IBAction func splitDown(_ sender: Any?) {
        splitActive(orientation: .horizontal) // horizontal divider, stacked
    }

    private func splitActive(orientation: NSUserInterfaceLayoutOrientation) {
        guard let tab = activeTab else { return }
        let oldPane = tab.activePane
        let newPane = PaneController(workspace: self)

        let oldView = oldPane.paneView
        let parent = oldView.superview

        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = (orientation == .vertical)
        split.dividerStyle = .thin
        split.setValue(NSColor(srgbRed: 0.07, green: 0.09, blue: 0.12, alpha: 1.0), forKey: "dividerColor")

        // Snapshot constraints to recreate after replacement
        if parent === contentContainer {
            // Remove from container, install split, then put both panes inside split.
            oldView.removeFromSuperview()
            tab.rootView = split
            contentContainer.addSubview(split)
            NSLayoutConstraint.activate([
                split.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                split.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                split.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
        } else if let oldSplit = parent as? NSSplitView {
            let position = oldSplit.arrangedSubviews.firstIndex(of: oldView) ?? 0
            oldSplit.removeArrangedSubview(oldView)
            oldView.removeFromSuperview()
            oldSplit.insertArrangedSubview(split, at: position)
        } else {
            return
        }

        oldView.translatesAutoresizingMaskIntoConstraints = false
        newPane.paneView.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(oldView)
        split.addArrangedSubview(newPane.paneView)

        DispatchQueue.main.async {
            // Center the divider
            let dim: CGFloat = split.isVertical ? split.bounds.width : split.bounds.height
            split.setPosition(dim / 2, ofDividerAt: 0)
        }

        newPane.start()
        setActivePane(newPane)
    }

    @IBAction func closePane(_ sender: Any?) {
        guard let tab = activeTab else { return }
        let pane = tab.activePane
        let view = pane.paneView
        let parent = view.superview

        if parent === contentContainer {
            // Last pane in tab — close the tab itself
            closeTab(at: activeTabIndex)
            return
        }

        guard let split = parent as? NSSplitView else { return }
        let siblings = split.arrangedSubviews
        guard let idx = siblings.firstIndex(of: view), siblings.count >= 2 else { return }
        let otherIdx = idx == 0 ? 1 : 0
        let otherView = siblings[otherIdx]

        pane.close()
        split.removeArrangedSubview(view)
        view.removeFromSuperview()

        // Promote the surviving sibling up the tree.
        let splitParent = split.superview
        split.removeArrangedSubview(otherView)
        otherView.removeFromSuperview()

        if splitParent === contentContainer {
            split.removeFromSuperview()
            tab.rootView = otherView
            otherView.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(otherView)
            NSLayoutConstraint.activate([
                otherView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                otherView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                otherView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                otherView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
        } else if let outerSplit = splitParent as? NSSplitView {
            let pos = outerSplit.arrangedSubviews.firstIndex(of: split) ?? 0
            outerSplit.removeArrangedSubview(split)
            split.removeFromSuperview()
            otherView.translatesAutoresizingMaskIntoConstraints = false
            outerSplit.insertArrangedSubview(otherView, at: pos)
        }

        // Pick a new active pane
        if let firstPane = firstPane(under: tab.rootView) {
            setActivePane(firstPane)
        }
    }

    // MARK: - Search & menu forwarding

    @IBAction func performFindAction(_ sender: Any?) {
        activePane?.paneView.openSearch()
    }

    @IBAction func performFindNext(_ sender: Any?) {
        activePane?.paneView.searchNext(direction: .forward)
    }

    @IBAction func performFindPrevious(_ sender: Any?) {
        activePane?.paneView.searchNext(direction: .backward)
    }

    @IBAction func interrupt(_ sender: Any?) {
        activePane?.sendInterrupt()
    }

    @IBAction func clearScreen(_ sender: Any?) {
        activePane?.clear()
    }

    @IBAction func zoomIn(_ sender: Any?) {
        activePane?.adjustFontSize(by: 1)
    }

    @IBAction func zoomOut(_ sender: Any?) {
        activePane?.adjustFontSize(by: -1)
    }

    // MARK: - Helpers

    func forEachPane(under view: NSView, _ body: (PaneController) -> Void) {
        if let host = view as? PaneView {
            host.controller.map(body)
            return
        }
        for sub in view.subviews {
            forEachPane(under: sub, body)
        }
    }

    private func firstPane(under view: NSView) -> PaneController? {
        if let host = view as? PaneView { return host.controller }
        for sub in view.subviews {
            if let p = firstPane(under: sub) { return p }
        }
        return nil
    }
}

// MARK: - Tab bar

@MainActor
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    var tabs: [String] = [] { didSet { rebuild() } }
    var activeIndex: Int = -1 { didSet { rebuild() } }

    private let stack = NSStackView()
    private let addButton = NSButton(title: "+", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1.0).cgColor

        let bottomLine = NSView()
        bottomLine.wantsLayer = true
        bottomLine.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1.0).cgColor
        bottomLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomLine)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        // Reserve room on the left for the macOS window traffic lights so titles
        // don't get clipped underneath them.
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 84, bottom: 4, right: 8)
        addSubview(stack)

        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 16, weight: .light)
        addButton.contentTintColor = NSColor(srgbRed: 0.55, green: 0.66, blue: 0.80, alpha: 1.0)
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        NSLayoutConstraint.activate([
            bottomLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: 1),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -8),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 26),
            addButton.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    @objc private func addClicked() { onAdd?() }

    private func rebuild() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (i, title) in tabs.enumerated() {
            let chip = TabChipView()
            chip.title = title
            chip.isActive = (i == activeIndex)
            chip.index = i
            chip.onSelect = { [weak self] idx in self?.onSelect?(idx) }
            chip.onClose = { [weak self] idx in self?.onClose?(idx) }
            stack.addArrangedSubview(chip)
        }
    }
}

@MainActor
private final class TabChipView: NSView {
    var title: String = "" { didSet { titleLabel.stringValue = title } }
    var isActive: Bool = false { didSet { redraw() } }
    var index: Int = 0
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = NSColor(srgbRed: 0.78, green: 0.84, blue: 0.92, alpha: 1.0)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 14, weight: .medium)
        closeButton.contentTintColor = NSColor(srgbRed: 0.55, green: 0.62, blue: 0.74, alpha: 1.0)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(selectClicked))
        addGestureRecognizer(click)

        redraw()
    }

    private func redraw() {
        if isActive {
            layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.13, blue: 0.18, alpha: 1.0).cgColor
            titleLabel.textColor = NSColor(srgbRed: 0.95, green: 0.97, blue: 1.0, alpha: 1.0)
            layer?.borderColor = NSColor(srgbRed: 0.32, green: 0.66, blue: 0.92, alpha: 0.5).cgColor
            layer?.borderWidth = 1
        } else {
            layer?.backgroundColor = NSColor(srgbRed: 0.07, green: 0.09, blue: 0.12, alpha: 1.0).cgColor
            titleLabel.textColor = NSColor(srgbRed: 0.66, green: 0.72, blue: 0.82, alpha: 1.0)
            layer?.borderColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
        }
    }

    @objc private func closeClicked() { onClose?(index) }
    @objc private func selectClicked() { onSelect?(index) }
}
