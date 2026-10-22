import SwiftUI

struct MeetingWorkspaceView: View {
    @ObservedObject var workspace: MeetingWorkspaceModel
    @ObservedObject var recorder: RecorderModel
    private let green = Color(red: 0.10, green: 0.40, blue: 0.33)
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(workspace.meetingTitle).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                    Label(workspace.isFinalizing ? "正在完成末尾转录…" : workspace.speechStatus, systemImage: "waveform")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if recorder.isRecording {
                    Text(durationText(recorder.elapsed)).monospacedDigit().foregroundStyle(green)
                    Button(recorder.phase == .paused ? "继续" : "暂停") { recorder.pauseOrResume() }
                    Button("结束并保存") { Task { await recorder.stop() } }
                }
                Button { workspace.exportMarkdown() } label: { Image(systemName: "square.and.arrow.up") }.help("导出转录与追问 Markdown").disabled(workspace.document == nil)
                Button { workspace.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.help("追问设置")
            }.padding(24)
            if let error = workspace.speechError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider()
            HSplitView {
                transcript.frame(minWidth: 350, maxWidth: .infinity)
                questions.frame(minWidth: 340, idealWidth: 400, maxWidth: 550)
            }
        }.background(Color(red: 0.975, green: 0.979, blue: 0.965))
        .sheet(isPresented: $workspace.showSettings) { QuestionSettingsView(workspace: workspace) }
        .alert("追问提示", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("知道了") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
    }
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("会议转录").font(.headline)
                Spacer()
                Text("本机识别 · \(workspace.confirmed.count) 段已定稿").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            if workspace.document?.segments.isEmpty != false {
                VStack(spacing: 14) {
                    Image(systemName: "text.bubble").font(.system(size: 36, weight: .light)).foregroundStyle(green.opacity(0.5))
                    Text(recorder.isRecording ? "正在聆听会议声音" : "边听，边读，边追问").font(.title3)
                    Text("开始录音并启用本地转录。\n文字出现后，拖动选中任意一句，\n就能在右侧围绕它继续讨论。")
                        .multilineTextAlignment(.center).lineSpacing(5).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptTextView(segments: workspace.document?.segments ?? [], clearToken: workspace.clearSelectionToken,
                                   focus: workspace.focusSegment, onSelection: workspace.updateSelection)
            }
            Divider()
            if let selection = workspace.selection {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("已选 \(selection.text.count) 字 · \(durationText(selection.start))").font(.caption).foregroundStyle(green)
                        Spacer()
                        Button("取消选择") { workspace.selection = nil; workspace.clearSelectionToken = UUID() }.font(.caption)
                    }
                    Picker("加入上下文", selection: $workspace.scope) { ForEach(ContextScope.allCases) { Text($0.label).tag($0) } }
                        .font(.caption)
                    Button { workspace.newThread() } label: { Label("追问选中内容", systemImage: "bubble.left.and.text.bubble.right").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(workspace.generating)
                    Text("选择期间文字显示暂时固定，后台转录继续。") .font(.caption2).foregroundStyle(.secondary)
                }.padding(16)
            } else {
                Label("拖动选择文字，即可创建独立追问。", systemImage: "cursorarrow.rays").font(.caption).foregroundStyle(.secondary).padding(18)
            }
        }.background(.white)
    }
    private var questions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("选段追问").font(.headline)
                Spacer()
                if let threads = workspace.document?.threads, !threads.isEmpty {
                    Menu {
                        ForEach(threads.reversed()) { thread in
                            Button("\(durationText(thread.start)) · \(thread.quote.prefix(22))") { workspace.activeThreadID = thread.id; workspace.question = "" }
                        }
                    } label: { Label("\(threads.count) 条", systemImage: "clock") }.disabled(workspace.generating)
                }
            }.padding(20)
            if let thread = workspace.activeThread {
                threadContent(thread)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "quote.bubble").font(.system(size: 34, weight: .light)).foregroundStyle(green.opacity(0.6))
                    Text("从一句话开始").font(.title3.bold())
                    Text("圈选左侧的会议文字，解释概念、厘清决定，或继续追问。每条讨论始终保留原文引用。")
                        .lineSpacing(5).foregroundStyle(.secondary)
                    Button("配置 API 或本地 Agent") { workspace.showSettings = true }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
    private func threadContent(_ thread: QuestionThread) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("引用 · \(durationText(thread.start))").font(.caption).foregroundStyle(green); Spacer(); Text(thread.scope).font(.caption2).foregroundStyle(.secondary) }
                ScrollView { Text(thread.quote).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                if thread.scope.contains("未定稿") { Text("含识别中的文字，之后可能修正；此讨论保留提问时快照。").font(.caption2).foregroundStyle(.orange) }
                DisclosureGroup("本次可引用的 \(thread.evidence.count) 段材料") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(thread.evidence.enumerated()), id: \.offset) { index, evidence in
                                Button { focus(evidence.id) } label: {
                                    Text("[[\(index + 1)]] \(durationText(evidence.start)) · \(evidence.text)")
                                        .font(.caption).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).foregroundStyle(green)
                            }
                        }
                    }.frame(maxHeight: 150).padding(.top, 8)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(16).background(green.opacity(0.055)).clipShape(RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if thread.turns.isEmpty {
                            Text("想从哪里展开？").font(.caption).foregroundStyle(.secondary)
                            ForEach(["解释这段话的意思", "这里有哪些行动项？", "哪些结论还不确定？"], id: \.self) { suggestion in
                                Button(suggestion) { workspace.question = suggestion }.buttonStyle(.bordered)
                            }
                        }
                        ForEach(thread.turns) { turn in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(turn.question).font(.callout.weight(.medium)).textSelection(.enabled)
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 10))
                                if !turn.answer.isEmpty {
                                    Text(answerText(turn.answer, thread: thread)).font(.callout).lineSpacing(5).textSelection(.enabled)
                                        .environment(\.openURL, OpenURLAction { url in
                                            if url.scheme == "huisheng", let index = Int(url.lastPathComponent), thread.evidence.indices.contains(index) { focus(thread.evidence[index].id) }
                                            return .handled
                                        })
                                }
                                if turn.status == "pending" { HStack { ProgressView().controlSize(.small); Text(workspace.settings.backend == .api ? "正在回答…" : "Agent 正在处理，完成后显示…").font(.caption).foregroundStyle(.secondary) } }
                                if let error = turn.error { Text(error).font(.caption).foregroundStyle(.red) }
                                if ["failed", "cancelled"].contains(turn.status) {
                                    HStack { Text(turn.status == "cancelled" ? "已停止 · 内容未完成" : "回答未完成").font(.caption).foregroundStyle(.secondary)
                                        Button("编辑后重试") { workspace.question = turn.question }.font(.caption).disabled(workspace.generating) }
                                }
                            }.id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: thread.turns.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("发送到：\(workspace.settings.destination)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                TextField("围绕这段话继续追问…", text: $workspace.question, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...5).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .disabled(workspace.generating)
                HStack {
                    Text("上下文已固定 · 新转录不会自动加入").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if workspace.generating { Button("停止") { workspace.stopAnswer() } }
                    else { Button("发送") { workspace.send() }.buttonStyle(.borderedProminent).disabled(workspace.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
            }.padding(16)
        }
    }
    private func focus(_ id: UUID) { workspace.focusSegment = nil; DispatchQueue.main.async { workspace.focusSegment = id } }
    private func answerText(_ answer: String, thread: QuestionThread) -> AttributedString {
        var text = answer
        for index in thread.evidence.indices { text = text.replacingOccurrences(of: "[[\(index + 1)]]", with: "[〔\(index + 1)〕](huisheng://citation/\(index))") }
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer)
    }
}

struct TranscriptionOptionsView: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var workspace: MeetingWorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("本地实时转录", isOn: $model.useTranscription).toggleStyle(.switch).controlSize(.small).disabled(model.busy || !LiveTranscription.supported)
            if model.useTranscription {
                Picker("识别语言", selection: $model.transcriptionLocale) {
                    Text("中文").tag("zh-CN"); Text("English").tag("en-US"); Text("Deutsch").tag("de-DE")
                }.disabled(model.busy)
            }
            Text(LiveTranscription.supported ? "本机识别，首次使用可能下载 Apple 语音组件。" : "本地实时转录需要 macOS 26 和支持的 Apple Silicon Mac。")
                .font(.caption2).foregroundStyle(.secondary)
            if model.phase == .starting { Text(workspace.speechStatus).font(.caption).foregroundStyle(.secondary) }
            if let error = workspace.speechError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}
