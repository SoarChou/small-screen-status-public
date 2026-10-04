import Cocoa

struct LaunchGate {
    static let chatGPTID = "com.openai.codex"
    let hostID: String
    var pending = false
    init(hostID: String = Self.chatGPTID) { self.hostID = hostID }
    mutating func request(sourceID: String?, screenRunning: Bool) -> Bool {
        guard sourceID == hostID, !screenRunning, !pending else { return false }
        pending = true
        return true
    }
    mutating func completed() { pending = false }
    func shouldClose(sourceID: String?, hostRunning: Bool) -> Bool { sourceID == hostID && !hostRunning }
    func transition(previous: Set<Int32>, current: Set<Int32>) -> Bool? {
        previous == current ? nil : !current.isEmpty
    }
}

final class ChatGPTLauncher {
    let appURL: URL
    let workspace = NSWorkspace.shared
    let screenID: String
    var gate: LaunchGate
    var observers: [NSObjectProtocol] = []
    var pendingClose: DispatchWorkItem?
    var processCheck: Timer?
    var observedHostPIDs: Set<Int32> = []
    var sampledHost = false
    init(appURL: URL, hostID: String = LaunchGate.chatGPTID) {
        self.appURL = appURL
        self.screenID = Bundle(url: appURL)?.bundleIdentifier ?? "local.soar.small-screen-status"
        self.gate = LaunchGate(hostID: hostID)
    }
    var hostRunning: Bool { NSRunningApplication.runningApplications(withBundleIdentifier: gate.hostID).contains { !$0.isTerminated } }
    func start() {
        observers.append(workspace.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                            object: nil, queue: nil) { [weak self] event in
            guard let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.async { self?.chatGPTStarted(app) }
        })
        observers.append(workspace.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                            object: nil, queue: nil) { [weak self] event in
            guard let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.async { self?.chatGPTStopped(app) }
        })
        // Some macOS sessions omit workspace lifecycle notifications. Check
        // actual process transitions as well, without relaunching a manual quit.
        checkHostProcesses()
        let check = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkHostProcesses() }
        RunLoop.main.add(check, forMode: .common)
        processCheck = check
    }
    func checkHostProcesses() {
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: gate.hostID).filter { !$0.isTerminated }
        let current = Set(hosts.map(\.processIdentifier))
        if !sampledHost {
            sampledHost = true
            if let app = hosts.first { chatGPTStarted(app) }
        } else if let started = gate.transition(previous: observedHostPIDs, current: current) {
            if started, let app = hosts.first { chatGPTStarted(app) }
            else { scheduleClose() }
        }
        observedHostPIDs = current
    }
    func chatGPTStarted(_ app: NSRunningApplication) {
        guard app.bundleIdentifier == gate.hostID else { return }
        pendingClose?.cancel(); pendingClose = nil
        let screenRunning = NSRunningApplication.runningApplications(withBundleIdentifier: screenID).contains { !$0.isTerminated }
        guard gate.request(sourceID: app.bundleIdentifier, screenRunning: screenRunning) else { return }
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            gate.completed(); report("Small Screen Status bundle missing: \(appURL.path)"); return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = false
        workspace.openApplication(at: appURL, configuration: config) { [weak self] launched, error in
            DispatchQueue.main.async {
                self?.gate.completed()
                if let error = error { self?.report("Small Screen Status launch failed: \(error.localizedDescription)") }
                else if let launched = launched {
                    self?.report("ChatGPT started; Small Screen Status running (pid \(launched.processIdentifier))")
                    // The host may have exited while Launch Services was opening the screen.
                    if self?.hostRunning == false { self?.scheduleClose() }
                }
            }
        }
    }
    func chatGPTStopped(_ app: NSRunningApplication) {
        guard app.bundleIdentifier == gate.hostID else { return }
        scheduleClose()
    }
    func scheduleClose() {
        pendingClose?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.closeIfHostGone() }
        pendingClose = work
        // Allow a quick restart or a remaining instance to keep the screen open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    func closeIfHostGone() {
        guard gate.shouldClose(sourceID: gate.hostID, hostRunning: hostRunning) else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: screenID) where !app.isTerminated {
            if app.terminate() { report("ChatGPT exited; requested normal Small Screen Status exit (pid \(app.processIdentifier))") }
            else { report("Small Screen Status did not accept the normal exit request") }
        }
    }
    func report(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--list-displays" {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let displays = NSScreen.screens.map { screen -> [String:Any] in
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return ["name": screen.localizedName, "width": Int(screen.frame.width), "height": Int(screen.frame.height), "main": CGDisplayIsMain(id) != 0]
    }
    let data = try! JSONSerialization.data(withJSONObject: displays, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--quit-screen" {
    let target = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath().standardizedFileURL
    guard Bundle(url: target)?.bundleIdentifier == "local.soar.small-screen-status" else { exit(2) }
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "local.soar.small-screen-status").filter {
        $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target && !$0.isTerminated
    }
    for app in apps { guard app.terminate() else { exit(1) } }
    let end = Date().addingTimeInterval(5)
    while apps.contains(where: { !$0.isTerminated }) && Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
    exit(apps.contains(where: { !$0.isTerminated }) ? 1 : 0)
} else if CommandLine.arguments.contains("--self-test") {
    var gate = LaunchGate()
    var count = 0
    func check(_ condition: Bool) { precondition(condition); count += 1 }
    check(!gate.request(sourceID: "other.app", screenRunning: false))
    check(!gate.request(sourceID: nil, screenRunning: false))
    check(!gate.request(sourceID: LaunchGate.chatGPTID, screenRunning: true))
    check(gate.request(sourceID: LaunchGate.chatGPTID, screenRunning: false))
    check(!gate.shouldClose(sourceID: "other.app", hostRunning: false))
    check(!gate.shouldClose(sourceID: nil, hostRunning: false))
    check(!gate.shouldClose(sourceID: LaunchGate.chatGPTID, hostRunning: true))
    check(gate.shouldClose(sourceID: LaunchGate.chatGPTID, hostRunning: false))
    check(gate.transition(previous: [], current: []) == nil)
    check(gate.transition(previous: [1], current: [1]) == nil)
    check(gate.transition(previous: [], current: [1]) == true)
    check(gate.transition(previous: [1], current: []) == false)
    check(gate.transition(previous: [1], current: [2]) == true)
    check(gate.transition(previous: [1,2], current: [2]) == true)
    check(!gate.request(sourceID: LaunchGate.chatGPTID, screenRunning: false))
    gate.completed()
    check(!gate.request(sourceID: LaunchGate.chatGPTID, screenRunning: true))
    check(gate.request(sourceID: LaunchGate.chatGPTID, screenRunning: false))
    print("Launcher checks: \(count) passed")
} else {
    let args = CommandLine.arguments
    guard args.count == 2 || (args.count == 4 && args[2] == "--host-id") else {
        FileHandle.standardError.write(Data("Usage: ChatGPTSmallScreenLauncher /absolute/path/SmallScreen.app [--host-id bundle.id]\n".utf8))
        exit(2)
    }
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let launcher = ChatGPTLauncher(appURL: URL(fileURLWithPath: args[1]), hostID: args.count == 4 ? args[3] : LaunchGate.chatGPTID)
    launcher.start()
    withExtendedLifetime(launcher) { application.run() }
}
