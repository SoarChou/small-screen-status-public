import Cocoa

struct DirectQuestion: Codable {
    let id: String
    let threadID: String
    let title: String
    let questions: [InteractionQuestion]
    let created: Double
    let expires: Double
    let pid: Int32
    let status: String
}

extension Model {
    func loadDirectQuestions() {
        let folder = root.appendingPathComponent("screen-requests")
        let paths = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var next: [String: DirectQuestion] = [:]
        for path in paths where UUID(uuidString: path.deletingPathExtension().lastPathComponent) != nil {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
                  let size = attributes[.size] as? NSNumber, size.intValue < 128 * 1024,
                  let data = try? Data(contentsOf: path), let question = try? JSONDecoder().decode(DirectQuestion.self, from: data),
                  question.id == path.deletingPathExtension().lastPathComponent,
                  UUID(uuidString: question.threadID) != nil, question.status == "pending",
                  question.expires > now.timeIntervalSince1970, (1...3).contains(question.questions.count),
                  Set(question.questions.map(\.id)).count == question.questions.count,
                  question.questions.allSatisfy({ !$0.id.isEmpty && !$0.text.isEmpty }),
                  question.pid > 0, kill(question.pid, 0) == 0 else { continue }
            next[question.id] = question
        }
        directQuestions = next
        directSubmitted = directSubmitted.intersection(Set(next.keys))
    }
    func withDirectQuestions(_ incoming: [TaskInfo]) -> [TaskInfo] {
        var tasks = incoming
        for request in directQuestions.values.sorted(by: { $0.created < $1.created }) {
            let interaction = TaskInteraction(id: request.id, kind: "small_screen", questions: request.questions)
            if let index = tasks.firstIndex(where: { $0.id == request.threadID }) {
                if ["done", "error", "interrupted"].contains(tasks[index].status),
                   (tasks[index].finished ?? 0) >= request.created { continue }
                tasks[index].interactions = (tasks[index].interactions ?? []) + [interaction]
                tasks[index].status = "waiting"; tasks[index].stage = "等待小屏回答"
            } else {
                tasks.append(TaskInfo(id: request.threadID, title: request.title, source: "Codex", status: "waiting",
                                      stage: "等待小屏回答", started: request.created, updated: request.created,
                                      finished: nil, detail: "可在小屏直接提交", progress: nil, interactions: [interaction]))
            }
        }
        return tasks
    }
    func readyToSubmit(_ task: TaskInfo, _ request: TaskInteraction) -> Bool {
        !directSubmitted.contains(request.id) && request.questions.allSatisfy {
            !(replyDrafts[draftKey(task, request, $0)] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    @discardableResult func submitDirectAnswer(_ task: TaskInfo, _ request: TaskInteraction) -> Bool {
        guard request.kind == "small_screen", readyToSubmit(task, request),
              UUID(uuidString: request.id) != nil else { return false }
        do {
            let path = root.appendingPathComponent("screen-requests/\(request.id).json")
            let live = try JSONDecoder().decode(DirectQuestion.self, from: Data(contentsOf: path))
            guard live.id == request.id, live.threadID == task.id, live.status == "pending",
                  live.expires > Date().timeIntervalSince1970, live.pid > 0, kill(live.pid, 0) == 0,
                  live.questions.map(\.id) == request.questions.map(\.id) else { throw NSError(domain: "expired-question", code: 1) }
            let answers = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, replyDrafts[draftKey(task, request, $0)] ?? "") })
            guard answers.values.allSatisfy({ $0.count <= 16000 }) else { throw NSError(domain: "answer-too-long", code: 1) }
            let data = try JSONSerialization.data(withJSONObject: ["id": request.id, "threadID": task.id, "answers": answers])
            let answerPath = root.appendingPathComponent("screen-requests/\(request.id).answer.json")
            // No duplicate delivery when the user clicks twice before the waiter acknowledges.
            guard !FileManager.default.fileExists(atPath: answerPath.path) else { throw NSError(domain: "already-submitted", code: 1) }
            try data.write(to: answerPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: answerPath.path)
            directSubmitted.insert(request.id); directReplyError = nil
            notify("回答已提交，等待任务接收")
            return true
        } catch {
            directReplyError = "未能提交：问题可能已过期或任务已停止，草稿已保留"
            return false
        }
    }
}
