import Cocoa
import SwiftUI

final class DisplayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            NSApplication.shared.activate(ignoringOtherApps: true)
            makeKey()
        }
        super.sendEvent(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A separate development bundle can show fixtures without touching live task state.
    let previewRoot = Bundle.main.object(forInfoDictionaryKey: "SmallScreenPreviewRoot") as? String
    lazy var model = Model(root: previewRoot.map { URL(fileURLWithPath: $0) })
    var window: DisplayWindow!
    var statusItem: NSStatusItem!
    var worker: Process?
    var workerLog: FileHandle?
    var preferredDisplay: String?
    var displayMenu: NSMenu!
    var hotkeys: Hotkeys?
    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditingMenu()
        preferredDisplay = UserDefaults.standard.string(forKey: "preferredDisplay")
        let savedScale = UserDefaults.standard.double(forKey: "fontScale")
        model.scale = savedScale > 0 ? CGFloat(savedScale) : 1
        model.start()
        if previewRoot != nil { model.tab = "interactions" }
        window = DisplayWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = previewRoot == nil ? "小屏任务状态" : "小屏交互预览（测试数据）"
        window.isReleasedWhenClosed = false
        // Keep the dedicated small-display surface above Dock/menu-bar chrome.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: Dashboard(model: model))
        window.backgroundColor = .black
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◉"
        let menu = NSMenu()
        for (title, action, key) in [("显示小屏窗口", #selector(showWindow), ""),
                                     ("任务总览", #selector(overview), "0"),
                                     ("小工具", #selector(tools), "t"),
                                     ("放大字号", #selector(larger), "+"),
                                     ("缩小字号", #selector(smaller), "-"),
                                     ("隐藏窗口", #selector(hideWindow), ""),
                                     ("退出小屏状态", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        let displays = NSMenuItem(title: "选择显示屏", action: nil, keyEquivalent: "")
        displayMenu = NSMenu(title: "选择显示屏")
        displays.submenu = displayMenu
        menu.insertItem(displays, at: 3)
        NotificationCenter.default.addObserver(self, selector: #selector(placeWindow), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                if self?.model.attentionAlert != nil { self?.model.dismissAttention() }
                else if !(self?.window.firstResponder is NSTextView) { self?.hideWindow() }
                else { return event }
                return nil
            }
            if self?.window.firstResponder is NSTextView { return event }
            if event.characters == "+" || event.characters == "=" { self?.larger(); return nil }
            if event.characters == "-" { self?.smaller(); return nil }
            return event
        }
        model.onShow = { [weak self] in
            guard let self = self else { return }
            if self.model.attentionAlert != nil { self.window.makeFirstResponder(self.window.contentView) }
            self.showWindow()
        }
        if previewRoot == nil {
            hotkeys = Hotkeys(model: model)
            hotkeys?.start()
            startWorker()
        }
        showWindow()
    }
    func installEditingMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "小屏状态")
        appMenu.addItem(withTitle: "退出小屏状态", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "z"),
                                     ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                     ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            let item = editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
            if action == "redo:" { item.keyEquivalentModifierMask = [.command, .shift] }
        }
        editItem.submenu = editMenu; menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu
    }
    func startWorker() {
        guard let path = Bundle.main.path(forResource: "monitor", ofType: "py", inDirectory: "Scripts") else { return }
        try? FileManager.default.createDirectory(at: model.root, withIntermediateDirectories: true)
        let log = model.root.appendingPathComponent("monitor.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        workerLog = try? FileHandle(forWritingTo: log)
        workerLog?.seekToEndOfFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "pythonExecutable") ?? "/usr/bin/python3")
        process.arguments = [path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = workerLog ?? FileHandle.nullDevice
        do { try process.run(); worker = process } catch { NSLog("monitor: %@", error.localizedDescription) }
    }
    @objc func placeWindow() {
        let screens = NSScreen.screens
        let choices = screens.map { DisplayOption(name: $0.localizedName, area: $0.frame.width * $0.frame.height,
                                                  isMain: CGDisplayIsMain(displayID($0)) != 0) }
        let selected = DisplayOption.selectedIndex(choices, preferred: preferredDisplay)
        displayMenu.removeAllItems()
        for (index, screen) in screens.enumerated() {
            let item = NSMenuItem(title: "\(screen.localizedName) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))", action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = screen.localizedName
            item.state = index == selected ? .on : .off
            displayMenu.addItem(item)
        }
        let automatic = NSMenuItem(title: "自动选择最小的副屏", action: #selector(automaticDisplay), keyEquivalent: "")
        automatic.target = self
        displayMenu.addItem(.separator()); displayMenu.addItem(automatic)
        guard let index = selected else {
            model.displayAvailable = false
            window.orderOut(nil)
            statusItem.button?.toolTip = "目标屏幕未连接；可在菜单中选择显示屏"
            return
        }
        let screen = screens[index]
        model.displayAvailable = true
        window.setFrame(screen.frame, display: true)
        statusItem.button?.toolTip = "小屏任务状态 · \(screen.localizedName)"
    }
    func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    @objc func selectDisplay(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        preferredDisplay = name
        UserDefaults.standard.set(name, forKey: "preferredDisplay")
        showWindow()
    }
    @objc func automaticDisplay() {
        preferredDisplay = nil
        UserDefaults.standard.removeObject(forKey: "preferredDisplay")
        showWindow()
    }
    @objc func showWindow() { placeWindow(); if model.displayAvailable { window.orderFrontRegardless() } }
    @objc func overview() { model.clearPin(); model.tab = "tasks"; showWindow() }
    @objc func tools() { model.tab = "tools"; showWindow() }
    @objc func hideWindow() { window.orderOut(nil) }
    @objc func larger() { model.scale = min(1.45, model.scale + 0.1); UserDefaults.standard.set(Double(model.scale), forKey: "fontScale") }
    @objc func smaller() { model.scale = max(0.75, model.scale - 0.1); UserDefaults.standard.set(Double(model.scale), forKey: "fontScale") }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        if let editor = window?.firstResponder as? NSTextView { editor.unmarkText() }
        window?.makeFirstResponder(nil)
        model.timer?.invalidate()
        model.saveWidgets(); model.saveReplyDrafts()
        hotkeys?.stop(); worker?.terminate(); try? workerLog?.close()
    }
}

struct DisplayOption {
    let name: String
    let area: CGFloat
    let isMain: Bool
    static func selectedIndex(_ choices: [DisplayOption], preferred: String?) -> Int? {
        if let preferred = preferred { return choices.firstIndex { $0.name == preferred } }
        return choices.indices.filter { !choices[$0].isMain }.min { choices[$0].area < choices[$1].area }
    }
}

@main
enum SmallScreenMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") { SelfTests.run(); return }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
