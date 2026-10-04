import Cocoa
import SwiftUI

struct WidgetWorkspace: View {
    @ObservedObject var model: Model
    let unit: CGFloat
    var body: some View {
        let size = unit * model.scale
        HStack(alignment: .top, spacing: 16 * unit) {
            ScrollView {
                VStack(spacing: 8 * unit) {
                    ForEach(model.widgets) { widget in
                        Button { model.selectWidget(widget.id) } label: {
                            HStack(spacing: 10 * unit) {
                                Image(systemName: widget.symbol).frame(width: 23 * size)
                                Text(widget.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }.font(.system(size: 22 * size, weight: .medium))
                                .frame(width: 188 * unit).padding(.vertical, 10 * unit)
                        }.buttonStyle(ControlStyle(selected: model.selectedWidget?.id == widget.id))
                    }
                }
            }.frame(width: 226 * unit)
            if let widget = model.selectedWidget {
                VStack(alignment: .leading, spacing: 13 * unit) {
                    Text(widget.title).font(.system(size: 29 * size, weight: .semibold))
                    Text(widget.subtitle ?? "").font(.system(size: 19 * size)).foregroundColor(Theme.muted)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    WidgetContent(model: model, widget: widget, unit: unit).id(widget.id)
                    if let error = model.storageError ?? model.registryEditError ?? model.toolError { Text(error).font(.system(size: 17 * size)).foregroundColor(Theme.amber) }
                }.padding(22 * unit).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 16 * unit).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 16 * unit).stroke(Theme.line, lineWidth: 1))
            } else {
                Text(model.toolError ?? "还没有小工具。可以用 small-screen-tools skill 添加。")
                    .font(.system(size: 25 * size)).foregroundColor(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxHeight: .infinity)
    }
}

struct WidgetContent: View {
    @ObservedObject var model: Model
    let widget: WidgetDefinition
    let unit: CGFloat
    @State private var customMinutes = "25"
    @State private var newItem = ""
    var size: CGFloat { unit * model.scale }
    var state: WidgetState { model.widgetState(widget.id) }
    var remaining: Double { max(0, state.timerEnd.map { $0 - model.now.timeIntervalSince1970 } ?? state.timerRemaining) }
    var body: some View {
        switch widget.kind {
        case "timer": timer
        case "note": note
        case "checklist": checklist
        case "clock": clocks
        case "links": links
        case "readout": readout
        default: Text("这个工具类型暂不支持").foregroundColor(Theme.amber)
        }
    }
    var timer: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 11 * unit) {
            HStack(spacing: 10 * unit) {
                ForEach(widget.presets ?? [5,25,50], id: \.self) { minutes in
                    Button("\(minutes) 分钟") { model.startTimer(widget.id, minutes: minutes) }
                        .font(.system(size: 20 * size)).buttonStyle(ControlStyle())
                }
            }
            HStack(spacing: 10 * unit) {
                TextField("分钟", text: $customMinutes).textFieldStyle(.roundedBorder)
                    .frame(width: 80 * unit).accessibilityLabel("自定义计时分钟数")
                Text("分钟").foregroundColor(Theme.muted)
                Button("开始专注") { if let minutes = Int(customMinutes) { model.startTimer(widget.id, minutes: minutes) } }
                    .buttonStyle(ControlStyle(selected: true)).disabled(!(1...1440).contains(Int(customMinutes) ?? 0))
                Button("休息 5 分钟") { model.startTimer(widget.id, minutes: 5, phase: "break") }.buttonStyle(ControlStyle())
            }.font(.system(size: 20 * size))
            HStack(alignment: .firstTextBaseline, spacing: 15 * unit) {
                Text(countdownText(remaining)).font(.system(size: 68 * size, weight: .medium, design: .monospaced)).tracking(-3)
                Text(state.timerFinished ? "已完成" : (state.timerEnd == nil ? (state.timerRemaining < state.timerDuration ? "已暂停" : "待开始") : (state.timerPhase == "break" ? "休息中" : "专注中")))
                    .font(.system(size: 23 * size, weight: .medium)).foregroundColor(Theme.accent)
            }
            ProgressView(value: min(1, max(0, 1 - remaining / max(1, state.timerDuration)))).tint(Theme.accent)
            HStack(spacing: 12 * unit) {
                Button(state.timerEnd == nil ? "开始 / 继续" : "暂停") { model.toggleTimer(widget.id) }
                    .buttonStyle(ControlStyle(selected: true))
                Button("重置") { model.resetTimer(widget.id) }.buttonStyle(ControlStyle())
            }.font(.system(size: 22 * size, weight: .medium))
        }.padding(.bottom, 3 * unit)
        }.onAppear { customMinutes = String(max(1, Int(state.timerDuration / 60))) }
    }
    var note: some View {
        VStack(alignment: .leading, spacing: 8 * unit) {
            StatusTextEditor(text: Binding(get: { state.note }, set: { value in model.changeWidget(widget.id) { $0.note = value } }), fontSize: 25 * size, label: "\(widget.title)内容")
                .padding(10 * unit).background(Theme.background.opacity(0.55)).cornerRadius(10 * unit)
                .accessibilityLabel("\(widget.title)内容")
            Text(model.storageError == nil ? "自动保存在本机 · ⌘V 粘贴 · ⌘Z 撤销" : "保存失败，请检查提示")
                .font(.system(size: 17 * size)).foregroundColor(Theme.muted)
        }.frame(maxHeight: .infinity)
    }
    var checklist: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15 * unit) {
                ForEach(widget.items ?? []) { item in
                    let checked = state.checked.contains(item.id)
                    HStack(spacing: 10 * unit) {
                    Button {
                        model.changeWidget(widget.id) { value in
                            if checked { value.checked.removeAll { $0 == item.id } } else { value.checked.append(item.id) }
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 14 * unit) {
                            Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundColor(checked ? Theme.accent : Theme.muted)
                            Text(item.text).strikethrough(checked).foregroundColor(checked ? Theme.muted : Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 24 * size)).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityLabel("\(checked ? "取消勾选" : "勾选")：\(item.text)")
                    Button { model.removeChecklistItem(widget.id, itemID: item.id) } label: {
                        Image(systemName: "minus.circle").font(.system(size: 20 * size)).foregroundColor(Theme.muted)
                    }.buttonStyle(.plain).accessibilityLabel("移除检查项：\(item.text)")
                    }
                }
                HStack {
                Button("重置勾选") { model.changeWidget(widget.id) { $0.checked = [] } }
                    .font(.system(size: 18 * size)).buttonStyle(ControlStyle()).padding(.top, 5 * unit)
                Button("撤销清单修改") { model.undoChecklistEdit() }.font(.system(size: 18 * size)).buttonStyle(ControlStyle())
                }
                HStack(spacing: 10 * unit) {
                    TextField("添加自己的检查项", text: $newItem).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("新检查项")
                    Button("添加") { if model.addChecklistItem(widget.id, text: newItem) { newItem = "" } }
                        .buttonStyle(ControlStyle(selected: true)).disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.font(.system(size: 20 * size))
            }
        }
    }
    var clocks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22 * unit) {
                ForEach(Array((widget.zones ?? []).enumerated()), id: \.offset) { _, zone in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 7 * unit) {
                            Text(zone.title).font(.system(size: 25 * size, weight: .medium)).foregroundColor(Theme.accent)
                            Text(formattedDate(zone.timezone)).font(.system(size: 18 * size)).foregroundColor(Theme.muted)
                        }
                        Spacer()
                        Text(formattedTime(zone.timezone)).font(.system(size: 48 * size, weight: .medium, design: .monospaced))
                    }
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
    }
    func formattedTime(_ zone: String) -> String {
        let formatter = DateFormatter(); formatter.timeZone = resolvedTimeZone(zone); formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: model.now)
    }
    func formattedDate(_ zone: String) -> String {
        let formatter = DateFormatter(); formatter.timeZone = resolvedTimeZone(zone); formatter.dateFormat = "MM-dd · EEE"
        formatter.locale = Locale(identifier: "zh_CN"); return formatter.string(from: model.now)
    }
    func resolvedTimeZone(_ zone: String) -> TimeZone? {
        zone == "local" ? .autoupdatingCurrent : TimeZone(identifier: zone)
    }
    var links: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12 * unit) {
                ForEach(Array((widget.links ?? []).enumerated()), id: \.offset) { _, link in
                    Button { if let url = URL(string: link.url), ["https","http","codex","file"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) } } label: {
                        Label(link.title, systemImage: "arrow.up.right").font(.system(size: 25 * size))
                    }.buttonStyle(ControlStyle())
                }
            }
        }
    }
    var readout: some View {
        let value = model.readouts[widget.id]
        return VStack(alignment: .leading, spacing: 16 * unit) {
            Text(value?.label ?? "等待本地读数").font(.system(size: 24 * size)).foregroundColor(Theme.muted)
            Text(value?.value ?? "—").font(.system(size: 75 * size, weight: .medium, design: .monospaced))
            ScrollView { Text(value?.detail ?? "请让脚本按扩展协议写入已注册的 JSON 文件。").font(.system(size: 24 * size)).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ToolStatusStrip: View {
    @ObservedObject var model: Model
    let size: CGFloat
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8 * size) {
                ForEach(model.widgetSummaries) { summary in
                    Button { model.openWidget(summary.id) } label: {
                        HStack(spacing: 8 * size) {
                            Image(systemName: summary.symbol).font(.system(size: 17 * size))
                            Text(summary.title).font(.system(size: 15 * size)).foregroundColor(Theme.muted)
                            Text(summary.value).font(.system(size: 18 * size, weight: .medium)).monospacedDigit()
                        }.foregroundColor(summary.attention ? Theme.amber : Theme.ink)
                            .padding(.horizontal, 10 * size).padding(.vertical, 5 * size)
                            .background(RoundedRectangle(cornerRadius: 8 * size).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 8 * size).stroke(summary.attention ? Theme.amber.opacity(0.6) : Theme.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                        .help("\(summary.title) · \(summary.value) · 点击打开工具")
                        .accessibilityLabel("工具状态：\(summary.title)，\(summary.value)，点击打开")
                }
            }.fixedSize(horizontal: true, vertical: false)
        }.frame(height: 36 * size)
    }
}
