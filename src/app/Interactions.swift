import SwiftUI

struct InteractionWorkspace: View {
    @ObservedObject var model: Model
    let unit: CGFloat
    @State private var composing = false
    @State private var targetID: String?
    var body: some View {
        let size = unit * model.scale
        VStack(alignment: .leading, spacing: 12 * unit) {
            HStack {
                Button("待处理 \(model.questionCount)") { composing = false }
                    .buttonStyle(ControlStyle(selected: !composing))
                    .accessibilityLabel("查看待处理问题")
                Button("提问 / 追加指令") { composing = true }
                    .buttonStyle(ControlStyle(selected: composing))
                Spacer()
                Text(composing ? "复制后在对话中粘贴并提交" : "小屏提问可直接提交").foregroundColor(Theme.muted)
            }.font(.system(size: 18 * size))
            if composing {
                composer(size: size)
            } else if model.attentionTasks.isEmpty {
                VStack(spacing: 14 * unit) {
                    Image(systemName: "checkmark.bubble").font(.system(size: 45 * size)).foregroundColor(Theme.accent)
                    Text("暂时没有待回答的问题").font(.system(size: 30 * size, weight: .semibold))
                    Text("任务发出提问后，会在这里显示问题和选项")
                        .font(.system(size: 22 * size)).foregroundColor(Theme.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20 * unit) {
                        ForEach(model.attentionTasks) { task in
                            HStack {
                                Text(task.title).font(.system(size: 27 * size, weight: .semibold))
                                Spacer()
                                Button("打开对话") { model.open(task) }.buttonStyle(ControlStyle())
                            }
                            ForEach(task.interactions ?? []) { request in
                                ForEach(request.questions) { question in
                                    QuestionCard(model: model, task: task, request: request, question: question, unit: unit)
                                }
                            }
                        }
                    }.padding(.bottom, 4 * unit)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    func composer(size: CGFloat) -> some View {
        let candidates = model.tasks.filter { $0.threadURL != nil }
        let target = candidates.first { $0.id == targetID } ?? candidates.first { $0.id == model.pinnedID } ?? candidates.first
        return VStack(alignment: .leading, spacing: 12 * unit) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9 * unit) {
                    ForEach(candidates) { task in
                        Button { targetID = task.id } label: {
                            Text("\((model.orderedIDs.firstIndex(of: task.id) ?? 0) + 1)  \(task.title)")
                                .lineLimit(1).frame(maxWidth: 250 * unit)
                        }.buttonStyle(ControlStyle(selected: task.id == target?.id))
                            .accessibilityLabel("指令目标：\(task.title)")
                    }
                }
            }.font(.system(size: 20 * size))
            if let target = target {
                let instruction = model.instructionDrafts[target.id] ?? ""
                Text("发给：\(target.title)").font(.system(size: 23 * size, weight: .semibold))
                StatusTextEditor(text: Binding(get: { model.instructionDrafts[target.id] ?? "" }, set: { model.editInstruction(target.id, $0) }), fontSize: 25 * size, label: "新问题或追加指令").padding(10 * unit)
                    .background(Theme.background).cornerRadius(12 * unit)
                    .accessibilityLabel("新问题或追加指令")
                HStack {
                    Text("运行中任务可在原对话选择立即调整或排队")
                        .font(.system(size: 17 * size)).foregroundColor(Theme.muted)
                    Spacer()
                    Button("复制指令并打开对话") { model.prepareReply(target, text: instruction) }
                        .font(.system(size: 20 * size, weight: .medium)).buttonStyle(ControlStyle(selected: true))
                        .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text("暂无可选择的 Codex 任务").font(.system(size: 28 * size)).frame(maxHeight: .infinity)
            }
        }.padding(20 * unit).background(Theme.surface).cornerRadius(14 * unit)
            .overlay(RoundedRectangle(cornerRadius: 14 * unit).stroke(Theme.line, lineWidth: 1))
    }
}

struct QuestionCard: View {
    @ObservedObject var model: Model
    let task: TaskInfo
    let request: TaskInteraction
    let question: InteractionQuestion
    let unit: CGFloat
    var body: some View {
        let size = unit * model.scale
        let key = model.draftKey(task, request, question)
        let draft = model.replyDrafts[key] ?? ""
        VStack(alignment: .leading, spacing: 12 * unit) {
            Text(request.kind == "approval" ? "权限确认" : question.title)
                .font(.system(size: 18 * size, weight: .semibold)).foregroundColor(Theme.amber)
            Text(question.text).font(.system(size: 27 * size, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(request.kind == "small_screen" ? (request.questions.count == 1 ? "点选选项直接提交；也可以输入自定义回答" : "完成全部问题后，一次提交回答") : "内置提问：选择后需复制到原对话提交")
                .font(.system(size: 17 * size)).foregroundColor(Theme.muted)
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    model.editReply(key, option.label)
                    if request.kind == "small_screen", request.questions.count == 1 { model.submitDirectAnswer(task, request) }
                } label: {
                    HStack(alignment: .top, spacing: 12 * unit) {
                        Text("\(index + 1)").font(.system(size: 22 * size, design: .monospaced))
                        VStack(alignment: .leading, spacing: 4 * unit) {
                            Text(option.label).font(.system(size: 23 * size, weight: .medium))
                            if !option.description.isEmpty { Text(option.description).font(.system(size: 19 * size)).opacity(0.8) }
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(ControlStyle(selected: draft == option.label))
                    .disabled(model.directSubmitted.contains(request.id))
            }
            if request.kind == "approval" {
                Button("回对话查看权限并决定") { model.open(task) }
                    .font(.system(size: 21 * size)).buttonStyle(ControlStyle(selected: true))
            } else {
                StatusTextEditor(text: Binding(get: { model.replyDrafts[key] ?? "" }, set: { model.editReply(key, $0) }), fontSize: 23 * size, label: "回复：\(question.text)")
                    .padding(8 * unit).frame(height: 100 * unit).background(Theme.background).cornerRadius(10 * unit)
                    .accessibilityLabel("回复：\(question.text)")
                if request.kind == "small_screen" {
                    if question.id == request.questions.last?.id {
                        Button(model.directSubmitted.contains(request.id) ? "已提交，等待任务接收" : (request.questions.count > 1 ? "提交全部回答" : "提交回答")) {
                            model.submitDirectAnswer(task, request)
                        }.font(.system(size: 21 * size)).buttonStyle(ControlStyle(selected: true))
                            .disabled(!model.readyToSubmit(task, request))
                        if let error = model.directReplyError { Text(error).font(.system(size: 17 * size)).foregroundColor(Theme.red) }
                    }
                } else {
                    Button("复制回复并打开对话") { model.prepareReply(task, text: draft) }
                        .font(.system(size: 21 * size)).buttonStyle(ControlStyle(selected: true))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.padding(20 * unit).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface).cornerRadius(14 * unit)
            .overlay(RoundedRectangle(cornerRadius: 14 * unit).stroke(Theme.amber.opacity(0.3), lineWidth: 1))
    }
}
