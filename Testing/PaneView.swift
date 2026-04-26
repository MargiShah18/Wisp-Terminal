import AppKit

@MainActor
final class PaneView: NSView {
    weak var controller: PaneController?

    let scrollView = NSScrollView()
    let blockList: BlockListView
    let composer: ComposerView
    let searchOverlay: SearchOverlayView
    private let leftAccent = CALayer()

    private var pendingScrollToBottom: Bool = true

    init(controller: PaneController) {
        self.controller = controller
        self.blockList = BlockListView(controller: controller)
        self.composer = ComposerView(controller: controller)
        self.searchOverlay = SearchOverlayView(controller: controller)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        layer?.backgroundColor = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1.0).cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        // Track viewport size changes so we can stretch the documentView to fill
        // the full width of the pane (cards otherwise render at their initial 600pt).
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.documentView = blockList
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        composer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(composer)

        searchOverlay.translatesAutoresizingMaskIntoConstraints = false
        searchOverlay.isHidden = true
        addSubview(searchOverlay)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: composer.topAnchor),

            composer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor),

            searchOverlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            searchOverlay.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            searchOverlay.widthAnchor.constraint(equalToConstant: 380),
            searchOverlay.heightAnchor.constraint(equalToConstant: 46)
        ])

        leftAccent.backgroundColor = NSColor.clear.cgColor
        leftAccent.frame = NSRect(x: 0, y: 0, width: 2, height: 0)
        layer?.addSublayer(leftAccent)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        // Single-click anywhere in the pane (except composer/search) makes it active.
        let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handlePaneClick))
        clickRecognizer.delaysPrimaryMouseButtonEvents = false
        scrollView.addGestureRecognizer(clickRecognizer)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        leftAccent.frame = NSRect(x: 0, y: 0, width: 2, height: bounds.height)
        stretchDocumentToViewport()
        recomputeGridSize()
    }

    /// Match the BlockListView's width to the scroll view's visible width so the
    /// cards always span the entire pane (instead of staying at their initial
    /// 600pt frame).
    private func stretchDocumentToViewport() {
        let target = scrollView.contentView.bounds.width
        guard target > 1 else { return }
        if abs(blockList.frame.width - target) > 0.5 {
            blockList.frame.size.width = target
            blockList.recomputeLayout()
        }
    }

    @objc private func clipFrameDidChange(_ note: Notification) {
        stretchDocumentToViewport()
    }

    private func recomputeGridSize() {
        guard let controller else { return }
        let metrics = blockList.metrics
        let visibleWidth = max(scrollView.contentView.bounds.width - blockList.horizontalInsets, 100)
        let visibleHeight = max(bounds.height - composer.fittingSize.height - 24, 100)
        let cols = max(20, Int(visibleWidth / metrics.charWidth))
        let rows = max(8, Int(visibleHeight / metrics.lineHeight))
        controller.resize(cols: cols, rows: rows)
    }

    func setIsActive(_ active: Bool) {
        leftAccent.backgroundColor = active
            ? NSColor(srgbRed: 0.32, green: 0.78, blue: 0.96, alpha: 0.85).cgColor
            : NSColor.clear.cgColor
        composer.setIsActive(active)
    }

    func updateCwd(_ cwd: String) {
        composer.setCwd(cwd)
    }

    func fontDidChange() {
        blockList.recomputeMetricsAndLayout()
        composer.applyFontSize()
        recomputeGridSize()
    }

    func markGridChanged() {
        blockList.refreshContent()
        if pendingScrollToBottom {
            scrollToBottom(animated: false)
        }
        // Update raw-mode banner if alt-screen state changed
        composer.setRawMode(controller?.grid.isInAlternateScreen ?? false)
    }

    func invalidateLayout() {
        blockList.recomputeLayout()
        if pendingScrollToBottom {
            scrollToBottom(animated: false)
        }
    }

    /// Force the next refresh to land at the bottom even if the user has scrolled
    /// up. Used right after submitting a command so output is always visible.
    func requestScrollToBottom() {
        pendingScrollToBottom = true
    }

    func scrollToBottom(animated: Bool) {
        let docHeight = blockList.frame.height
        let visible = scrollView.contentView.bounds.height
        guard docHeight > visible else { return }
        let target = NSPoint(x: 0, y: docHeight - visible)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                scrollView.contentView.animator().setBoundsOrigin(target)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func boundsDidChange(_ note: Notification) {
        // Detect whether user has scrolled away from the bottom.
        let docHeight = blockList.frame.height
        let visible = scrollView.contentView.bounds
        let bottom = visible.origin.y + visible.height
        // Allow a 24px slack for "still at bottom"
        pendingScrollToBottom = (docHeight - bottom) < 24
    }

    @objc private func handlePaneClick() {
        guard let controller, let workspace = controller.workspace else { return }
        workspace.setActivePane(controller)
    }

    // MARK: - Search

    func openSearch() {
        searchOverlay.isHidden = false
        searchOverlay.becomeKey()
    }

    func closeSearch() {
        searchOverlay.isHidden = true
        blockList.setSearchQuery("")
        window?.makeFirstResponder(composer)
    }

    func setSearchQuery(_ q: String) {
        blockList.setSearchQuery(q)
    }

    func searchNext(direction: SearchDirection) {
        let target = blockList.advanceSearch(direction: direction)
        searchOverlay.updateMatchInfo(current: target.index, total: target.total)
        if let rect = target.rect {
            _ = blockList.scrollToVisible(rect)
        }
    }

    func scrollToBlock(id: Int) {
        if let rect = blockList.frameForBlock(id: id) {
            _ = blockList.scrollToVisible(rect.insetBy(dx: 0, dy: -40))
        }
    }
}

enum SearchDirection { case forward, backward }
