import SwiftUI
import AppKit

struct SpeechSettingsView: View {
    @Binding var settings: TranscriptionSettings
    var live = true
    @ObservedObject private var language = AppSettings.shared
    @State private var models: [URL] = []
    @State private var executable = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("转录引擎"), selection: $settings.engine) {
                ForEach(TranscriptionEngine.allCases) { Text($0.label).tag($0) }
            }.id(language.language)
            Picker(L("识别语言"), selection: $settings.language) {
                if settings.engine == .whisper { Text(L("自动识别")).tag("auto") }
                Text("中文").tag("zh-CN"); Text("English").tag("en-US"); Text("Deutsch").tag("de-DE")
            }.id(language.language)
            Text(L(settings.engine == .whisper ? (live ? "音频留在本机，按语音片段更新文字。" : "使用 Whisper 在本机转录。") : "Apple 模型在本机运行，需要指定语言。"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
            if settings.engine == .whisper {
                DisclosureGroup(L("本地模型")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(settings.resolvedModel.isEmpty ? L("未找到模型") : URL(fileURLWithPath: settings.resolvedModel).lastPathComponent)
                            .font(.system(size: 14)).lineLimit(2).help(settings.resolvedModel)
                        HStack {
                            if !models.isEmpty {
                                Menu(L("已找到的模型")) {
                                    ForEach(models, id: \.path) { url in Button(url.lastPathComponent) { settings.whisperModel = url.path } }
                                }
                            }
                            Button(L("选择模型…")) { choose(model: true) }
                        }
                        Text(executable.isEmpty ? L("未找到 whisper-cli") : executable).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        HStack {
                            Button(L("选择程序…")) { choose(model: false) }
                            Button(L("重新查找")) { Task { await scan() } }
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 14))
            }
        }
        .onChange(of: settings.engine) { _, engine in
            if engine == .apple && settings.language == "auto" { settings.language = "zh-CN" }
            if engine == .whisper { settings.language = "auto" }
        }
        .task { await scan() }
    }
    private func scan() async {
        await ExecutableLocator.refresh()
        models = WhisperModels.discover(); executable = settings.resolvedExecutable
    }
    private func choose(model: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = L(model ? "选择 Whisper 模型" : "选择 whisper-cli")
        if panel.runModal() == .OK, let url = panel.url {
            if model { settings.whisperModel = url.path } else { settings.whisperExecutable = url.path; executable = url.path }
        }
    }
}

struct FileTranscriptionView: View {
    @ObservedObject var model: RecorderModel
    var recording: Recording
    @ObservedObject private var language = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var hasText = false
    @State private var hasQuestions = false
    @State private var loading = true
    @State private var inspectionError: String?
    private var running: Bool { model.phase == .transcribing }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L("转录录音")).font(.system(size: 24, weight: .semibold))
            Text(recording.title).font(.system(size: 18)).lineLimit(2)
            SpeechSettingsView(settings: $model.transcriptionSettings, live: false).disabled(running)
            if hasQuestions {
                Text(L("这份转录已有追问，请打开现有转录。为保留引用关系，暂不替换其原文。"))
                    .foregroundStyle(.secondary)
            } else if hasText {
                Text(L("重新转录前会备份已有文字。取消或失败不会改变原文件。"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            } else {
                Text(L("音频和识别过程都在本机。完成后可选中文字追问。"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            if running {
                ProgressView(value: model.fileProgress)
                Text(L(model.fileCancelling ? "正在取消…" : "正在转录…") + " \(Int(model.fileProgress * 100))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            if let error = model.fileError ?? inspectionError { Text(L(error)).foregroundStyle(.orange).font(.system(size: 14)) }
            HStack {
                Spacer()
                if running {
                    Button(L("取消转录")) { model.cancelFileTranscription() }.disabled(model.fileCancelling)
                } else {
                    Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                    if hasQuestions {
                        Button(L("查看转录")) { model.openTranscript(recording); model.transcriptOpened = UUID(); dismiss() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(L(hasText ? "重新转录" : "开始转录")) { model.transcribeFile(recording) }
                            .buttonStyle(.borderedProminent).disabled(loading || inspectionError != nil).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }.padding(28).frame(width: 560).font(.system(size: 16)).controlSize(.large)
        .interactiveDismissDisabled(running)
        .task {
            let directory = model.folder.appendingPathComponent(recording.folderName), id = recording.id
            let result = await Task.detached { Result { try MeetingStore.load(in: directory, recordingID: id) } }.value
            switch result {
            case .success(let document): hasText = !document.segments.isEmpty; hasQuestions = !document.threads.isEmpty
            case .failure(let error): inspectionError = error.localizedDescription
            }
            loading = false
        }
    }
}
