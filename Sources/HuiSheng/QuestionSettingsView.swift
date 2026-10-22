import SwiftUI
import AppKit

struct QuestionSettingsView: View {
    @ObservedObject var workspace: MeetingWorkspaceModel
    @ObservedObject private var language = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft = QuestionSettings()
    @State private var key = ""
    @State private var error: String?
    @State private var hasKey = false
    @State private var discovered: [QuestionBackend: String] = [:]
    @State private var scanning = false
    init(workspace: MeetingWorkspaceModel) {
        self.workspace = workspace
        _draft = State(initialValue: workspace.settings)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L("追问设置")).font(.system(size: 24, weight: .semibold))
            Picker(L("回答方式"), selection: $draft.backend) {
                ForEach(QuestionBackend.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).id(language.language)
            HStack(spacing: 12) {
                Text(L("本机 Agent")).foregroundStyle(.secondary)
                ForEach([QuestionBackend.codex, .claude]) { backend in
                    if discovered[backend] != nil {
                        Button(backend == .codex ? "Codex" : "Claude Code") { draft.backend = backend }
                    }
                }
                if discovered.isEmpty { Text(L(scanning ? "正在查找…" : "未找到已安装的 Agent")).font(.system(size: 14)).foregroundStyle(.secondary) }
                Spacer()
                Button { Task { await discover() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("重新查找")).disabled(scanning)
            }
            if draft.backend == .api {
                HStack {
                    Button("Ollama") { draft.baseURL = "http://127.0.0.1:11434/v1"; draft.model = "" }
                    Button("LM Studio") { draft.baseURL = "http://127.0.0.1:1234/v1"; draft.model = "" }
                    Button("OpenAI") { draft.baseURL = "https://api.openai.com/v1"; draft.model = "" }
                    Button("OpenRouter") { draft.baseURL = "https://openrouter.ai/api/v1"; draft.model = "" }
                }
                field("接口地址") { TextField("https://api.example.com/v1", text: $draft.baseURL) }
                field("模型") { TextField(L("填写已可用的模型名称"), text: $draft.model) }
                field("API 密钥") { SecureField(L(hasKey ? "已保存；留空保留" : "本机服务可留空"), text: $key) }
                HStack {
                    Text(L("密钥保存在 macOS 钥匙串。")).foregroundStyle(.secondary)
                    Spacer()
                    if hasKey { Button(L("删除密钥")) { do { try APIKeyStore.remove(for: draft.baseURL); hasKey = false; key = "" } catch { self.error = error.localizedDescription } } }
                }.font(.system(size: 14))
            } else {
                Text(L(ExecutableLocator.executable(draft.agentPath) ? "已找到本地 Agent" : "请安装 CLI，或在路径设置中选择程序。"))
                    .foregroundStyle(.secondary)
                DisclosureGroup(L("Agent 路径")) {
                    HStack {
                        TextField(L("可执行文件的绝对路径"), text: $draft.agentPath)
                        Button(L("选择…")) {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.title = L("选择 Agent")
                            if panel.runModal() == .OK, let url = panel.url { draft.agentPath = url.path }
                        }
                    }.padding(.top, 8)
                }
                field("模型") { TextField(L("可选，留空使用 CLI 默认模型"), text: $draft.model) }
                Text(L("请先安装并在终端登录 CLI。Agent 完成后显示回答。"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                Text(L("本地 Agent 可能连接云端。离线问答请通过 API 连接本机模型。"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            DisclosureGroup(L("发送哪些内容？")) {
                Text(L("点击发送后，仅提交选中文字、你选择的上下文，以及此讨论中已完成的问答。音频留在本机。"))
                    .font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 10)
            }
            if let error { Text(L(error)).foregroundStyle(.red).font(.system(size: 14)) }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("保存")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 16)).textFieldStyle(.roundedBorder).controlSize(.large).padding(28).frame(width: 650)
        .onAppear { if draft.agentPath.isEmpty && draft.backend != .api { draft.agentPath = draft.backend.defaultPath }; refreshKey() }
        .task { await discover() }
        .onChange(of: draft.backend) { _, value in
            if value != .api { draft.agentPath = value.defaultPath }
            draft.model = ""; error = nil
        }
        .onChange(of: draft.baseURL) { _, _ in key = ""; refreshKey() }
    }
    private func discover() async {
        scanning = true
        await ExecutableLocator.refresh()
        discovered = [:]
        for backend in [QuestionBackend.codex, .claude] {
            if let path = ExecutableLocator.locate(backend.rawValue) { discovered[backend] = path }
        }
        if draft.backend != .api, draft.agentPath.isEmpty { draft.agentPath = discovered[draft.backend] ?? "" }
        scanning = false
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(L(title)).fontWeight(.medium); content() }
    }
    private func refreshKey() { hasKey = (try? APIKeyStore.read(for: draft.baseURL).isEmpty) == false }
    private func save() {
        do {
            draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if draft.backend == .api {
                _ = try draft.endpoint("chat/completions")
                if !key.isEmpty { try APIKeyStore.save(key, for: draft.baseURL) }
            } else if !ExecutableLocator.executable(draft.agentPath) {
                throw RecorderError.message("所选路径不是可执行文件。请先安装对应 CLI。")
            }
            try draft.save(); workspace.settings = draft; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
