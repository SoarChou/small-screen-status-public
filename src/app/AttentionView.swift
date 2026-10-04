import SwiftUI

struct AttentionOverlay: View {
    @ObservedObject var model: Model
    let alert: AttentionAlert
    let unit: CGFloat
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var size: CGFloat { unit * model.scale }
    var tint: Color { alert.kind == .failure ? Theme.red : (alert.kind == .timer ? Theme.amber : Theme.accent) }
    var symbol: String { switch alert.kind { case .question: return "bubble.left.and.text.bubble.right.fill"; case .timer: return "timer"; case .failure: return "exclamationmark.triangle.fill"; case .completion: return "checkmark.circle.fill" } }
    var body: some View {
        ZStack {
            Theme.background.opacity(0.97).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16 * unit) {
                HStack(spacing: 12 * unit) {
                    Image(systemName: symbol).font(.system(size: 29 * size)).foregroundColor(tint)
                    Text(alert.kind == .question ? "需要你回答" : (alert.kind == .timer ? "计时结束" : (alert.kind == .failure ? "任务需要检查" : "本轮完成")))
                        .font(.system(size: 30 * size, weight: .semibold))
                    Spacer()
                    if let deadline = alert.expires {
                        Text("\(Int(ceil(max(0, deadline.timeIntervalSince(model.now))))) 秒后返回")
                            .font(.system(size: 18 * size)).monospacedDigit().foregroundColor(Theme.muted)
                    } else { Text("正在处理").font(.system(size: 18 * size)).foregroundColor(Theme.muted) }
                    Button { model.dismissAttention() } label: { Image(systemName: "xmark").font(.system(size: 22 * size)) }
                        .buttonStyle(.plain).padding(7 * unit).accessibilityLabel("关闭提示并返回")
                }
                Text(alert.title).font(.system(size: 27 * size, weight: .medium)).lineLimit(2).foregroundColor(Theme.muted)
                Rectangle().fill(tint.opacity(0.25)).frame(height: 1)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                HStack {
                    Text(model.queuedAlertCount > 0 ? "还有 \(model.queuedAlertCount) 条提示" : "结束提示后返回原页面")
                        .font(.system(size: 18 * size)).foregroundColor(Theme.muted)
                    Spacer()
                    Button(alert.kind == .question ? "暂时返回" : "知道了，返回") { model.dismissAttention() }
                        .font(.system(size: 21 * size, weight: .medium)).buttonStyle(ControlStyle())
                }
            }.padding(26 * unit).background(Theme.surface)
                .cornerRadius(22 * unit)
                .overlay(RoundedRectangle(cornerRadius: 22 * unit).stroke(tint.opacity(0.65), lineWidth: 1.5))
                .padding(22 * unit)
            if alert.kind == .completion && !reduceMotion {
                CompletionRibbons(began: alert.created, running: model.now.timeIntervalSince(alert.created) < 6)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }.foregroundColor(Theme.ink)
    }
    @ViewBuilder var content: some View {
        switch alert.kind {
        case .question:
            if let task = model.cache[alert.targetID], let request = task.interactions?.first(where: { $0.id == alert.requestID }) {
                ScrollView {
                    VStack(spacing: 12 * unit) {
                        ForEach(request.questions) { question in
                            QuestionCard(model: model, task: task, request: request, question: question, unit: unit)
                        }
                    }
                }
            } else { Text("问题已处理").font(.system(size: 35 * size)) }
        case .timer:
            let state = model.widgetState(alert.targetID)
            VStack(spacing: 20 * unit) {
                PulsingTimerIcon(tint: tint, size: 72 * size)
                Text(state.timerPhase == "break" ? "休息结束，开始下一轮" : "专注完成，休息一下")
                    .font(.system(size: 42 * size, weight: .semibold))
                Text("本轮 \(Int(state.timerDuration / 60)) 分钟")
                    .font(.system(size: 24 * size)).foregroundColor(Theme.muted)
                HStack(spacing: 14 * unit) {
                    Button(state.timerPhase == "break" ? "开始 25 分钟专注" : "开始 5 分钟休息") {
                        model.startTimer(alert.targetID, minutes: state.timerPhase == "break" ? 25 : 5, phase: state.timerPhase == "break" ? "focus" : "break")
                        model.dismissAttention()
                    }.buttonStyle(ControlStyle(selected: true))
                    Button("查看计时器") { model.closeAttention(); model.openWidget(alert.targetID) }.buttonStyle(ControlStyle())
                }.font(.system(size: 22 * size, weight: .medium))
            }
        case .completion, .failure:
            VStack(spacing: 18 * unit) {
                Image(systemName: symbol).font(.system(size: 70 * size)).foregroundColor(tint)
                Text(alert.kind == .completion ? "这一轮已完成" : (model.cache[alert.targetID]?.status == "interrupted" ? "任务已中断" : "执行失败"))
                    .font(.system(size: 48 * size, weight: .semibold))
                if let task = model.cache[alert.targetID] {
                    Text("用时 \(task.duration(at: model.now))").font(.system(size: 25 * size, design: .monospaced)).foregroundColor(Theme.muted)
                    Button(task.source == "Codex" ? "打开对话查看结果" : "打开任务记录") {
                        model.closeAttention(); model.open(task)
                    }.font(.system(size: 23 * size)).buttonStyle(ControlStyle(selected: true))
                }
            }
        }
    }
}

struct PulsingTimerIcon: View {
    let tint: Color
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0 : sin(context.date.timeIntervalSince1970 * 2)
            Image(systemName: "timer").font(.system(size: size)).foregroundColor(tint)
                .scaleEffect(1 + 0.035 * phase).shadow(color: tint.opacity(0.20 + 0.08 * phase), radius: 14)
        }
    }
}

struct CompletionRibbons: View {
    let began: Date
    let running: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSince(began)
                guard time >= 0 && time < 6 else { return }
                let colors = [Theme.accent, Theme.amber, Color(red: 0.55, green: 0.68, blue: 0.89), Theme.red, Theme.ink]
                for index in 0..<65 {
                    let delay = Double(index % 13) * 0.05
                    let age = max(0, time - delay)
                    let x = size.width * CGFloat((index * 37) % 101) / 100 + sin(age * 2 + Double(index)) * 25
                    let y = -40 + age * (90 + Double(index % 9) * 9)
                    var piece = context
                    piece.opacity = min(1, max(0, (6 - time) / 1.5))
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(age * 2.5 + Double(index)))
                    piece.fill(Path(CGRect(x: -4, y: -10, width: 8, height: 20)), with: .color(colors[index % colors.count]))
                }
            }
        }
    }
}
