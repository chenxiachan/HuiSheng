import Foundation

enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case whisper, apple
    var id: String { rawValue }
    var label: String { self == .whisper ? "Whisper" : L("Apple 本地模型") }
}
struct TranscriptionSettings: Codable, Equatable {
    var engine: TranscriptionEngine = .apple
    var language = "zh-CN"
    var whisperExecutable = ""
    var whisperModel = ""
    var resolvedExecutable: String { whisperExecutable.isEmpty ? ExecutableLocator.locate("whisper-cli") ?? "" : whisperExecutable }
    var resolvedModel: String { whisperModel.isEmpty ? WhisperModels.discover().first?.path ?? "" : whisperModel }
    var whisperLanguage: String { language == "auto" ? "auto" : String(language.prefix(2)) }
    static func load() -> Self {
        if let data = UserDefaults.standard.data(forKey: "transcriptionSettings"), let saved = try? JSONDecoder().decode(Self.self, from: data) { return saved }
        var result = Self()
        if ExecutableLocator.locate("whisper-cli") != nil, !WhisperModels.discover().isEmpty { result.engine = .whisper; result.language = "auto" }
        return result
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "transcriptionSettings") } }
    func validated() throws -> Self {
        var result = self
        if engine == .whisper {
            result.whisperExecutable = resolvedExecutable; result.whisperModel = resolvedModel
            guard ExecutableLocator.executable(result.whisperExecutable) else { throw RecorderError.message("未找到 whisper-cli，请安装 whisper.cpp 或选择可执行文件。") }
            guard FileManager.default.isReadableFile(atPath: result.whisperModel), result.whisperModel.hasSuffix(".bin") else { throw RecorderError.message("未找到 Whisper 模型，请选择 whisper.cpp 的 ggml 多语言模型文件。") }
            if language != "en-US" && URL(fileURLWithPath: result.whisperModel).lastPathComponent.contains(".en.") {
                throw RecorderError.message("此模型仅支持英语；自动识别语言需要多语言模型。")
            }
        } else {
            guard LiveTranscription.supported else { throw RecorderError.message("Apple 本地转录需要 macOS 26 和支持的 Mac。") }
            guard language != "auto" else { throw RecorderError.message("自动识别语言请选择 Whisper；Apple 模型需要指定语言。") }
        }
        return result
    }
}
enum WhisperModels {
    static func discover(home: String = NSHomeDirectory()) -> [URL] {
        let roots = ["/opt/homebrew/share/whisper-cpp/models", "/usr/local/share/whisper-cpp/models",
                     home + "/Documents/whisper.cpp/models", home + "/whisper.cpp/models", home + "/.cache/whisper",
                     home + "/.local/share/whisper", home + "/Library/Application Support/VoiceInput/models",
                     home + "/Library/Application Support/HuiSheng/models"]
        var seen = Set<String>()
        var files: [URL] = []
        for root in roots {
            let candidates = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            for file in candidates {
                let name = file.lastPathComponent
                guard name.hasPrefix("ggml-"), file.pathExtension == "bin", !name.contains(".en."), !name.contains("silero"),
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      seen.insert(file.resolvingSymlinksInPath().path).inserted else { continue }
                files.append(file)
            }
        }
        return files.sorted {
            func rank(_ url: URL) -> Int {
                let name = url.lastPathComponent
                if name.contains("large-v3-turbo") { return 0 }
                if name.contains("small") { return 1 }
                if name.contains("base") { return 2 }
                return 3
            }
            return rank($0) == rank($1) ? $0.lastPathComponent < $1.lastPathComponent : rank($0) < rank($1)
        }
    }
}
