import AppKit
import SwiftUI

@MainActor
func makeStandardEditMenu() -> NSMenu {
    let menu = NSMenu(title: "编辑")
    menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = menu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(.separator())
    menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    menu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    menu.addItem(.separator())
    menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    return menu
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var mainWindow: NSWindow?
    private var state: AppState?
    private var shortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()
        let state = AppState(demo: CommandLine.arguments.contains("--demo"))
        NSApp.appearance = state.appearance.nsAppearance
        state.onAppearanceChanged = { NSApp.appearance = $0.nsAppearance }
        state.onActivationFailure = { message in
            let alert = NSAlert()
            alert.messageText = "切换未完成"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
        state.onRequestActivation = { [weak self] profile, reauthenticate in
            self?.requestSwitch(profile, reauthenticate: reauthenticate)
        }
        self.state = state
        let panel = StatusPanelView(state: state,
                                    close: { [weak self] in self?.statusPopover?.performClose(nil) },
                                    openMain: { [weak self] in self?.openPanel(nil) },
                                    openSettings: { [weak self] in self?.openSettingsFromStatus() },
                                    quit: { [weak self] in self?.quit(nil) })
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = []
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 270)
        popover.contentViewController = hosting
        statusPopover = popover
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Branding.menuBarImage()
            button.toolTip = Branding.appName
            button.target = self
            button.action = #selector(toggleStatusPanel(_:))
        }
        statusItem = item
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.mainWindow, window.isKeyWindow,
                  event.window === window, window.attachedSheet == nil, self.state?.page != .add,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased(),
                  let content = window.contentViewController as? PanelSplitViewController,
                  content.handleShortcut(key) else { return event }
            return nil
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationDidTerminate(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if !state.demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runPendingIfPossible() }
        }
        if state.demo && CommandLine.arguments.contains("--demo-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.statusItem?.button?.performClick(nil)
            }
        } else if !state.silentLaunch {
            // A normal launch opens the main window; closing it keeps the app
            // available from the status bar.
            DispatchQueue.main.async { [weak self] in self?.openPanel(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.cancelChatGPTLogin()
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let hide = applicationMenu.addItem(withTitle: "隐藏 \(Branding.appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        let hideOthers = applicationMenu.addItem(withTitle: "隐藏其他应用", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        let showAll = applicationMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAll.target = NSApp
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(withTitle: "退出 \(Branding.appName)", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = makeStandardEditMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleStatusPanel(_ sender: Any?) {
        guard let popover = statusPopover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            state?.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openSettingsFromStatus() {
        openPanel(nil)
        if let content = mainWindow?.contentViewController as? PanelSplitViewController {
            _ = content.handleShortcut(",")
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        nil // Both toolbar items are provided by AppKit.
    }

    @objc private func openPanel(_ sender: Any?) {
        guard let state else { return }
        NSApp.setActivationPolicy(.regular)
        let window: NSWindow
        if let existing = mainWindow {
            window = existing
        } else {
            let content = PanelSplitViewController(state: state)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.title = Branding.appName
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = PanelColors.windowBackground
            window.isMovableByWindowBackground = true
            window.delegate = self
            window.contentViewController = content
            let toolbar = NSToolbar(identifier: "MainToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
            // NSHostingController can replace the initial content size when
            // attached; set the intended window size after installing it.
            window.setContentSize(NSSize(width: 980, height: 700))
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 720, height: 520)
            window.collectionBehavior.insert(.fullScreenNone)
            // Open on the screen containing the menu-bar item, even when the
            // Mac has displays to the left or above the primary display.
            if let screen = statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first {
                let frame = screen.visibleFrame
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
            } else { window.center() }
            mainWindow = window
        }
        let openingWindow = !window.isVisible && !window.isMiniaturized
        if openingWindow {
            state.page = .manage
            state.editing = nil
            state.editingCurrent = nil
        }
        state.refresh()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if openingWindow {
            DispatchQueue.main.async { [weak window] in
                guard let window, window.isVisible, window.isKeyWindow, window.attachedSheet == nil else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if state?.closeToMenuBar == false { DispatchQueue.main.async { NSApp.terminate(nil) } }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow, state?.closeToMenuBar == true else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanel(nil)
        return false
    }

    private func requestSwitch(_ profile: CodexProfile, reauthenticate: Bool) {
        guard let state, !state.busy else { return }
        if state.demo {
            if CommandLine.arguments.contains("--demo-restart-dialog") { _ = askRestart(for: profile) }
            state.activate(profile, reauthenticate: reauthenticate)
            return
        }
        let pending = state.pendingProfileID == profile.id && state.pendingReauthentication == reauthenticate
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").filter { !$0.isTerminated }
        guard !running.isEmpty else {
            if !pending { state.cancelPending() }
            state.activate(profile, reauthenticate: reauthenticate, fromPending: pending)
            return
        }
        guard let appURL = running.first?.bundleURL else {
            state.onActivationFailure?("无法确定 Codex 应用的位置，请先手动退出后切换。")
            return
        }
        if askRestart(for: profile) == .alertFirstButtonReturn {
            state.cancelPending()
            state.activate(profile, reauthenticate: reauthenticate, closing: running, reopenURL: appURL)
        } else {
            state.scheduleActivation(profile, reauthenticate: reauthenticate)
        }
    }

    private func askRestart(for profile: CodexProfile) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "切换后需要重启 Codex"
        alert.informativeText = "已选择“\(state?.profileDisplayName(profile) ?? profile.name)”。立即重启时，应用会先退出 Codex，再完成切换并重新打开。选择稍后，将在 Codex 退出后完成切换。请先结束其他 Codex CLI 会话。"
        alert.addButton(withTitle: "立即重启")
        alert.addButton(withTitle: "稍后")
        return alert.runModal()
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.openai.codex" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runPendingIfPossible() }
    }

    private func runPendingIfPossible() {
        guard let state, !state.busy, let id = state.pendingProfileID,
              NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").allSatisfy(\.isTerminated) else { return }
        guard let profile = state.profiles.first(where: { $0.id == id }) else { state.cancelPending(); return }
        state.activate(profile, reauthenticate: state.pendingReauthentication, fromPending: true)
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(sender) }
}

@main
struct CodexAccountManagerMain {
    @MainActor static func main() {
        // Compatibility for existing third-party provider configurations.
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--credential-helper" {
            let configured = UserDefaults.standard.string(forKey: ProfileStore.preferenceKey)
            let directory = configured.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
                ?? ProfileStore.standard().directory
            guard let id = UUID(uuidString: CommandLine.arguments[2]), let secret = try? SavedCredentialFiles(root: directory).load(id: id) else { exit(1) }
            FileHandle.standardOutput.write(Data((secret + "\n").utf8))
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
