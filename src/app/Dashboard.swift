import SwiftUI

struct ControlStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(selected ? Theme.background : Theme.ink)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.accent : Theme.elevated.opacity(configuration.isPressed ? 1 : 0.65)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: selected ? 0 : 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct TextWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MarqueeText: View {
    let text: String
    let fontSize: CGFloat
    var weight: Font.Weight = .regular
    var color: Color = Theme.ink
    @State private var textWidth: CGFloat = 0
    @State private var began = Date()
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        GeometryReader { geo in
            let distance = max(0, textWidth - geo.size.width)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: distance < 1 || reduceMotion)) { context in
                let travel = Double(distance / 32)
                let phase = max(0, context.date.timeIntervalSince(began)).truncatingRemainder(dividingBy: max(1, travel + 5))
                let offset: CGFloat = phase <= 2 ? 0 : (phase >= travel + 2 ? -distance : -CGFloat(phase - 2) * 32)
                Text(text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.system(size: fontSize, weight: weight)).foregroundColor(color)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { measure in Color.clear.preference(key: TextWidth.self, value: measure.size.width) })
                    .offset(x: reduceMotion ? 0 : offset)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            }.clipped()
        }
        .frame(height: fontSize * 1.4)
        .onPreferenceChange(TextWidth.self) { textWidth = $0 }
        .onChange(of: text) { _ in began = Date(); textWidth = 0 }
        .accessibilityLabel(text)
    }
}

struct Dashboard: View {
    @ObservedObject var model: Model
    @State private var page = 0
    @State private var manualUntil = Date.distantPast
    @State private var hoverList = false
    var pageCount: Int { max(1, (model.tasks.count + 2) / 3) }
    var currentPage: Int { page % pageCount }
    var visibleTasks: [TaskInfo] { Array(model.tasks.dropFirst(currentPage * 3).prefix(3)) }
    var rotationTick: Int { Int(model.now.timeIntervalSince1970 / 12) }
    var body: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width / 1080, geo.size.height / 540)
            let size = unit * model.scale
            ZStack {
            VStack(spacing: 12 * unit) {
                header(size: size)
                if model.tab == "tasks" {
                    taskStrip(size: size)
                    if let task = model.pinnedTask {
                        FocusPanel(model: model, task: task, unit: unit)
                    } else if !model.tasks.isEmpty {
                        VStack(spacing: 9 * unit) {
                            ForEach(visibleTasks) { task in
                                TaskRow(model: model, task: task, position: (model.orderedIDs.firstIndex(of: task.id) ?? 0) + 1,
                                        unit: unit, compact: visibleTasks.count == 3)
                            }
                        }.frame(maxHeight: .infinity).onHover { hoverList = $0 }
                    } else {
                        VStack(spacing: 15 * unit) {
                            Image(systemName: "rectangle.stack").font(.system(size: 44 * size)).foregroundColor(Theme.accent)
                            Text(model.stale ? "正在连接任务" : "暂时没有运行中的任务").font(.system(size: 33 * size, weight: .semibold))
                            Text("Codex 和脚本开始后会自动出现在这里").font(.system(size: 24 * size)).foregroundColor(Theme.muted)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if model.tab == "interactions" {
                    InteractionWorkspace(model: model, unit: unit)
                } else {
                    WidgetWorkspace(model: model, unit: unit)
                }
                footer(size: size)
            }
            .padding(.horizontal, 28 * unit).padding(.top, 18 * unit).padding(.bottom, 16 * unit)
            .frame(width: geo.size.width, height: geo.size.height)
            .background(LinearGradient(colors: [Theme.surface, Theme.background], startPoint: .topLeading, endPoint: .bottomTrailing))
            .foregroundColor(Theme.ink)
            .allowsHitTesting(model.attentionAlert == nil)
            .disabled(model.attentionAlert != nil)
            .accessibilityHidden(model.attentionAlert != nil)
            if let alert = model.attentionAlert {
                AttentionOverlay(model: model, alert: alert, unit: unit)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
            }
            }.animation(.easeOut(duration: 0.25), value: model.attentionAlert?.id)
        }
        .preferredColorScheme(.dark)
        .onChange(of: rotationTick) { _ in
            if model.attentionAlert == nil, model.tab == "tasks", model.pinnedID == nil, pageCount > 1, model.now > manualUntil, !hoverList {
                withAnimation(.easeInOut(duration: 0.2)) { page = (currentPage + 1) % pageCount }
            }
        }
        .onChange(of: model.orderedIDs) { _ in page = min(currentPage, pageCount - 1) }
    }
    func header(size: CGFloat) -> some View {
        HStack(spacing: 13 * size) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 23 * size, weight: .medium)).foregroundColor(Theme.accent)
            Text(model.tab == "tasks" ? "任务监测" : (model.tab == "interactions" ? "待处理" : "小工具")).font(.system(size: 25 * size, weight: .semibold))
            if model.tab == "tasks" {
                Text("\(model.state?.active_count ?? 0) 运行").font(.system(size: 17 * size)).foregroundColor(Theme.muted)
            }
            Spacer()
            HStack(spacing: 5) {
                Button { model.tab = "tasks" } label: { Label("任务", systemImage: "rectangle.stack") }
                    .buttonStyle(ControlStyle(selected: model.tab == "tasks"))
                Button { model.tab = "interactions" } label: { Label("待处理\(model.questionCount > 0 ? " \(model.questionCount)" : "")", systemImage: "bubble.left.and.text.bubble.right") }
                    .buttonStyle(ControlStyle(selected: model.tab == "interactions"))
                    .accessibilityLabel("待处理页面，\(model.questionCount) 个问题")
                Button { model.tab = "tools" } label: { Label("工具", systemImage: "square.grid.2x2") }
                    .buttonStyle(ControlStyle(selected: model.tab == "tools"))
            }.font(.system(size: 18 * size, weight: .medium))
            Text(model.now, style: .time).font(.system(size: 22 * size, design: .monospaced)).foregroundColor(Theme.muted)
        }
    }
    func taskStrip(size: CGFloat) -> some View {
        HStack(spacing: 9) {
            Button { model.clearPin() } label: { Text("总览").font(.system(size: 18 * size, weight: .medium)) }
                .buttonStyle(ControlStyle(selected: model.pinnedID == nil)).accessibilityLabel("总览，取消固定监测")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(Array(model.tasks.enumerated()), id: \.element.id) { index, task in
                            Button { model.pin(task) } label: {
                                HStack(spacing: 8) {
                                    Text("\(index + 1)").font(.system(size: 17 * size, weight: .semibold, design: .monospaced))
                                    Text(task.title).font(.system(size: 18 * size, weight: .medium)).lineLimit(1).frame(maxWidth: 210 * size)
                                    if model.pinnedID == task.id { Image(systemName: "pin.fill").font(.system(size: 13 * size)) }
                                }
                            }
                            .id(task.id).buttonStyle(ControlStyle(selected: model.pinnedID == task.id))
                            .help("固定监测 5 分钟 · \(task.title)")
                            .accessibilityLabel("固定监测 \(index + 1)：\(task.title)")
                        }
                    }
                }
                .onChange(of: model.pinnedID) { id in if let id = id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
            }
        }
    }
    func footer(size: CGFloat) -> some View {
        HStack(spacing: 12) {
            if let toast = model.toast {
                Text(toast).foregroundColor(Theme.accent).lineLimit(1)
            } else if let error = model.hotkeyError ?? model.state?.error {
                Text(error).foregroundColor(Theme.amber).lineLimit(1)
            } else if model.tab == "tasks", !model.widgetSummaries.isEmpty {
                ToolStatusStrip(model: model, size: size)
            } else {
                Text("⌃⌥⌘ 1–9 跳转 · 加 ⇧ 固定").lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.tab == "tasks", let until = model.pinUntil {
                Text("固定 \(durationText(until.timeIntervalSince(model.now)))").monospacedDigit()
            } else if model.tab == "tasks", pageCount > 1 {
                Button("‹") { page = (currentPage + pageCount - 1) % pageCount; manualUntil = model.now.addingTimeInterval(30) }
                    .accessibilityLabel("上一页任务")
                Text("\(currentPage + 1) / \(pageCount)").monospacedDigit()
                Button("›") { page = (currentPage + 1) % pageCount; manualUntil = model.now.addingTimeInterval(30) }
                    .accessibilityLabel("下一页任务")
            } else { Text("本地更新 · 字号 ±") }
        }.buttonStyle(.plain).font(.system(size: 16 * size)).foregroundColor(Theme.muted)
    }
}

struct TaskRow: View {
    @ObservedObject var model: Model
    let task: TaskInfo
    let position: Int
    let unit: CGFloat
    let compact: Bool
    @State private var hovered = false
    var body: some View {
        let size = unit * model.scale
        VStack(alignment: .leading, spacing: (compact ? 4 : 7) * unit) {
            HStack(spacing: 12 * unit) {
                Text(String(format: "%02d", position)).font(.system(size: 18 * size, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.muted).frame(width: 26 * unit)
                Button { model.open(task) } label: {
                    MarqueeText(text: task.title, fontSize: (compact ? 27 : 32) * size, weight: .semibold)
                }.buttonStyle(.plain).accessibilityLabel("打开对话 \(position)：\(task.title)")
                Button { model.pin(task) } label: { Image(systemName: "pin").font(.system(size: 20 * size)) }
                    .buttonStyle(.plain).foregroundColor(Theme.muted).padding(7 * unit)
                    .accessibilityLabel("固定任务 \(position) 五分钟")
                Button { model.open(task) } label: { Image(systemName: "arrow.up.right").font(.system(size: 21 * size)) }
                    .buttonStyle(.plain).foregroundColor(Theme.muted).padding(7 * unit)
                    .accessibilityLabel("跳转对话 \(position)")
            }
            HStack(spacing: 14 * unit) {
                HStack(spacing: 8 * unit) {
                    Circle().fill(task.color).frame(width: 7 * unit, height: 7 * unit)
                    Text(task.statusLabel).font(.system(size: (compact ? 24 : 30) * size, weight: .semibold))
                }.foregroundColor(task.color)
                Text(task.stage == task.statusLabel ? task.source : "\(task.source) · \(task.stage)")
                    .font(.system(size: (compact ? 19 : 22) * size)).foregroundColor(Theme.muted).lineLimit(1)
                Spacer(minLength: 0)
                Text(task.progress.map { "\(Int($0))%" } ?? task.duration(at: model.now))
                    .font(.system(size: (compact ? 29 : 40) * size, weight: .medium, design: .monospaced)).tracking(-1)
            }
            if let detail = task.detail, !detail.isEmpty {
                MarqueeText(text: detail, fontSize: (compact ? 18 : 21) * size, color: Theme.muted)
            }
        }
        .padding(.horizontal, 17 * unit).padding(.vertical, (compact ? 8 : 12) * unit)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(RoundedRectangle(cornerRadius: 14 * unit).fill(hovered ? Theme.elevated : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14 * unit).stroke(Theme.line, lineWidth: 1))
        .onHover { hovered = $0 }.animation(.easeInOut(duration: 0.18), value: hovered)
    }
}

struct FocusPanel: View {
    @ObservedObject var model: Model
    let task: TaskInfo
    let unit: CGFloat
    var body: some View {
        let size = unit * model.scale
        VStack(alignment: .leading, spacing: 14 * unit) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5 * unit) {
                    Text(task.statusLabel).font(.system(size: 57 * size, weight: .bold)).foregroundColor(task.color)
                    Text("\(task.source) · \(task.stage)").font(.system(size: 23 * size)).foregroundColor(Theme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4 * unit) {
                    Text(task.progress.map { "\(Int($0))%" } ?? task.duration(at: model.now))
                        .font(.system(size: 64 * size, weight: .medium, design: .monospaced)).tracking(-2)
                    Button { model.open(task) } label: { Label(task.source == "Codex" ? "打开对话" : "打开记录", systemImage: "arrow.up.right") }
                        .font(.system(size: 19 * size)).buttonStyle(ControlStyle())
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 13 * unit) {
                    Text(task.title).font(.system(size: 34 * size, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(task.detail?.isEmpty == false ? task.detail! : "等待下一条进展更新")
                        .font(.system(size: 25 * size)).foregroundColor(Theme.muted).lineSpacing(6 * unit)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24 * unit).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16 * unit).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16 * unit).stroke(Theme.accent.opacity(0.28), lineWidth: 1))
    }
}
