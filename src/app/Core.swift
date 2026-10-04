import Cocoa
import SwiftUI

enum Theme {
    static let background = Color(red: 0.064, green: 0.070, blue: 0.073)
    static let surface = Color(red: 0.096, green: 0.104, blue: 0.106)
    static let elevated = Color(red: 0.132, green: 0.143, blue: 0.145)
    static let ink = Color(red: 0.93, green: 0.93, blue: 0.88)
    static let muted = Color(red: 0.65, green: 0.69, blue: 0.67)
    static let accent = Color(red: 0.66, green: 0.82, blue: 0.72)
    static let line = Color.white.opacity(0.10)
    static let amber = Color(red: 0.90, green: 0.72, blue: 0.45)
    static let red = Color(red: 0.91, green: 0.53, blue: 0.47)
}

struct TaskInfo: Decodable, Identifiable {
    let id: String
    let title: String
    let source: String
    var status: String
    var stage: String
    let started: Double
    let updated: Double
    let finished: Double?
    let detail: String?
    let progress: Double?
    var interactions: [TaskInteraction]? = nil
    var color: Color {
        switch status {
        case "waiting", "unknown", "interrupted": return Theme.amber
        case "error": return Theme.red
        default: return Theme.accent
        }
    }
    var statusLabel: String {
        switch status {
        case "done": return source == "Codex" ? "本轮完成" : "执行完成"
        case "waiting": return "等你操作"
        case "error": return "执行失败"
        case "interrupted": return "已中断"
        case "unknown": return "待确认"
        default: return "执行中"
        }
    }
    var threadURL: URL? {
        guard source == "Codex", UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }
    func duration(at date: Date) -> String { durationText(max(0, (finished ?? date.timeIntervalSince1970) - started)) }
}

struct TaskInteraction: Decodable, Identifiable {
    let id: String
    let kind: String
    let questions: [InteractionQuestion]
}
struct InteractionQuestion: Codable, Identifiable {
    let id: String
    let title: String
    let text: String
    let options: [InteractionOption]
}
struct InteractionOption: Codable { let label: String; let description: String }

func durationText(_ interval: Double) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds/3600, seconds/60%60, seconds%60) }
    return String(format: "%02d:%02d", seconds/60, seconds%60)
}

// A countdown must keep showing 1 until its actual deadline, rather than 0
// throughout the final fractional second. Elapsed task durations still round down.
func countdownText(_ interval: Double) -> String { durationText(ceil(max(0, interval))) }

struct Snapshot: Decodable {
    let heartbeat: Double
    let primary: TaskInfo?
    let active: [TaskInfo]
    let active_count: Int
    let display_tasks: [TaskInfo]?
    let error: String?
}

struct WidgetDefinition: Codable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String?
    let icon: String?
    let presets: [Int]?
    let items: [CheckItem]?
    let zones: [ClockZone]?
    let links: [QuickLink]?
    let file: String?
    var monitor: Bool? = nil
    var symbol: String {
        icon ?? ["timer":"timer", "note":"square.and.pencil", "checklist":"checklist",
                 "clock":"clock", "links":"link", "readout":"chart.bar.xaxis"][kind] ?? "square.grid.2x2"
    }
}
struct CheckItem: Codable, Identifiable { let id: String; let text: String }
struct ClockZone: Codable { let title: String; let timezone: String }
struct QuickLink: Codable { let title: String; let url: String }
struct WidgetRegistry: Codable { let version: Int; let widgets: [WidgetDefinition] }
struct Readout: Decodable { let label: String; let value: String; let detail: String? }

struct WidgetSummary: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let value: String
    var attention = false
}

struct WidgetState: Codable {
    var note = ""
    var checked: [String] = []
    var timerEnd: Double?
    var timerRemaining = 25.0 * 60
    var timerDuration = 25.0 * 60
    var timerFinished = false
    var timerPhase: String? = nil
}

final class Model: ObservableObject {
    @Published var state: Snapshot?
    @Published var now = Date()
    @Published var scale: CGFloat = 1
    @Published var displayAvailable = true
    @Published var tab = "tasks"
    @Published var orderedIDs: [String] = []
    @Published var pinnedID: String?
    @Published var pinUntil: Date?
    @Published var widgets: [WidgetDefinition] = []
    @Published var selectedWidgetID: String?
    @Published var widgetStates: [String: WidgetState] = [:]
    @Published var toolError: String?
    @Published var storageError: String?
    @Published var registryEditError: String?
    @Published var hotkeyError: String?
    @Published var toast: String?
    @Published var lastOpenedThread: String?
    @Published var replyDrafts: [String: String] = [:]
    @Published var instructionDrafts: [String: String] = [:]
    @Published var readouts: [String: Readout] = [:]
    @Published var attentionAlert: AttentionAlert?
    @Published var queuedAlertCount = 0
    @Published var directSubmitted: Set<String> = []
    @Published var directReplyError: String?
    var directQuestions: [String: DirectQuestion] = [:]
    let alerts = AttentionCoordinator()
    var attentionStarted: Date?
    var savedAlertRevision = -1
    var cache: [String: TaskInfo] = [:]
    var timer: Timer?
    var lastReload = Date.distantPast
    var lastPoll = Date.distantPast
    var toastUntil = Date.distantPast
    var registeredHotkeys = 0
    let root: URL
    let defaults: UserDefaults
    var onShow: (() -> Void)?

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SmallScreenStatus")
        self.defaults = defaults
        let saved = defaults.double(forKey: "fontScale")
        scale = saved > 0 ? CGFloat(saved) : 1
    }
    var tasks: [TaskInfo] { orderedIDs.compactMap { cache[$0] } }
    var pinnedTask: TaskInfo? { pinnedID.flatMap { cache[$0] } }
    var stale: Bool { state == nil || now.timeIntervalSince1970 - (state?.heartbeat ?? 0) > 5 }
    var selectedWidget: WidgetDefinition? { widgets.first { $0.id == selectedWidgetID } ?? widgets.first }
    var attentionTasks: [TaskInfo] { tasks.filter { !($0.interactions ?? []).isEmpty } }
    var questionCount: Int { attentionTasks.reduce(0) { total, task in total + (task.interactions ?? []).reduce(0) { $0 + $1.questions.count } } }

    func start() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = root.appendingPathComponent("widgets.json")
        if !FileManager.default.fileExists(atPath: registry.path), let bundled = Bundle.main.url(forResource: "widgets", withExtension: "json") {
            try? FileManager.default.copyItem(at: bundled, to: registry)
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("tools-state.json")),
           let states = try? JSONDecoder().decode([String: WidgetState].self, from: data) { widgetStates = states }
        selectedWidgetID = defaults.string(forKey: "selectedWidget")
        if let data = try? Data(contentsOf: root.appendingPathComponent("attention-seen.json")),
           let keys = try? JSONDecoder().decode([String].self, from: data) { alerts.seen = Array(keys.suffix(512)) }
        if let data = try? Data(contentsOf: root.appendingPathComponent("reply-drafts.json")),
           let drafts = try? JSONDecoder().decode([String: String].self, from: data) { replyDrafts = drafts }
        if let data = try? Data(contentsOf: root.appendingPathComponent("instruction-drafts.json")),
           let drafts = try? JSONDecoder().decode([String: String].self, from: data) { instructionDrafts = drafts }
        tick(at: Date())
        let clock = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick(at: Date()) }
        clock.tolerance = 0.015
        // Keep updating during scroll tracking and menu interactions, too.
        RunLoop.main.add(clock, forMode: .common)
        timer = clock
    }
    func ingest(_ snapshot: Snapshot) {
        state = snapshot
        let incoming = withDirectQuestions(snapshot.display_tasks ?? snapshot.active)
        var ids = incoming.map(\.id)
        if ids.isEmpty, let primary = snapshot.primary { ids = [primary.id]; cache[primary.id] = primary }
        for task in incoming { cache[task.id] = task }
        if let pinned = pinnedID, !ids.contains(pinned), cache[pinned] != nil { ids.append(pinned) }
        let preserved = orderedIDs.filter { ids.contains($0) }
        let next = preserved + ids.filter { !preserved.contains($0) }
        if next != orderedIDs { orderedIDs = next }
        cache = cache.filter { ids.contains($0.key) }
        alerts.observe(tasks, now: now)
        syncAttention()
        let liveKeys = Set(attentionTasks.flatMap { task in (task.interactions ?? []).flatMap { request in request.questions.map { draftKey(task, request, $0) } } })
        let kept = replyDrafts.filter { liveKeys.contains($0.key) }
        if kept.count != replyDrafts.count { replyDrafts = kept; saveReplyDrafts() }
    }
    func tick(at date: Date) {
        now = date
        if attentionAlert == nil, let until = pinUntil, date >= until { clearPin() }
        let poll = date.timeIntervalSince(lastPoll) >= 0.5 || date < lastPoll
        if poll {
            lastPoll = date
            loadDirectQuestions()
            if let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
               let value = try? JSONDecoder().decode(Snapshot.self, from: data) { ingest(value) }
            else if let prior = state { ingest(prior) }
            else if !directQuestions.isEmpty { ingest(Snapshot(heartbeat: date.timeIntervalSince1970, primary: nil, active: [], active_count: 0, display_tasks: [], error: nil)) }
        }
        if date.timeIntervalSince(lastReload) >= 3 { lastReload = date; reloadWidgets() }
        var changed = false
        for (id, current) in widgetStates {
            if let end = current.timerEnd, date.timeIntervalSince1970 >= end {
                var value = current
                value.timerEnd = nil; value.timerRemaining = 0; value.timerFinished = true
                widgetStates[id] = value; changed = true
                notify("计时完成 · \(widgets.first { $0.id == id }?.title ?? "专注计时")")
                timerAttention(id, end: end)
            }
        }
        if changed { saveWidgets() }
        if toast != nil && date >= toastUntil { toast = nil }
        alerts.advance(now: date); syncAttention()
        if poll { writeDiagnostics() }
    }
    func task(at position: Int) -> TaskInfo? { position > 0 && position <= tasks.count ? tasks[position - 1] : nil }
    func pin(_ task: TaskInfo) {
        pinnedID = task.id; pinUntil = now.addingTimeInterval(300); tab = "tasks"
        onShow?(); writeDiagnostics()
    }
    func pin(position: Int) {
        guard let task = task(at: position) else { notify("位置 \(position) 当前没有任务"); return }
        pin(task)
    }
    func clearPin() { pinnedID = nil; pinUntil = nil }
    func open(position: Int) {
        guard let task = task(at: position) else { notify("位置 \(position) 当前没有任务"); return }
        open(task)
    }
    func open(_ task: TaskInfo) {
        guard let url = task.threadURL else {
            if task.source == "脚本" { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent("tasks/\(task.id).json")]) }
            else { notify("这个任务没有可打开的对话") }
            return
        }
        if NSWorkspace.shared.open(url) { lastOpenedThread = task.id; writeDiagnostics() }
        else { notify("无法打开 Codex 对话") }
    }
    func notify(_ message: String) { toast = message; toastUntil = now.addingTimeInterval(7) }
    func toggleTab() {
        let tabs = ["tasks", "interactions", "tools"]
        tab = tabs[((tabs.firstIndex(of: tab) ?? 0) + 1) % tabs.count]
        onShow?(); writeDiagnostics()
    }
    func editInstruction(_ id: String, _ value: String) {
        instructionDrafts[id] = value
        if let data = try? JSONEncoder().encode(instructionDrafts) {
            try? data.write(to: root.appendingPathComponent("instruction-drafts.json"), options: .atomic)
        }
    }
    func draftKey(_ task: TaskInfo, _ request: TaskInteraction, _ question: InteractionQuestion) -> String {
        "\(task.id)/\(request.id)/\(question.id)"
    }
    func editReply(_ key: String, _ value: String) { holdAttention(); replyDrafts[key] = value; saveReplyDrafts() }
    func saveReplyDrafts() {
        if let data = try? JSONEncoder().encode(replyDrafts) { try? data.write(to: root.appendingPathComponent("reply-drafts.json"), options: .atomic) }
    }
    func prepareReply(_ task: TaskInfo, text: String) {
        guard task.threadURL != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        open(task)
        notify("回复已复制，在对话中粘贴并提交")
    }
    func selectWidget(_ id: String) { selectedWidgetID = id; defaults.set(id, forKey: "selectedWidget") }
    func openWidget(_ id: String) {
        guard widgets.contains(where: { $0.id == id }) else { return }
        selectWidget(id); tab = "tools"; onShow?(); writeDiagnostics()
    }
    func reloadWidgets() {
        do {
            let value = try JSONDecoder().decode(WidgetRegistry.self, from: Data(contentsOf: root.appendingPathComponent("widgets.json")))
            let kinds = Set(["timer", "note", "checklist", "clock", "links", "readout"])
            guard value.version == 1, Set(value.widgets.map(\.id)).count == value.widgets.count,
                  value.widgets.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && kinds.contains($0.kind) }) else {
                throw NSError(domain: "widgets", code: 1, userInfo: [NSLocalizedDescriptionKey: "类型、ID 或版本无效"])
            }
            widgets = value.widgets; toolError = nil
            readouts = Dictionary(uniqueKeysWithValues: widgets.compactMap { widget in
                loadReadout(widget).map { (widget.id, $0) }
            })
        } catch { toolError = "工具配置无法读取，请检查 widgets.json" }
    }
    func widgetState(_ id: String) -> WidgetState { widgetStates[id] ?? WidgetState() }
    func loadReadout(_ widget: WidgetDefinition) -> Readout? {
        guard widget.kind == "readout", let path = widget.file, path.hasPrefix("/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 1024 * 1024,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 1024 * 1024 else { return nil }
        return try? JSONDecoder().decode(Readout.self, from: data)
    }
    var widgetSummaries: [WidgetSummary] {
        let summaries: [WidgetSummary] = widgets.compactMap { widget in
            guard widget.monitor != false else { return nil }
            let current = widgetState(widget.id)
            var value: String
            var attention = false
            switch widget.kind {
            case "timer":
                let seconds = max(0, current.timerEnd.map { $0 - now.timeIntervalSince1970 } ?? current.timerRemaining)
                attention = current.timerFinished
                if current.timerFinished { value = current.timerPhase == "break" ? "休息结束" : "计时完成" }
                else if current.timerEnd != nil { value = (current.timerPhase == "break" ? "休息 " : "") + countdownText(seconds) }
                else if current.timerRemaining < current.timerDuration { value = "暂停 \(countdownText(seconds))" }
                else { value = "待开始" }
            case "checklist":
                let ids = Set((widget.items ?? []).map(\.id))
                let checked = Set(current.checked).intersection(ids).count
                value = "\(checked)/\(ids.count)"
            case "note":
                let lines = current.note.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                guard lines > 0 else { return nil }
                value = "\(lines) 行笔记"
            case "clock":
                guard let zone = (widget.zones ?? []).first(where: { $0.timezone == "UTC" }) ?? widget.zones?.first,
                      let timeZone = TimeZone(identifier: zone.timezone) else { return nil }
                let formatter = DateFormatter(); formatter.timeZone = timeZone; formatter.dateFormat = "HH:mm"
                value = "\(zone.title) \(formatter.string(from: now))"
            case "readout": value = readouts[widget.id]?.value ?? "等待读数"
            default: return nil
            }
            return WidgetSummary(id: widget.id, title: widget.title, symbol: widget.symbol, value: value, attention: attention)
        }
        // Completed timers stay visible before other summaries, until reset or restarted.
        return summaries.filter(\.attention) + summaries.filter { !$0.attention }
    }
    func changeWidget(_ id: String, _ edit: (inout WidgetState) -> Void) {
        var value = widgetState(id); edit(&value); widgetStates[id] = value; saveWidgets()
    }
    func saveWidgets() {
        do {
            let data = try JSONEncoder().encode(widgetStates)
            try data.write(to: root.appendingPathComponent("tools-state.json"), options: .atomic)
            storageError = nil
        } catch { storageError = "小工具内容未保存，请检查本机存储空间或目录权限" }
    }
    func startTimer(_ id: String, minutes: Int, phase: String = "focus", at date: Date = Date()) {
        guard (1...1440).contains(minutes) else { return }
        now = date
        changeWidget(id) { $0.timerDuration = Double(minutes * 60); $0.timerRemaining = $0.timerDuration;
            $0.timerEnd = date.timeIntervalSince1970 + $0.timerDuration; $0.timerFinished = false; $0.timerPhase = phase }
    }
    func toggleTimer(_ id: String, at date: Date = Date()) {
        now = date
        changeWidget(id) {
            if let end = $0.timerEnd { $0.timerRemaining = max(0, end - date.timeIntervalSince1970); $0.timerEnd = nil }
            else { if $0.timerRemaining <= 0 { $0.timerRemaining = $0.timerDuration }; $0.timerEnd = date.timeIntervalSince1970 + $0.timerRemaining; $0.timerFinished = false }
        }
    }
    func resetTimer(_ id: String) { changeWidget(id) { $0.timerEnd = nil; $0.timerRemaining = $0.timerDuration; $0.timerFinished = false } }
    @discardableResult func addChecklistItem(_ id: String, text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return editChecklist(id) { $0.append(["id":"item-\(UUID().uuidString.lowercased())", "text":text]) }
    }
    @discardableResult func removeChecklistItem(_ id: String, itemID: String) -> Bool {
        editChecklist(id) { $0.removeAll { $0["id"] as? String == itemID } }
    }
    private func editChecklist(_ id: String, edit: (inout [[String:Any]]) -> Void) -> Bool {
        do {
            let path = root.appendingPathComponent("widgets.json")
            let data = try Data(contentsOf: path)
            guard var registry = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var rows = registry["widgets"] as? [[String: Any]],
                  let index = rows.firstIndex(where: { $0["id"] as? String == id && $0["kind"] as? String == "checklist" }) else {
                throw NSError(domain: "registry", code: 1)
            }
            var items = rows[index]["items"] as? [[String: Any]] ?? []
            edit(&items)
            rows[index]["items"] = items; registry["widgets"] = rows
            let updated = try JSONSerialization.data(withJSONObject: registry, options: [.prettyPrinted, .sortedKeys])
            _ = try JSONDecoder().decode(WidgetRegistry.self, from: updated)
            try data.write(to: root.appendingPathComponent("widgets.previous.json"), options: .atomic)
            try updated.write(to: path, options: .atomic)
            registryEditError = nil; reloadWidgets(); return true
        } catch { registryEditError = "检查项未修改，请检查工具配置或本机存储"; return false }
    }
    func undoChecklistEdit() {
        do {
            let backup = root.appendingPathComponent("widgets.previous.json")
            let data = try Data(contentsOf: backup)
            _ = try JSONDecoder().decode(WidgetRegistry.self, from: data)
            try data.write(to: root.appendingPathComponent("widgets.json"), options: .atomic)
            try FileManager.default.removeItem(at: backup)
            registryEditError = nil; reloadWidgets()
        } catch { registryEditError = "没有可恢复的上一次清单修改" }
    }
    func writeDiagnostics() {
        let value: [String: Any] = ["positions":orderedIDs, "pinned":pinnedID ?? "", "pinUntil":pinUntil?.timeIntervalSince1970 ?? 0,
                                  "tab":tab, "lastOpenedThread":lastOpenedThread ?? "", "registeredHotkeys":registeredHotkeys,
                                  "hotkeyError":hotkeyError ?? "", "attention":attentionAlert?.kind.rawValue ?? "",
                                  "attentionTarget":attentionAlert?.targetID ?? "", "attentionExpires":attentionAlert?.expires?.timeIntervalSince1970 ?? 0,
                                  "queuedAlerts":queuedAlertCount, "keyboardActive":NSApplication.shared.isActive,
                                  "editing":NSApplication.shared.keyWindow?.firstResponder is NSTextView]
        if let data = try? JSONSerialization.data(withJSONObject: value) { try? data.write(to: root.appendingPathComponent("ui-state.json"), options: .atomic) }
    }
}
