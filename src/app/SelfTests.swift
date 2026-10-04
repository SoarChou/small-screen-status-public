import Cocoa
import CoreFoundation

enum SelfTests {
    static func run() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("small-screen-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "small-screen-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = Model(root: root, defaults: defaults)
        model.now = Date(timeIntervalSince1970: 1000)
        var count = 0
        func check(_ condition: Bool, _ message: String) { count += 1; if !condition { fatalError(message) } }
        let displays = [DisplayOption(name: "Main", area: 100, isMain: true),
                        DisplayOption(name: "Large", area: 900, isMain: false),
                        DisplayOption(name: "Small", area: 200, isMain: false)]
        check(DisplayOption.selectedIndex(displays, preferred: nil) == 2, "Automatic display choice did not select the smallest secondary screen")
        check(DisplayOption.selectedIndex(displays, preferred: "Large") == 1, "Explicit display choice was ignored")
        check(DisplayOption.selectedIndex(displays, preferred: "Missing") == nil, "Disconnected explicit display covered another screen")
        check(DisplayOption.selectedIndex(Array(displays.prefix(1)), preferred: nil) == nil, "Automatic display choice covered the main screen")
        check(DisplayOption.selectedIndex(displays, preferred: "Main") == 0, "Explicit main display choice was rejected")
        let a = TaskInfo(id: "11111111-1111-4111-8111-111111111111", title: "A", source: "Codex", status: "running",
                         stage: "思考中", started: 900, updated: 1000, finished: nil, detail: "进展", progress: nil)
        let b = TaskInfo(id: "22222222-2222-4222-8222-222222222222", title: "B", source: "Codex", status: "running",
                         stage: "处理中", started: 901, updated: 1001, finished: nil, detail: "进展", progress: nil)
        func snapshot(_ tasks: [TaskInfo]) -> Snapshot { Snapshot(heartbeat: 1000, primary: tasks.first, active: tasks, active_count: tasks.count, display_tasks: tasks, error: nil) }
        model.ingest(snapshot([a,b]))
        model.ingest(snapshot([b,a]))
        check(model.task(at: 1)?.id == a.id && model.task(at: 2)?.id == b.id, "Task positions moved with updates")
        check(model.task(at: 0) == nil && model.task(at: 3) == nil, "Invalid positions were accepted")
        check(a.threadURL?.absoluteString == "codex://threads/\(a.id)", "Wrong thread deep link")
        let pendingJSON = "{\"id\":\"\(a.id)\",\"title\":\"A\",\"source\":\"Codex\",\"status\":\"waiting\",\"stage\":\"等待你的操作\",\"started\":900,\"updated\":1000,\"interactions\":[{\"id\":\"call-a\",\"kind\":\"question\",\"questions\":[{\"id\":\"0\",\"title\":\"待回答\",\"text\":\"选哪一个？\",\"options\":[{\"label\":\"A\",\"description\":\"解释\"}]}]}]}"
        let waiting = try! JSONDecoder().decode(TaskInfo.self, from: Data(pendingJSON.utf8))
        model.ingest(snapshot([waiting,b]))
        check(model.questionCount == 1 && model.attentionTasks.first?.id == a.id, "Pending questions were not decoded")
        let request = waiting.interactions![0], question = waiting.interactions![0].questions[0]
        let key = model.draftKey(waiting, request, question)
        model.editReply(key, "自己的答案")
        check(model.replyDrafts[key] == "自己的答案" && model.questionCount == 1, "Draft falsely resolved a request")
        model.ingest(snapshot([a,b]))
        check(model.questionCount == 0 && model.replyDrafts[key] == nil, "Resolved questions or drafts remained")
        model.editInstruction(a.id, "下一步处理任务")
        let drafts = try! JSONDecoder().decode([String:String].self, from: Data(contentsOf: root.appendingPathComponent("instruction-drafts.json")))
        check(drafts[a.id] == "下一步处理任务" && drafts[b.id] == nil, "Instruction drafts were not scoped to their target")
        model.toggleTab(); check(model.tab == "interactions", "Tab cycling skipped interactions")
        model.toggleTab(); model.toggleTab(); check(model.tab == "tasks", "Tab cycling did not return to tasks")
        model.pin(position: 2)
        check(model.pinnedID == b.id && model.pinUntil?.timeIntervalSince1970 == 1300, "Pin duration or position wrong")
        model.ingest(snapshot([a]))
        check(model.pinnedTask?.id == b.id && model.tasks.count == 2, "Pinned result vanished when absent from overview")
        model.tick(at: Date(timeIntervalSince1970: 1299))
        check(model.pinnedID == b.id, "Pin expired early")
        model.tick(at: Date(timeIntervalSince1970: 1300))
        check(model.pinnedID == nil, "Pin failed to expire")
        check(Hotkeys.operation(101)?.0 == "open" && Hotkeys.operation(209)?.1 == 9 && Hotkeys.operation(999) == nil, "Shortcut routing incorrect")
        check(Set(Hotkeys.numberCodes).count == 9, "Position key codes overlap")
        model.now = Date(timeIntervalSince1970: 2000)
        model.startTimer("focus", minutes: 5, at: model.now)
        model.now = Date(timeIntervalSince1970: 2121)
        model.toggleTimer("focus", at: model.now)
        check(model.widgetState("focus").timerRemaining == 179 && model.widgetState("focus").timerEnd == nil, "Pause lost remaining time")
        model.toggleTimer("focus", at: model.now)
        model.tick(at: Date(timeIntervalSince1970: 2301))
        check(model.widgetState("focus").timerFinished && model.widgetState("focus").timerEnd == nil, "Timer did not complete")
        check(countdownText(59.001) == "01:00" && countdownText(0.001) == "00:01" && countdownText(0) == "00:00",
              "Countdown displayed zero or dropped a second before the deadline")
        check(durationText(0.999) == "00:00", "Elapsed task duration was incorrectly rounded up")
        let precise = Model(root: root, defaults: defaults)
        precise.now = Date(timeIntervalSince1970: 1000) // Deliberately stale last UI refresh.
        precise.startTimer("fractional", minutes: 1, at: Date(timeIntervalSince1970: 2000.375))
        check(precise.widgetState("fractional").timerEnd == 2060.375, "Start used the previous UI refresh time")
        precise.toggleTimer("fractional", at: Date(timeIntervalSince1970: 2001.625))
        check(precise.widgetState("fractional").timerRemaining == 58.75, "Pause lost fractional remaining time")
        precise.toggleTimer("fractional", at: Date(timeIntervalSince1970: 3000.125))
        check(precise.widgetState("fractional").timerEnd == 3058.875, "Resume accumulated rounding error")
        precise.tick(at: Date(timeIntervalSince1970: 3058.874))
        check(!precise.widgetState("fractional").timerFinished, "Timer completed before its precise deadline")
        precise.tick(at: Date(timeIntervalSince1970: 3058.875))
        check(precise.widgetState("fractional").timerFinished, "Timer missed its precise deadline")
        // Exercise the real scheduled timer in a common tracking mode. A timer
        // registered only in the default mode stalls here, reproducing the bug.
        let ticking = Model(root: root.appendingPathComponent("clock"), defaults: defaults)
        ticking.start()
        defer { ticking.timer?.invalidate() }
        let began = Date()
        ticking.changeWidget("short") { $0.timerEnd = began.addingTimeInterval(0.25).timeIntervalSince1970 }
        let tracking = RunLoop.Mode("SmallScreenTrackingTest")
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: tracking.rawValue as CFString))
        let limit = began.addingTimeInterval(0.45)
        while Date() < limit { _ = RunLoop.main.run(mode: tracking, before: limit) }
        check(ticking.now.timeIntervalSince(began) >= 0.25, "UI clock stalled while tracking interaction")
        check(ticking.widgetState("short").timerFinished, "Timer completion stalled while tracking interaction")
        model.changeWidget("notes") { $0.note = "待处理问题" }
        model.changeWidget("checklist") { $0.checked = ["input"] }
        let data = try! Data(contentsOf: root.appendingPathComponent("tools-state.json"))
        let saved = try! JSONDecoder().decode([String: WidgetState].self, from: data)
        check(saved["notes"]?.note == "待处理问题" && saved["checklist"]?.checked == ["input"], "Tool state was not saved")
        let sample = "{\"version\":1,\"widgets\":[{\"id\":\"n\",\"kind\":\"note\",\"title\":\"新工具\"}]}"
        try! Data(sample.utf8).write(to: root.appendingPathComponent("widgets.json"))
        model.reloadWidgets()
        check(model.widgets.first?.title == "新工具", "Registry hot reload failed")
        try! Data("invalid".utf8).write(to: root.appendingPathComponent("widgets.json"))
        model.reloadWidgets()
        check(model.widgets.first?.title == "新工具" && model.toolError != nil, "Invalid registry replaced existing tools")
        let coordinator = AttentionCoordinator()
        let time = Date(timeIntervalSince1970: 1000)
        coordinator.observe([a], now: time)
        coordinator.enqueue(AttentionAlert(id: "timer-test", kind: .timer, title: "计时", targetID: "focus", created: time), now: time)
        coordinator.observe([waiting], now: time.addingTimeInterval(1))
        check(coordinator.active?.kind == .question && coordinator.queue.first?.kind == .timer, "Question did not preempt timer")
        coordinator.holdQuestion(); coordinator.advance(now: time.addingTimeInterval(60))
        check(coordinator.active?.kind == .question && coordinator.active?.expires == nil, "Editing question was dismissed by timeout")
        coordinator.observe([a], now: time.addingTimeInterval(61))
        check(coordinator.active?.kind == .timer, "Answering question did not resume queued notification")
        coordinator.advance(now: time.addingTimeInterval(82))
        check(coordinator.active == nil, "Timer notification failed to expire")
        coordinator.observe([waiting], now: time.addingTimeInterval(83))
        check(coordinator.active == nil, "An already shown question repeated")
        let done = TaskInfo(id: a.id, title: a.title, source: "Codex", status: "done", stage: "本轮完成", started: 900, updated: 1100, finished: 1100, detail: nil, progress: nil)
        let resultEvents = AttentionCoordinator()
        resultEvents.observe([done], now: time)
        check(resultEvents.active == nil, "Historical completions were replayed on startup")
        resultEvents.observe([a], now: time.addingTimeInterval(1)); resultEvents.observe([done], now: time.addingTimeInterval(2))
        check(resultEvents.active?.kind == .completion, "Real completion was not shown")
        resultEvents.observe([done], now: time.addingTimeInterval(3))
        check(resultEvents.queue.isEmpty, "Completion was duplicated on refresh")
        let restore = Model(root: root, defaults: defaults)
        restore.now = time; restore.ingest(snapshot([a,b])); restore.pin(b); restore.tab = "tools"
        restore.timerAttention("focus", end: 1000)
        restore.tick(at: time.addingTimeInterval(25))
        check(restore.attentionAlert == nil && restore.tab == "tools" && restore.pinnedID == b.id && restore.pinUntil?.timeIntervalSince1970 == 1325,
              "Notification changed the previous page or consumed pin time")
        try! Data("{\"version\":1,\"widgets\":[{\"id\":\"list\",\"kind\":\"checklist\",\"title\":\"我的清单\",\"items\":[],\"customField\":\"保留\"}]}".utf8).write(to: root.appendingPathComponent("widgets.json"))
        check(model.addChecklistItem("list", text: "自己的任务步骤"), "Adding a real checklist item failed")
        let registry = try! JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("widgets.json"))) as! [String:Any]
        let row = (registry["widgets"] as! [[String:Any]])[0]
        check((row["items"] as! [[String:Any]])[0]["text"] as? String == "自己的任务步骤" && row["customField"] as? String == "保留",
              "Checklist edit lost the item or unrelated configuration")
        let directRoot = root.appendingPathComponent("direct")
        let requestFolder = directRoot.appendingPathComponent("screen-requests")
        try! FileManager.default.createDirectory(at: requestFolder, withIntermediateDirectories: true)
        let directModel = Model(root: directRoot, defaults: defaults)
        let liveTime = Date().timeIntervalSince1970
        let requestID = UUID().uuidString.lowercased()
        let firstQuestion = InteractionQuestion(id: "0", title: "选择", text: "采用哪套配置？", options: [])
        let secondQuestion = InteractionQuestion(id: "1", title: "说明", text: "补充要求？", options: [])
        let liveRequest = DirectQuestion(id: requestID, threadID: a.id, title: a.title, questions: [firstQuestion, secondQuestion],
                                        created: liveTime, expires: liveTime + 300, pid: getpid(), status: "pending")
        let requestPath = requestFolder.appendingPathComponent("\(requestID).json")
        try! JSONEncoder().encode(liveRequest).write(to: requestPath)
        directModel.loadDirectQuestions(); directModel.ingest(snapshot([a,b]))
        let directTask = directModel.cache[a.id]!, directRequest = directTask.interactions![0]
        check(directModel.questionCount == 2 && directTask.status == "waiting" && directModel.cache[b.id]?.status == "running",
              "Direct question was not scoped to its original task")
        directModel.editReply(directModel.draftKey(directTask, directRequest, firstQuestion), "配置甲")
        check(!directModel.submitDirectAnswer(directTask, directRequest), "Partial multi-question answers were submitted")
        directModel.editReply(directModel.draftKey(directTask, directRequest, secondQuestion), "中文要求")
        check(directModel.submitDirectAnswer(directTask, directRequest), "Direct answer was not written")
        let answerPath = requestFolder.appendingPathComponent("\(requestID).answer.json")
        let delivered = try! JSONSerialization.jsonObject(with: Data(contentsOf: answerPath)) as! [String:Any]
        check(delivered["threadID"] as? String == a.id && (delivered["answers"] as? [String:String])?["1"] == "中文要求",
              "Direct answer lost text or targeted the wrong task")
        check(!directModel.submitDirectAnswer(directTask, directRequest), "Direct answer was submitted twice")
        let acknowledged = DirectQuestion(id: requestID, threadID: a.id, title: a.title, questions: liveRequest.questions,
                                         created: liveTime, expires: liveTime + 300, pid: getpid(), status: "answered")
        try! JSONEncoder().encode(acknowledged).write(to: requestPath)
        directModel.loadDirectQuestions(); directModel.ingest(snapshot([a,b]))
        check(directModel.questionCount == 0 && directModel.attentionAlert == nil && directModel.replyDrafts.isEmpty,
              "Acknowledged direct question or drafts remained")
        let composing = StatusTextView(frame: .zero)
        var committedText = ""
        composing.onCommittedText = { committedText = $0.string }
        composing.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        composing.unmarkText()
        check(!composing.hasMarkedText() && committedText == "中文", "IME commit failed to publish the final text")
        print("Native behavior checks: \(count) passed")
    }
}
