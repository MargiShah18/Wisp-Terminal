import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        showWindow(forceCreate: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if window?.isVisible != true {
            showWindow(forceCreate: false)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow(forceCreate: false) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Window

    private func showWindow(forceCreate: Bool) {
        if window == nil || forceCreate {
            let restoredFrame = SessionRestore.loadWindowFrame()
            let frame = restoredFrame ?? NSRect(x: 0, y: 0, width: 1180, height: 760)
            let w = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "SwiftMiniTerm"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(srgbRed: 0.04, green: 0.05, blue: 0.07, alpha: 1.0)
            w.isReleasedWhenClosed = false
            // We handle window frame persistence manually via SessionRestore, so
            // opt out of AppKit's window restoration to silence the benign
            // "Unable to find className=(null)" log on launch.
            w.isRestorable = false
            if restoredFrame == nil { w.center() }
            w.contentViewController = WorkspaceViewController()
            w.delegate = self
            window = w
        }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        if let frame = window?.frame {
            SessionRestore.saveWindowFrame(frame)
        }
    }

    func windowDidMove(_ notification: Notification) {
        if let frame = window?.frame {
            SessionRestore.saveWindowFrame(frame)
        }
    }

    // MARK: - Main menu

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About SwiftMiniTerm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide SwiftMiniTerm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Tab", action: #selector(WorkspaceViewController.newTab(_:)), keyEquivalent: "t"))
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(WorkspaceViewController.closeTab(_:)), keyEquivalent: "w")
        fileMenu.addItem(closeTabItem)
        let closePaneItem = NSMenuItem(title: "Close Pane", action: #selector(WorkspaceViewController.closePane(_:)), keyEquivalent: "w")
        closePaneItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closePaneItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Find", action: #selector(WorkspaceViewController.performFindAction(_:)), keyEquivalent: "f"))
        editMenu.addItem(NSMenuItem(title: "Find Next", action: #selector(WorkspaceViewController.performFindNext(_:)), keyEquivalent: "g"))
        let findPrev = NSMenuItem(title: "Find Previous", action: #selector(WorkspaceViewController.performFindPrevious(_:)), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(findPrev)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Split Right", action: #selector(WorkspaceViewController.splitRight(_:)), keyEquivalent: "d"))
        let splitDown = NSMenuItem(title: "Split Down", action: #selector(WorkspaceViewController.splitDown(_:)), keyEquivalent: "d")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(splitDown)
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Zoom In", action: #selector(WorkspaceViewController.zoomIn(_:)), keyEquivalent: "+"))
        viewMenu.addItem(NSMenuItem(title: "Zoom Out", action: #selector(WorkspaceViewController.zoomOut(_:)), keyEquivalent: "-"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Clear Buffer", action: #selector(WorkspaceViewController.clearScreen(_:)), keyEquivalent: "k"))
        let interrupt = NSMenuItem(title: "Send Interrupt", action: #selector(WorkspaceViewController.interrupt(_:)), keyEquivalent: ".")
        interrupt.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(interrupt)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Next Tab", action: #selector(WorkspaceViewController.nextTab(_:)), keyEquivalent: "]"))
        windowMenu.addItem(NSMenuItem(title: "Previous Tab", action: #selector(WorkspaceViewController.previousTab(_:)), keyEquivalent: "["))
        windowMenu.addItem(.separator())
        for i in 1...9 {
            let item = NSMenuItem(title: "Tab \(i)", action: tabSelector(for: i), keyEquivalent: "\(i)")
            windowMenu.addItem(item)
        }
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func tabSelector(for index: Int) -> Selector {
        switch index {
        case 1: return #selector(WorkspaceViewController.selectTab1(_:))
        case 2: return #selector(WorkspaceViewController.selectTab2(_:))
        case 3: return #selector(WorkspaceViewController.selectTab3(_:))
        case 4: return #selector(WorkspaceViewController.selectTab4(_:))
        case 5: return #selector(WorkspaceViewController.selectTab5(_:))
        case 6: return #selector(WorkspaceViewController.selectTab6(_:))
        case 7: return #selector(WorkspaceViewController.selectTab7(_:))
        case 8: return #selector(WorkspaceViewController.selectTab8(_:))
        case 9: return #selector(WorkspaceViewController.selectTab9(_:))
        default: return #selector(WorkspaceViewController.selectTab1(_:))
        }
    }
}
