import Cocoa
import SwiftUI

struct WindowPlacement {
    var fullScreen = true
    var fraction: Double = 0.6
    var anchor = "center"
    init(fullScreen: Bool = true, fraction: Double = 0.6, anchor: String = "center") {
        self.fullScreen = fullScreen; self.fraction = fraction; self.anchor = anchor
    }
    init(defaults: UserDefaults) {
        fullScreen = defaults.string(forKey: "windowMode") != "window"
        fraction = defaults.object(forKey: "windowFraction") == nil ? 0.6 : defaults.double(forKey: "windowFraction")
        anchor = defaults.string(forKey: "windowAnchor") ?? "center"
    }
    func frame(screen: NSRect, visible: NSRect) -> NSRect {
        guard !fullScreen else { return screen }
        let ratio = min(0.95, max(0.35, fraction))
        let width = min(visible.width, max(min(640, visible.width), visible.width * ratio))
        let height = min(visible.height, width / 2)
        let actualWidth = min(width, height * 2)
        let inset: CGFloat = 12
        let x = anchor.hasSuffix("left") ? visible.minX + inset : (anchor.hasSuffix("right") ? visible.maxX - actualWidth - inset : visible.midX - actualWidth / 2)
        let y = anchor.hasPrefix("top") ? visible.maxY - height - inset : (anchor.hasPrefix("bottom") ? visible.minY + inset : visible.midY - height / 2)
        return NSRect(x: min(max(visible.minX, x), visible.maxX - actualWidth),
                      y: min(max(visible.minY, y), visible.maxY - height), width: actualWidth, height: height)
    }
}

enum LoginStartup {
    static let label = "local.soar.small-screen-login"
    static let ownedLabels = [label, "local.soar.small-screen-chatgpt-launcher",
                              "local.soar.small-screen-dev-login", "local.soar.small-screen-dev-host"]
    static func configuration(app: URL) -> [String: Any] {
        ["Label": label, "ProgramArguments": ["/usr/bin/open", "-g", app.path],
         "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
    }
    static func call(_ arguments: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    }
    static func owned(_ config: [String: Any], app: URL) -> Bool {
        (config["ProgramArguments"] as? [String])?.contains(app.path) == true
    }
    static func status(app: URL, agents: URL) -> (Bool, String) {
        let domain = "gui/\(getuid())"
        for name in ownedLabels {
            let file = agents.appendingPathComponent("\(name).plist")
            guard let data = try? Data(contentsOf: file),
                  let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], owned(config, app: app) else { continue }
            let registered = (try? call(["print", "\(domain)/\(name)"])) == 0
            if registered { return (true, name.contains("host") || name.contains("chatgpt") ? "当前随 ChatGPT / Codex 启停，开启后可改为独立登录启动" : "已设置登录 Mac 后独立启动") }
            return (false, "有启动项配置，但未注册；可重新开启")
        }
        return (false, "未开启登录自动启动")
    }
    static func setEnabled(_ enabled: Bool, app: URL, agents: URL,
                           run: ([String]) throws -> Int32 = LoginStartup.call) throws {
        guard app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == "local.soar.small-screen-status" else {
            throw NSError(domain: "Startup", code: 1, userInfo: [NSLocalizedDescriptionKey: "请从已安装的小屏应用修改启动项"])
        }
        let domain = "gui/\(getuid())"
        let target = agents.appendingPathComponent("\(label).plist")
        if let data = try? Data(contentsOf: target),
           let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], !owned(config, app: app) {
            throw NSError(domain: "Startup", code: 2, userInfo: [NSLocalizedDescriptionKey: "已有其他安装使用相同启动项，请先检查安装位置"])
        }
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let backup = try? Data(contentsOf: target)
        // Only retire the other owned launchers after the new registration succeeds.
        if enabled {
            let data = try PropertyListSerialization.data(fromPropertyList: configuration(app: app), format: .xml, options: 0)
            _ = try run(["bootout", "\(domain)/\(label)"])
            do {
                try data.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                guard try run(["enable", "\(domain)/\(label)"]) == 0,
                      try run(["bootstrap", domain, target.path]) == 0 else {
                    throw NSError(domain: "Startup", code: 3, userInfo: [NSLocalizedDescriptionKey: "登录启动项注册失败，请检查系统设置中的登录项"])
                }
            } catch {
                if let backup { try? backup.write(to: target, options: .atomic); _ = try? run(["bootstrap", domain, target.path]) }
                else { try? FileManager.default.removeItem(at: target) }
                throw error
            }
        }
        for name in ownedLabels where !enabled || name != label {
            let path = agents.appendingPathComponent("\(name).plist")
            guard let data = try? Data(contentsOf: path),
                  let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], owned(config, app: app) else { continue }
            _ = try run(["bootout", "\(domain)/\(name)"])
            try FileManager.default.removeItem(at: path)
        }
    }
}

struct SettingsDisplay: Identifiable {
    let id: String
    let name: String
    let isMain: Bool
}

final class ScreenSettings: ObservableObject {
    let defaults: UserDefaults
    @Published var displays: [SettingsDisplay] = []
    @Published var display = "auto"
    @Published var mode = "full"
    @Published var anchor = "center"
    @Published var fraction = 0.6
    @Published var startup = false
    @Published var startupDetail = ""
    @Published var error: String?
    @Published var busy = false
    let app = Bundle.main.bundleURL
    var agents: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents") }
    init(defaults: UserDefaults) { self.defaults = defaults }
    static func screenID(_ screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() { return CFUUIDCreateString(nil, uuid) as String }
        return "display-\(number)"
    }
    func refreshDisplays() {
        displays = NSScreen.screens.map { SettingsDisplay(id: Self.screenID($0), name: $0.localizedName,
            isMain: CGDisplayIsMain(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0) }
    }
    func reload() {
        refreshDisplays()
        display = defaults.string(forKey: "preferredDisplayID")
            ?? displays.first(where: { $0.name == defaults.string(forKey: "preferredDisplay") })?.id ?? "auto"
        let position = WindowPlacement(defaults: defaults)
        mode = position.fullScreen ? "full" : "window"; fraction = position.fraction; anchor = position.anchor
        refreshStartup()
    }
    func savePlacement() {
        if display == "auto" {
            defaults.removeObject(forKey: "preferredDisplayID"); defaults.removeObject(forKey: "preferredDisplay")
        } else {
            defaults.set(display, forKey: "preferredDisplayID")
            if let selected = displays.first(where: { $0.id == display }) { defaults.set(selected.name, forKey: "preferredDisplay") }
        }
        defaults.set(mode, forKey: "windowMode"); defaults.set(anchor, forKey: "windowAnchor"); defaults.set(fraction, forKey: "windowFraction")
    }
    func refreshStartup() {
        let state = LoginStartup.status(app: app, agents: agents)
        startup = state.0; startupDetail = state.1
    }
    func changeStartup(_ enabled: Bool) {
        guard !busy else { return }
        busy = true; error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try LoginStartup.setEnabled(enabled, app: self.app, agents: self.agents) }
            catch { failure = error.localizedDescription }
            let message = failure
            DispatchQueue.main.async { self.busy = false; self.error = message; self.refreshStartup() }
        }
    }
}

struct ScreenSettingsView: View {
    @ObservedObject var settings: ScreenSettings
    @ObservedObject var model: Model
    let apply: () -> Void
    private func placement() { settings.savePlacement(); apply() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("显示位置").font(.system(size: 30, weight: .semibold))
                VStack(spacing: 10) {
                    displayButton("自动选择最小副屏", id: "auto")
                    ForEach(settings.displays) { display in
                        displayButton(display.name + (display.isMain ? " · 主屏" : ""), id: display.id)
                    }
                    if settings.display != "auto", !settings.displays.contains(where: { $0.id == settings.display }) {
                        Text("所选显示屏未连接；连接后自动恢复，也可重新选择").foregroundColor(Theme.amber)
                    }
                }
                HStack {
                    Button("铺满显示屏") { settings.mode = "full"; placement() }.buttonStyle(ControlStyle(selected: settings.mode == "full")).fixedSize()
                    Button("窗口模式") { settings.mode = "window"; placement() }.buttonStyle(ControlStyle(selected: settings.mode == "window")).fixedSize()
                }
                if settings.mode == "window" {
                    Text("窗口位置").font(.system(size: 23, weight: .medium))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach([("top-left", "左上"), ("center", "居中"), ("top-right", "右上"), ("bottom-left", "左下"), ("bottom-right", "右下")], id: \.0) { id, title in
                            Button(title) { settings.anchor = id; placement() }.buttonStyle(ControlStyle(selected: settings.anchor == id))
                        }
                    }
                    HStack {
                        Text("窗口大小")
                        Slider(value: $settings.fraction, in: 0.35...0.95, step: 0.05) { editing in if !editing { placement() } }
                            .accessibilityLabel("窗口大小比例")
                        Text("\(Int(settings.fraction * 100))%").monospacedDigit().frame(width: 70)
                    }
                }
                Divider()
                Text("启动与外观").font(.system(size: 30, weight: .semibold))
                Toggle("登录 Mac 后自动启动", isOn: Binding(get: { settings.startup }, set: settings.changeStartup))
                    .toggleStyle(.switch).disabled(settings.busy)
                Text(settings.busy ? "正在更新启动项…" : settings.startupDetail).font(.system(size: 19)).foregroundColor(Theme.muted)
                if let error = settings.error { Text(error).foregroundColor(Theme.amber) }
                HStack {
                    Text("界面字号")
                    Button("减小") { model.scale = max(0.75, model.scale - 0.1); model.defaults.set(Double(model.scale), forKey: "fontScale") }.buttonStyle(ControlStyle())
                    Text("\(Int(model.scale * 100))%").monospacedDigit()
                    Button("放大") { model.scale = min(1.45, model.scale + 0.1); model.defaults.set(Double(model.scale), forKey: "fontScale") }.buttonStyle(ControlStyle())
                }
                Toggle("使用旧版工具栏", isOn: Binding(get: { model.classicToolbar }, set: { model.classicToolbar = $0; model.defaults.set($0, forKey: "classicToolbar") }))
                    .toggleStyle(.switch)
                HStack {
                    Button("显示任务窗口") { apply() }.buttonStyle(ControlStyle(selected: true))
                    Button("刷新状态") { settings.reload() }.buttonStyle(ControlStyle()).fixedSize()
                }
            }.font(.system(size: 22)).foregroundColor(Theme.ink).padding(28)
        }.background(Theme.background).preferredColorScheme(.dark).environment(\.controlScale, 0.9)
    }
    private func displayButton(_ title: String, id: String) -> some View {
        Button { settings.display = id; placement() } label: {
            HStack { Text(title).lineLimit(2); Spacer(); if settings.display == id { Image(systemName: "checkmark") } }
                .frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(ControlStyle(selected: settings.display == id))
    }
}
