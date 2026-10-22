import SwiftUI
import AppKit

struct QuestionSettingsView: View {
    @ObservedObject var workspace: MeetingWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = QuestionSettings()
    @State private var key = ""
    @State private var error: String?
    @State private var hasKey = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("追问设置").font(.title2.bold()); Spacer(); Button("取消") { dismiss() } }
            Picker("回答方式", selection: $draft.backend) {
                ForEach(QuestionBackend.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            if draft.backend == .api {
                HStack {
                    Text("快速填写").foregroundStyle(.secondary)
                    Button("Ollama") { draft.baseURL = "http://127.0.0.1:11434/v1"; draft.model = "" }
                    Button("LM Studio") { draft.baseURL = "http://127.0.0.1:1234/v1"; draft.model = "" }
                    Button("OpenAI") { draft.baseURL = "https://api.openai.com/v1"; draft.model = "" }
                    Button("OpenRouter") { draft.baseURL = "https://openrouter.ai/api/v1"; draft.model = "" }
                }.font(.caption)
                TextField("接口地址（包含 /v1 等路径）", text: $draft.baseURL).textFieldStyle(.roundedBorder)
                TextField("模型名称，例如本机已下载的模型", text: $draft.model).textFieldStyle(.roundedBorder)
                SecureField(hasKey ? "已保存密钥；留空保留，填写则替换" : "API 密钥（本机服务可留空）", text: $key).textFieldStyle(.roundedBorder)
                HStack {
                    Text("密钥仅保存在 macOS 钥匙串。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if hasKey { Button("删除此接口密钥") { do { try APIKeyStore.remove(for: draft.baseURL); hasKey = false; key = "" } catch { self.error = error.localizedDescription } }.font(.caption) }
                }
                Text("兼容 Chat Completions 流式接口。本机模型需先启动 Ollama / LM Studio，并填写已安装的模型。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("Agent 可执行文件的绝对路径", text: $draft.agentPath).textFieldStyle(.roundedBorder)
                    Button("选择…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { draft.agentPath = url.path }
                    }
                }
                TextField("模型名称（可选，留空使用 CLI 默认模型）", text: $draft.model).textFieldStyle(.roundedBorder)
                Text("请先安装并在终端登录 CLI。每次在独立临时目录执行，输入经标准输入传递；回答完成后显示，可随时停止。CLI 需支持当前的临时会话和工具限制参数。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("本地 Agent 不等于离线模型：它仍可能连接自己的云端服务。若需要全离线问答，选择 API 并连接本机模型。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Label("音频与语音识别始终留在本机。", systemImage: "waveform").font(.callout)
            Text("点击发送后，会声才交给所选接口或 Agent：你圈选的文字、明确选择的上下文范围，以及该追问中已完成的问答。其他录音不会加入。")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button("保存设置") { save() }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 620)
        .onAppear { draft = workspace.settings; if draft.agentPath.isEmpty && draft.backend != .api { draft.agentPath = draft.backend.defaultPath }; refreshKey() }
        .onChange(of: draft.backend) { _, value in
            if value != .api { draft.agentPath = value.defaultPath }
            draft.model = ""; error = nil
        }
        .onChange(of: draft.baseURL) { _, _ in key = ""; refreshKey() }
    }
    private func refreshKey() { hasKey = (try? APIKeyStore.read(for: draft.baseURL).isEmpty) == false }
    private func save() {
        do {
            draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if draft.backend == .api {
                _ = try draft.endpoint("chat/completions")
                if !key.isEmpty { try APIKeyStore.save(key, for: draft.baseURL) }
            } else if !FileManager.default.isExecutableFile(atPath: draft.agentPath) {
                throw RecorderError.message("所选路径不是可执行文件。请先安装对应 CLI。")
            }
            try draft.save(); workspace.settings = draft; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
