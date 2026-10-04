import Foundation

enum AttentionKind: String, Equatable {
    case question, failure, timer, completion
    var priority: Int { switch self { case .question: return 3; case .failure, .timer: return 2; case .completion: return 1 } }
    var seconds: Double { switch self { case .question: return 45; case .failure, .timer: return 20; case .completion: return 10 } }
}

struct AttentionAlert: Identifiable, Equatable {
    let id: String
    let kind: AttentionKind
    let title: String
    let targetID: String
    var requestID: String? = nil
    var created: Date
    var expires: Date? = nil
}

final class AttentionCoordinator {
    var active: AttentionAlert?
    var queue: [AttentionAlert] = []
    var seen: [String] = []
    var revision = 0
    var baseline = false
    var statuses: [String: String] = [:]
    func enqueue(_ alert: AttentionAlert, now: Date) {
        guard !seen.contains(alert.id) else { return }
        seen.append(alert.id); if seen.count > 512 { seen.removeFirst(seen.count - 512) }; revision += 1
        if let current = active, alert.kind.priority > current.kind.priority {
            // A higher-priority request temporarily interrupts the current notification.
            if current.expires.map({ $0 > now }) ?? true { queue.append(current) }
            active = nil
        }
        queue.append(alert)
        queue.sort { $0.kind.priority == $1.kind.priority ? $0.created < $1.created : $0.kind.priority > $1.kind.priority }
        advance(now: now)
    }
    func observe(_ tasks: [TaskInfo], now: Date) {
        for task in tasks {
            for request in task.interactions ?? [] {
                enqueue(AttentionAlert(id: "question/\(task.id)/\(request.id)", kind: .question, title: task.title,
                                       targetID: task.id, requestID: request.id, created: now), now: now)
            }
            if baseline, ["done", "error", "interrupted"].contains(task.status),
               let old = statuses[task.id], !["done", "error", "interrupted"].contains(old) {
                let key = "result/\(task.id)/\(task.finished ?? task.updated)"
                enqueue(AttentionAlert(id: key, kind: task.status == "done" ? .completion : .failure,
                                       title: task.title, targetID: task.id, created: now), now: now)
            }
            statuses[task.id] = task.status
        }
        baseline = true
        let liveQuestions = Set(tasks.flatMap { task in (task.interactions ?? []).map { "question/\(task.id)/\($0.id)" } })
        queue.removeAll { $0.kind == .question && !liveQuestions.contains($0.id) }
        if let current = active, current.kind == .question, !liveQuestions.contains(current.id) { active = nil }
        advance(now: now)
    }
    func advance(now: Date) {
        if let deadline = active?.expires, deadline <= now { active = nil }
        if active == nil, !queue.isEmpty {
            var next = queue.removeFirst()
            next.created = now
            next.expires = now.addingTimeInterval(next.kind.seconds)
            active = next
        }
    }
    func dismiss(now: Date) { active = nil; advance(now: now) }
    func clear() { active = nil; queue.removeAll() }
    func holdQuestion() { if active?.kind == .question { active?.expires = nil } }
}

extension Model {
    func syncAttention() {
        let previous = attentionAlert
        if previous == nil, alerts.active != nil { attentionStarted = now }
        if alerts.active == nil, let started = attentionStarted {
            if let until = pinUntil { pinUntil = until.addingTimeInterval(max(0, now.timeIntervalSince(started))) }
            attentionStarted = nil
        }
        if attentionAlert != alerts.active { attentionAlert = alerts.active }
        if queuedAlertCount != alerts.queue.count { queuedAlertCount = alerts.queue.count }
        if alerts.revision != savedAlertRevision {
            savedAlertRevision = alerts.revision
            if let data = try? JSONEncoder().encode(alerts.seen) { try? data.write(to: root.appendingPathComponent("attention-seen.json"), options: .atomic) }
        }
        if let alert = attentionAlert, previous?.id != alert.id { onShow?() }
    }
    func dismissAttention() { alerts.dismiss(now: now); syncAttention() }
    func closeAttention() { alerts.clear(); syncAttention() }
    func holdAttention() { alerts.holdQuestion(); syncAttention() }
    func timerAttention(_ id: String, end: Double) {
        alerts.enqueue(AttentionAlert(id: "timer/\(id)/\(end)", kind: .timer,
                                      title: widgets.first { $0.id == id }?.title ?? "计时", targetID: id, created: now), now: now)
        syncAttention()
    }
}
