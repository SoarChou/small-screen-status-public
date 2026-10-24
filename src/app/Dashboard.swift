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

private func sourceColor(_ source: String) -> Color {
    switch source {
    case "DSH": return Color(red: 0.55, green: 0.72, blue: 0.85)
    case "脚本": return Color(red: 0.74, green: 0.67, blue: 0.83)
    default: return Theme.accent
    }
}

private struct TaskSlot: Identifiable {
    let position: Int
    let task: TaskInfo
    var id: String { task.id }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedSource: String?
    @State private var page = 0
    @State private var manualUntil = Date.distantPast
    @State private var hoverList = false
    @State private var lastTurn = Date.distantPast
    private let sourceOrder = ["Codex", "DSH", "脚本"]
    var sources: [String] { sourceOrder.filter { source in model.tasks.contains { $0.source == source } } }
    private var slots: [TaskSlot] {
        model.tasks.enumerated().compactMap { index, task in
            selectedSource == nil || task.source == selectedSource ? TaskSlot(position: index + 1, task: task) : nil
        }
    }
    var pageCount: Int { max(1, (slots.count + 2) / 3) }
    var currentPage: Int { min(page, pageCount - 1) }
    private var visibleSlots: [TaskSlot] { Array(slots.dropFirst(currentPage * 3).prefix(3)) }
    private func manualChoice() { manualUntil = model.now.addingTimeInterval(60); lastTurn = model.now }
    private func stepRotation() {
        guard model.tab == "tasks", model.pinnedID == nil, model.attentionAlert == nil,
              !hoverList, !reduceMotion, model.now >= manualUntil else { return }
        if lastTurn == .distantPast { lastTurn = model.now; return }
        guard model.now.timeIntervalSince(lastTurn) >= 9 else { return }
        lastTurn = model.now
        let nextPage = (currentPage + 1) % pageCount
        withAnimation(.easeInOut(duration: 0.26)) {
            if selectedSource != nil, currentPage + 1 < pageCount { page += 1; return }
            page = 0
            if sources.count > 1 {
                if let source = selectedSource, let index = sources.firstIndex(of: source) {
                    selectedSource = sources[(index + 1) % sources.count]
                } else { selectedSource = sources[0] }
            } else if pageCount > 1 { page = nextPage }
        }
    }
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
                            ForEach(visibleSlots) { slot in
                                TaskRow(model: model, task: slot.task, position: slot.position,
                                        unit: unit, compact: visibleSlots.count == 3)
                            }
                        }.frame(maxHeight: .infinity).onHover { hoverList = $0 }
                    } else {
                        VStack(spacing: 15 * unit) {
                            Image(systemName: "rectangle.stack").font(.system(size: 44 * size)).foregroundColor(Theme.accent)
                            Text(model.stale ? "正在连接任务" : "暂时没有运行中的任务").font(.system(size: 33 * size, weight: .semibold))
                            Text("选中的来源有任务时会自动出现在这里").font(.system(size: 24 * size)).foregroundColor(Theme.muted)
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
            .background {
                ZStack {
                    Theme.background
                    LinearGradient(colors: [Theme.accent.opacity(0.045), .clear], startPoint: .topLeading, endPoint: .center)
                    Canvas { context, area in
                        var grid = Path()
                        stride(from: CGFloat(0), through: area.height, by: 44 * unit).forEach { y in
                            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: area.width, y: y))
                        }
                        context.stroke(grid, with: .color(Theme.ink.opacity(0.035)), lineWidth: 0.5)
                    }.accessibilityHidden(true)
                }
            }
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
        .onAppear { lastTurn = model.now }
        .onChange(of: model.now) { _ in stepRotation() }
        .onChange(of: model.orderedIDs) { _ in page = min(currentPage, pageCount - 1) }
        .onChange(of: sources) { next in
            if next.count <= 1 || selectedSource.map({ !next.contains($0) }) == true {
                selectedSource = nil; page = 0
            }
        }
    }
    func header(size: CGFloat) -> some View {
        HStack(spacing: 13 * size) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 23 * size, weight: .medium)).foregroundColor(Theme.accent)
            Text(model.tab == "tasks" ? "任务监测" : (model.tab == "interactions" ? "待处理" : "小工具")).font(.system(size: 25 * size, weight: .semibold))
            if model.tab == "tasks" {
                HStack(spacing: 6 * size) {
                    Circle().fill(Theme.accent).frame(width: 6 * size, height: 6 * size)
                    Text("\(model.activeCount) LIVE").tracking(1.1 * size)
                }.font(.system(size: 14 * size, weight: .medium, design: .monospaced)).foregroundColor(Theme.muted)
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
            Menu {
                ForEach(sourceOrder, id: \.self) { source in
                    Button { model.toggleSource(source) } label: {
                        Label(source, systemImage: model.sourceEnabled(source) ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                Label("来源", systemImage: "line.3.horizontal.decrease")
                    .font(.system(size: 17 * size, weight: .medium))
                    .foregroundColor(Theme.muted)
                    .padding(.horizontal, 10 * size).padding(.vertical, 8 * size)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.elevated.opacity(0.55)))
            }.menuStyle(.borderlessButton).fixedSize()
            Text(model.now, style: .time).font(.system(size: 22 * size, design: .monospaced)).foregroundColor(Theme.muted)
        }
    }
    func taskStrip(size: CGFloat) -> some View {
        HStack(spacing: 9) {
            Button {
                selectedSource = nil; page = 0; manualChoice(); model.clearPin()
            } label: { Text("总览").font(.system(size: 18 * size, weight: .medium)) }
                .buttonStyle(ControlStyle(selected: model.pinnedID == nil && selectedSource == nil))
                .accessibilityLabel("总览，取消固定监测与分组")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        if sources.count > 1 {
                            ForEach(sources, id: \.self) { source in
                                let count = model.tasks.filter { $0.source == source }.count
                                Button {
                                    selectedSource = selectedSource == source ? nil : source
                                    page = 0; manualChoice(); model.clearPin()
                                } label: {
                                    HStack(spacing: 6 * size) {
                                        Circle().fill(sourceColor(source)).frame(width: 7 * size, height: 7 * size)
                                        Text(source)
                                        Text("\(count)").font(.system(size: 15 * size, design: .monospaced))
                                    }
                                    .font(.system(size: 17 * size, weight: selectedSource == source ? .semibold : .medium))
                                    .foregroundColor(selectedSource == source ? sourceColor(source) : Theme.muted)
                                    .padding(.horizontal, 11 * size).padding(.vertical, 8 * size)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(sourceColor(source).opacity(selectedSource == source ? 0.15 : 0.06)))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(sourceColor(source).opacity(selectedSource == source ? 0.38 : 0.13), lineWidth: 1))
                                }.buttonStyle(.plain).accessibilityLabel("\(source)，\(count) 个任务")
                            }
                            Rectangle().fill(Theme.line).frame(width: 1, height: 20 * size)
                        }
                        ForEach(slots) { slot in
                            Button { model.pin(slot.task); manualChoice() } label: {
                                HStack(spacing: 8) {
                                    Text("\(slot.position)").font(.system(size: 17 * size, weight: .semibold, design: .monospaced))
                                    Text(slot.task.title).font(.system(size: 18 * size, weight: .medium)).lineLimit(1).frame(maxWidth: 210 * size)
                                    if model.pinnedID == slot.id { Image(systemName: "pin.fill").font(.system(size: 13 * size)) }
                                }
                            }
                            .id(slot.id).buttonStyle(ControlStyle(selected: model.pinnedID == slot.id))
                            .help("固定监测 5 分钟 · \(slot.task.title)")
                            .accessibilityLabel("固定监测 \(slot.position)：\(slot.task.title)")
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
                if pageCount <= 8 {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Button { page = index; manualChoice() } label: {
                            Capsule().fill(index == currentPage ? Theme.accent : Theme.muted.opacity(0.45))
                                .frame(width: index == currentPage ? 17 * size : 6 * size, height: 6 * size)
                        }.accessibilityLabel("第 \(index + 1) 页，共 \(pageCount) 页")
                    }
                } else {
                    Button("‹") { page = (currentPage + pageCount - 1) % pageCount; manualChoice() }
                        .accessibilityLabel("上一页任务")
                    Text("\(currentPage + 1) / \(pageCount)").monospacedDigit()
                    Button("›") { page = (currentPage + 1) % pageCount; manualChoice() }
                        .accessibilityLabel("下一页任务")
                }
            } else if model.tab == "tasks", let source = selectedSource {
                Text("\(source) · 点击总览查看全部").lineLimit(1)
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
                Text(task.source).font(.system(size: (compact ? 18 : 20) * size, weight: .medium))
                    .foregroundColor(sourceColor(task.source)).lineLimit(1)
                if task.stage != task.statusLabel {
                    Text("/  \(task.stage)").font(.system(size: (compact ? 19 : 22) * size))
                        .foregroundColor(Theme.muted).lineLimit(1)
                }
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
                    Button { model.open(task) } label: { Label(task.source == "脚本" ? "打开记录" : "打开对话", systemImage: "arrow.up.right") }
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
