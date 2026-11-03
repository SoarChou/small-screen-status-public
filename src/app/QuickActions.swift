import Cocoa
import SwiftUI

struct WorkTask: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let source: String
    let sessionId: String?
    init(_ task: TaskInfo) { id = task.id; title = task.title; source = task.source; sessionId = task.sessionId }
    var task: TaskInfo {
        TaskInfo(id: id, title: title, source: source, status: "done", stage: "", started: 0,
                 updated: 0, finished: nil, detail: nil, progress: nil, sessionId: sessionId)
    }
}

struct QuickNote: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    let text: String
    let created: Date
    let task: WorkTask?
}

struct WorkResult: Codable, Identifiable, Equatable {
    let id: String
    let task: WorkTask
    let created: Date
    var paths: [String]
    var read = false
}

struct WorkReminder: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    let task: WorkTask
    let deadline: Date?
    var delivered = false
}

struct WorkbenchState: Codable, Equatable {
    var notes: [QuickNote] = []
    var results: [WorkResult] = []
    var reminders: [WorkReminder] = []
    var draft = ""
}

extension Model {
    var quickTarget: TaskInfo? {
        pinnedTask ?? (tasks.count == 1 ? tasks.first : nil)
    }
    var unreadResults: Int { workbench.results.filter { !$0.read }.count }
    var pendingReminders: [WorkReminder] { workbench.reminders.filter { !$0.delivered } }
    var runningTimer: WidgetDefinition? {
        widgets.first { $0.kind == "timer" && widgetState($0.id).timerEnd != nil }
    }
    var quickTimer: WidgetDefinition? {
        runningTimer ?? widgets.first { $0.kind == "timer" }
    }
    func presentQuickPanel(_ panel: String) {
        guard attentionAlert == nil else { notify("请先处理或关闭当前提示，再使用快捷入口"); return }
        guard displayAvailable else { notify("请先从菜单栏选择可用的显示屏"); return }
        quickPanel = panel
        onShow?()
    }
    func loadWorkbench() {
        let path = root.appendingPathComponent("workbench.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do { workbench = try JSONDecoder().decode(WorkbenchState.self, from: Data(contentsOf: path)) }
        catch { storageError = "快捷区数据无法读取；原文件已保留" }
    }
    @discardableResult func saveWorkbench(_ value: WorkbenchState) -> Bool {
        do {
            let path = root.appendingPathComponent("workbench.json")
            try JSONEncoder().encode(value).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            workbench = value; storageError = nil
            return true
        } catch { storageError = "未能保存，请保留输入后重试"; return false }
    }
    func editQuickDraft(_ text: String) {
        var next = workbench; next.draft = text; _ = saveWorkbench(next)
    }
    @discardableResult func saveQuickNote(taskID: String?) -> Bool {
        let text = workbench.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var next = workbench
        next.notes.insert(QuickNote(text: text, created: now, task: taskID.flatMap { cache[$0] }.map(WorkTask.init)), at: 0)
        next.draft = ""
        guard saveWorkbench(next) else { return false }
        notify("已存入随手记"); return true
    }
    func observeResults(_ incoming: [TaskInfo]) {
        var next = workbench
        for task in incoming {
            guard task.status == "done" else { continue }
            let key = "\(task.id)/\(task.finished ?? task.updated)"
            if let index = next.results.firstIndex(where: { $0.id == key }) {
                for path in task.artifacts ?? [] where path.hasPrefix("/") && !next.results[index].paths.contains(path) {
                    next.results[index].paths.append(path)
                }
            } else if let previous = cache[task.id], previous.status != "done" {
                next.results.insert(WorkResult(id: key, task: WorkTask(task), created: now,
                                              paths: (task.artifacts ?? []).filter { $0.hasPrefix("/") }), at: 0)
            }
            for index in next.reminders.indices where next.reminders[index].task.id == task.id
                && next.reminders[index].deadline == nil && !next.reminders[index].delivered {
                next.reminders[index].delivered = true
                // Use the same event ID as ordinary completion alerts to avoid duplicates.
                alerts.enqueue(AttentionAlert(id: "result/\(key)", kind: .completion,
                                              title: task.title, targetID: task.id, created: now), now: now)
                notify("你关注的任务已完成 · \(task.title)")
            }
        }
        if next != workbench { _ = saveWorkbench(next) }
    }
    func addReminder(task: WorkTask, minutes: Int?) {
        var next = workbench
        if let existing = next.reminders.firstIndex(where: { !$0.delivered && $0.task.id == task.id && ($0.deadline == nil) == (minutes == nil) }) {
            next.reminders.remove(at: existing)
        }
        next.reminders.append(WorkReminder(task: task, deadline: minutes.map { now.addingTimeInterval(Double($0 * 60)) }))
        if saveWorkbench(next) { notify(minutes.map { "\($0) 分钟后提醒" } ?? "将在任务完成时提醒"); quickPanel = nil }
    }
    func cancelReminder(_ id: String) {
        var next = workbench; next.reminders.removeAll { $0.id == id }; _ = saveWorkbench(next)
    }
    func checkReminders() {
        let due = pendingReminders.filter { $0.deadline.map { $0 <= now } ?? false }
        guard !due.isEmpty else { return }
        var next = workbench
        for reminder in due {
            if let index = next.reminders.firstIndex(where: { $0.id == reminder.id }) { next.reminders[index].delivered = true }
        }
        guard saveWorkbench(next) else { return }
        for reminder in due {
            alerts.enqueue(AttentionAlert(id: "reminder/\(reminder.id)", kind: .reminder,
                                          title: reminder.task.title, targetID: reminder.task.id, created: now), now: now)
        }
    }
    func snoozeReminder(_ alert: AttentionAlert) {
        guard let task = workbench.reminders.last(where: { $0.task.id == alert.targetID })?.task else { return }
        addReminder(task: task, minutes: 5)
    }
    func openRememberedTask(_ id: String) {
        if let live = cache[id] { open(live) }
        else if let saved = workbench.reminders.last(where: { $0.task.id == id })?.task { open(saved.task) }
    }
    func markResultRead(_ id: String) {
        var next = workbench
        if let index = next.results.firstIndex(where: { $0.id == id }) { next.results[index].read = true }
        _ = saveWorkbench(next)
    }
    func linkArtifact(_ id: String) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = true; picker.allowsMultipleSelection = true
        picker.prompt = "关联产物"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK else { return }
        var next = workbench
        if let index = next.results.firstIndex(where: { $0.id == id }) {
            for url in picker.urls where !next.results[index].paths.contains(url.path) { next.results[index].paths.append(url.path) }
        }
        _ = saveWorkbench(next)
    }
    func openArtifact(_ path: String, resultID: String) {
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { notify("文件已移动或不存在，请重新关联"); return }
        let url = URL(fileURLWithPath: path)
        if ["pdf", "png", "jpg", "jpeg", "txt", "md", "csv", "json", "xlsx", "pptx", "docx"].contains(url.pathExtension.lowercased()) {
            guard NSWorkspace.shared.open(url) else { notify("无法打开这个产物"); return }
        } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        markResultRead(resultID)
    }
}

struct QuickActionBar: View {
    @ObservedObject var model: Model
    let size: CGFloat
    var body: some View {
        HStack(spacing: 8 * size) {
            if model.questionCount > 0 {
                Button { model.tab = "interactions" } label: { Label("待回答 \(model.questionCount)", systemImage: "bubble.left") }
                    .foregroundColor(Theme.amber)
            }
            if let timer = model.quickTimer {
                let state = model.widgetState(timer.id)
                HStack(spacing: 6 * size) {
                    Button { model.presentQuickPanel("timer") } label: {
                        Label(state.timerEnd != nil ? countdownText(max(0, (state.timerEnd ?? 0) - model.now.timeIntervalSince1970)) : "番茄钟", systemImage: "timer")
                            .monospacedDigit()
                    }.help("番茄钟 · ⌃⌥⌘P")
                    Button {
                    if state.timerEnd == nil && (state.timerFinished || state.timerRemaining == state.timerDuration) {
                        model.startTimer(timer.id, minutes: 25)
                    } else { model.toggleTimer(timer.id) }
                    } label: { Image(systemName: state.timerEnd == nil ? "play.fill" : "pause.fill") }
                    .accessibilityLabel(state.timerEnd == nil ? "开始或继续番茄钟" : "暂停番茄钟")
                }
            }
            Button { model.presentQuickPanel("note") } label: { Label("记一句", systemImage: "square.and.pencil") }.help("随手记 · ⌃⌥⌘N")
            Button { model.presentQuickPanel("results") } label: { Label("产物\(model.unreadResults > 0 ? " \(model.unreadResults)" : "")", systemImage: "tray") }
                .foregroundColor(model.unreadResults > 0 ? Theme.accent : Theme.muted)
                .help("完成产物 · ⌃⌥⌘R")
            Button { model.presentQuickPanel("remind") } label: {
                Label("稍后\(model.pendingReminders.isEmpty ? "" : " \(model.pendingReminders.count)")", systemImage: "bell")
            }.help("稍后提醒 · ⌃⌥⌘B")
        }.buttonStyle(ControlStyle()).fixedSize(horizontal: true, vertical: false)
    }
}

struct QuickPanel: View {
    @ObservedObject var model: Model
    let unit: CGFloat
    @State private var taskID = ""
    @State private var choosingTask = false
    var size: CGFloat { unit * model.scale }
    var panel: String { model.quickPanel ?? "note" }
    var body: some View {
        ZStack {
            Theme.background.opacity(0.96)
            VStack(alignment: .leading, spacing: 15 * unit) {
                HStack {
                    Text(panel == "note" ? "随手记" : (panel == "results" ? "完成产物" : (panel == "timer" ? "番茄钟" : (panel == "sources" ? "任务来源" : "稍后提醒"))))
                        .font(.system(size: 34 * size, weight: .semibold))
                    Spacer()
                    Button("返回") { model.quickPanel = nil }.buttonStyle(ControlStyle())
                }
                if panel == "note" || panel == "remind" {
                    HStack {
                        Button { choosingTask.toggle() } label: {
                            HStack {
                                Text(model.cache[taskID]?.title ?? "选择关联任务").lineLimit(1)
                                Spacer()
                                Image(systemName: choosingTask ? "chevron.up" : "chevron.down")
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(ControlStyle()).accessibilityLabel("选择关联任务")
                    }
                }
                if choosingTask { taskChoices }
                else if panel == "sources" { sourceChoices }
                else if panel == "note" { noteContent }
                else if panel == "results" { resultsContent }
                else if panel == "timer" {
                    if let timer = model.quickTimer { WidgetContent(model: model, widget: timer, unit: unit).id(timer.id) }
                    else { Text("请先在工具中添加计时器").font(.system(size: 24 * size)) }
                }
                else { remindersContent }
                if let error = model.storageError { Text(error).foregroundColor(Theme.amber).font(.system(size: 18 * size)) }
            }.padding(24 * unit).background(Theme.surface).cornerRadius(18 * unit)
                .overlay(RoundedRectangle(cornerRadius: 18 * unit).stroke(Theme.line))
                .padding(24 * unit)
        }.onAppear { taskID = model.quickTarget?.id ?? "" }
        .id(panel)
        .foregroundColor(Theme.ink)
    }
    var taskChoices: some View {
        ScrollView {
            VStack(spacing: 12 * unit) {
                Button { taskID = ""; choosingTask = false } label: {
                    Text("不关联任务").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(ControlStyle(selected: taskID.isEmpty))
                ForEach(model.tasks) { task in
                    Button { taskID = task.id; choosingTask = false } label: {
                        Text(task.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(ControlStyle(selected: taskID == task.id))
                }
            }
        }.frame(maxHeight: .infinity)
    }
    var sourceChoices: some View {
        VStack(spacing: 16 * unit) {
            ForEach(["Codex", "DSH", "脚本"], id: \.self) { source in
                Button { model.toggleSource(source) } label: {
                    HStack {
                        Text(source)
                        Spacer()
                        Image(systemName: model.sourceEnabled(source) ? "checkmark.circle.fill" : "circle")
                    }.frame(maxWidth: .infinity).padding(.vertical, 7 * unit)
                }.buttonStyle(ControlStyle(selected: model.sourceEnabled(source)))
            }
            Spacer(minLength: 0)
        }
    }
    var noteContent: some View {
        VStack(alignment: .leading, spacing: 12 * unit) {
            StatusTextEditor(text: Binding(get: { model.workbench.draft }, set: model.editQuickDraft),
                             fontSize: 25 * size, label: "随手记内容", autofocus: true,
                             onSubmit: { if model.saveQuickNote(taskID: taskID.isEmpty ? nil : taskID) { model.quickPanel = nil } })
                .frame(height: 115 * unit).padding(8 * unit).background(Theme.background).cornerRadius(9 * unit)
            HStack {
                Button("存下这句") { _ = model.saveQuickNote(taskID: taskID.isEmpty ? nil : taskID) }
                    .buttonStyle(ControlStyle(selected: true)).disabled(model.workbench.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("⌘↩ 保存并返回 · 草稿自动保存").foregroundColor(Theme.muted)
            }.font(.system(size: 24 * size))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12 * unit) {
                    ForEach(model.workbench.notes) { note in
                        VStack(alignment: .leading, spacing: 4 * unit) {
                            Text(note.text).font(.system(size: 22 * size)).textSelection(.enabled)
                            HStack {
                                Text(note.created, style: .date); Text(note.created, style: .time)
                                if let task = note.task { Text("· \(task.title)").lineLimit(1) }
                            }.font(.system(size: 16 * size)).foregroundColor(Theme.muted)
                        }
                        Divider()
                    }
                }
            }.frame(maxHeight: .infinity)
        }
    }
    var resultsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14 * unit) {
                if model.workbench.results.isEmpty {
                    Text("新完成的任务会留在这里；脚本可上报文件，或手动关联产物。")
                        .font(.system(size: 24 * size)).foregroundColor(Theme.muted).padding(.vertical, 30 * unit)
                }
                ForEach(model.workbench.results) { result in
                    VStack(alignment: .leading, spacing: 10 * unit) {
                        HStack {
                            if !result.read { Circle().fill(Theme.accent).frame(width: 7 * unit, height: 7 * unit) }
                            Text(result.task.title).font(.system(size: 25 * size, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(result.created, style: .time).foregroundColor(Theme.muted)
                        }
                        ForEach(result.paths, id: \.self) { path in
                            Button { model.openArtifact(path, resultID: result.id) } label: {
                                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc")
                            }.buttonStyle(ControlStyle()).help(path)
                        }
                        HStack {
                            Button("打开对话 / 记录") { model.open(result.task.task) }.buttonStyle(ControlStyle())
                            Button("关联文件或目录") { model.linkArtifact(result.id) }.buttonStyle(ControlStyle())
                            if !result.read { Button("标记已看") { model.markResultRead(result.id) }.buttonStyle(ControlStyle()) }
                        }
                    }.font(.system(size: 19 * size)).padding(15 * unit).background(Theme.background).cornerRadius(12 * unit)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var remindersContent: some View {
        VStack(alignment: .leading, spacing: 18 * unit) {
            HStack(spacing: 12 * unit) {
                ForEach([5, 15, 30], id: \.self) { minutes in
                    Button("\(minutes) 分钟后") {
                        if let task = model.cache[taskID] { model.addReminder(task: WorkTask(task), minutes: minutes) }
                    }.buttonStyle(ControlStyle()).disabled(model.cache[taskID] == nil)
                }
                Button("完成时提醒") {
                    if let task = model.cache[taskID] { model.addReminder(task: WorkTask(task), minutes: nil) }
                }.buttonStyle(ControlStyle(selected: true)).disabled(model.cache[taskID]?.status != "running" && model.cache[taskID]?.status != "waiting")
            }.font(.system(size: 25 * size))
            if taskID.isEmpty { Text("先选择一个任务").font(.system(size: 21 * size)).foregroundColor(Theme.muted) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16 * unit) {
                    ForEach(model.pendingReminders) { reminder in
                        HStack {
                            Text(reminder.task.title).lineLimit(1)
                            Spacer()
                            if let deadline = reminder.deadline { Text(countdownText(max(0, deadline.timeIntervalSince(model.now)))).monospacedDigit() }
                            else { Text("完成时") }
                            Button("取消") { model.cancelReminder(reminder.id) }.buttonStyle(ControlStyle())
                        }.font(.system(size: 22 * size))
                    }
                }
            }.frame(maxHeight: .infinity)
        }
    }
}
