import SwiftUI

struct MeetingWorkspaceView: View {
    @ObservedObject var workspace: MeetingWorkspaceModel
    @ObservedObject var recorder: RecorderModel
    @ObservedObject private var language = AppSettings.shared
    @State private var quoteHeight: CGFloat = 24
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(workspace.document == nil ? L("转录与追问") : workspace.meetingTitle)
                        .font(.system(size: 24, weight: .semibold)).lineLimit(1)
                    Text(L(workspace.isFinalizing ? "正在完成末尾转录…" : workspace.speechStatus))
                        .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if recorder.isRecording {
                    Text(durationText(recorder.elapsed)).monospacedDigit()
                    Button { recorder.pauseOrResume() } label: { Image(systemName: recorder.phase == .paused ? "play.fill" : "pause.fill") }
                        .help(L(recorder.phase == .paused ? "继续录音" : "暂停录音"))
                    Button(L("结束并保存")) { Task { await recorder.stop() } }
                }
                Button { workspace.exportMarkdown() } label: { Image(systemName: "square.and.arrow.up") }
                    .help(L("导出转录与追问")).disabled(workspace.document == nil)
                Button { workspace.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.help(L("追问设置"))
            }.padding(24)
            if let error = workspace.speechError {
                Label(L(error), systemImage: "exclamationmark.triangle").font(.system(size: 14)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider()
            HSplitView {
                transcript.frame(minWidth: 340, maxWidth: .infinity)
                questions.frame(minWidth: 350, idealWidth: 420, maxWidth: 600)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $workspace.showSettings) { QuestionSettingsView(workspace: workspace) }
        .alert(L("追问提示"), isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button(L("好")) { workspace.error = nil }
        } message: { Text(L(workspace.error ?? "")) }
    }
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("转录")).font(.system(size: 19, weight: .semibold))
                Spacer()
                Text(LF("%d 段已定稿", workspace.confirmed.count)).font(.system(size: 14)).foregroundStyle(.secondary)
            }.padding(22)
            if workspace.document?.segments.isEmpty != false {
                VStack(spacing: 12) {
                    Text(L(recorder.isRecording ? "正在聆听会议声音" : "暂无转录")).font(.system(size: 20, weight: .medium))
                    Text(L("开启实时转录后开始录音。"))
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptTextView(segments: workspace.document?.segments ?? [], clearToken: workspace.clearSelectionToken,
                                   focus: workspace.focusSegment, language: language.language, onSelection: workspace.updateSelection)
            }
            Divider()
            if let selection = workspace.selection {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(LF("已选 %d 字 · %@", selection.text.count, durationText(selection.start)))
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("取消选择")) { workspace.selection = nil; workspace.clearSelectionToken = UUID() }
                            .font(.system(size: 14))
                    }
                    Picker(L("上下文"), selection: $workspace.scope) {
                        ForEach(ContextScope.allCases) { Text(L($0.label)).tag($0) }
                    }.id(language.language)
                    Button { workspace.newThread() } label: { Text(L("追问选中内容")).frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(workspace.generating)
                    Text(L("选择时暂停滚动，转录继续。")) .font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(20)
            } else {
                Text(L("选中文字，在右侧追问。"))
                    .font(.system(size: 14)).foregroundStyle(.secondary).padding(22)
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private var questions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("追问")).font(.system(size: 19, weight: .semibold))
                Spacer()
                if let threads = workspace.document?.threads, !threads.isEmpty {
                    Menu {
                        ForEach(threads.reversed()) { thread in
                            Button("\(durationText(thread.start)) · \(thread.quote.prefix(22))") { workspace.activeThreadID = thread.id; workspace.question = "" }
                        }
                    } label: { Label("\(threads.count)", systemImage: "clock") }
                        .help(L("追问历史")).disabled(workspace.generating)
                }
            }.padding(22)
            if let thread = workspace.activeThread { threadContent(thread) }
            else {
                VStack(spacing: 18) {
                    Text(L("选择一段转录开始追问。"))
                        .font(.system(size: 17)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(L("追问设置")) { workspace.showSettings = true }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func threadContent(_ thread: QuestionThread) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Button(durationText(thread.start)) { if let first = thread.evidence.first { focus(first.id) } }
                        .buttonStyle(.link).help(L("回到原文"))
                    Spacer()
                    Text(localizedScope(thread.scope)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }.font(.system(size: 14))
                ScrollView {
                    Text(thread.quote).font(.system(size: 17)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { quoteHeight = $0 }
                }.frame(height: min(110, max(24, quoteHeight)))
                if thread.scope.contains("未定稿") {
                    Text(L("包含识别初稿；引用保留提问时的文字。")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                DisclosureGroup(LF("引用材料（%d）", thread.evidence.count)) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(thread.evidence.enumerated()), id: \.offset) { index, evidence in
                                Button { focus(evidence.id) } label: {
                                    Text("[[\(index + 1)]] \(durationText(evidence.start)) · \(evidence.text)")
                                        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.link)
                            }
                        }
                    }.frame(maxHeight: 150).padding(.top, 10)
                }.font(.system(size: 14)).foregroundStyle(.secondary)
            }.padding(18).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 20)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if thread.turns.isEmpty {
                            ForEach(["解释这段话的意思", "这里有哪些行动项？", "哪些结论还不确定？"], id: \.self) { suggestion in
                                Button(L(suggestion)) { workspace.question = L(suggestion) }.buttonStyle(.link).font(.system(size: 16))
                            }
                        }
                        ForEach(thread.turns) { turn in
                            VStack(alignment: .leading, spacing: 16) {
                                Text(turn.question).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                                if !turn.answer.isEmpty {
                                    Text(answerText(turn.answer, thread: thread)).font(.system(size: 18)).lineSpacing(5).textSelection(.enabled)
                                        .environment(\.openURL, OpenURLAction { url in
                                            if url.scheme == "huisheng", let index = Int(url.lastPathComponent), thread.evidence.indices.contains(index) { focus(thread.evidence[index].id) }
                                            return .handled
                                        })
                                }
                                if turn.status == "pending" {
                                    HStack { ProgressView().controlSize(.small); Text(L(workspace.settings.backend == .api ? "正在回答…" : "Agent 正在处理…")) }
                                        .font(.system(size: 14)).foregroundStyle(.secondary)
                                }
                                if let error = turn.error { Text(L(error)).font(.system(size: 14)).foregroundStyle(.red) }
                                if ["failed", "cancelled"].contains(turn.status) {
                                    HStack {
                                        Text(L(turn.status == "cancelled" ? "已停止 · 内容未完成" : "回答未完成")).foregroundStyle(.secondary)
                                        Button(L("编辑后重试")) { workspace.question = turn.question }.disabled(workspace.generating)
                                    }.font(.system(size: 14))
                                }
                            }.id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: thread.turns.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField(L("继续追问…"), text: $workspace.question, axis: .vertical)
                    .font(.system(size: 17)).textFieldStyle(.plain).lineLimit(2...5).padding(14)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).disabled(workspace.generating)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workspace.settings.destination).lineLimit(1)
                        Text(L("仅发送此讨论的上下文")).lineLimit(2)
                    }.font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if workspace.generating { Button(L("停止")) { workspace.stopAnswer() } }
                    else {
                        Button(L("发送")) { workspace.send() }.buttonStyle(.borderedProminent)
                            .disabled(workspace.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.padding(20)
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
    @ObservedObject private var language = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(L("实时转录"), isOn: $model.useTranscription).toggleStyle(.switch).disabled(model.busy)
            if model.useTranscription {
                SpeechSettingsView(settings: $model.transcriptionSettings).disabled(model.busy)
            } else {
                Text(L("只录音，结束后可在录音列表中转录。")).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            if model.phase == .starting { Text(L(workspace.speechStatus)).font(.system(size: 14)).foregroundStyle(.secondary) }
            if let error = workspace.speechError { Text(L(error)).font(.system(size: 14)).foregroundStyle(.orange) }
        }
    }
}
