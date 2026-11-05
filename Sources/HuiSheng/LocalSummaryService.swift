import Foundation
import FoundationModels
import NaturalLanguage

enum SummaryOutput { case notes, summary }
enum SummaryModelError: Error { case contextLimit }

enum AppleSummaryModel {
    static var unavailableReason: String? {
        guard #available(macOS 26.0, *) else { return "自动命名与总结需要 macOS 26 的 Apple 本地模型。" }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "请先在系统设置中开启 Apple Intelligence，再重新生成总结。"
        case .unavailable(.modelNotReady): return "Apple 本地模型尚未就绪，请等待系统完成模型准备后重试。"
        case .unavailable: return "这台 Mac 暂不支持 Apple 本地大语言模型。"
        }
    }
    static func generate(instructions: String, text: String, output: SummaryOutput) async throws -> String {
        try Task.checkCancellation()
        if let reason = unavailableReason { throw RecorderError.message(reason) }
        guard #available(macOS 26.0, *) else { throw RecorderError.message("自动命名与总结需要 macOS 26 的 Apple 本地模型。") }
        let session = LanguageModelSession(model: .default, tools: [], instructions: instructions)
        do {
            if output == .notes {
                return try await session.respond(to: "Extract concise factual notes from this section. Keep discussion, confirmed decisions, actions with explicit owners/deadlines, and unresolved questions. Retain timestamps when provided. Under 180 words or 300 Chinese characters. Do not add facts.\n\n<meeting_data>\n\(text)\n</meeting_data>",
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 650)).content
            }
            let string = DynamicGenerationSchema(type: String.self)
            let list = DynamicGenerationSchema(arrayOf: string, minimumElements: 0, maximumElements: 6)
            let languageRule = instructions.contains("Output in English") ? " Write every item as an English sentence; preserve only personal names in their original script." : " 全部使用简体中文，保留人名及明确的截止时间。"
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "MeetingSummary", properties: [
                .init(name: "title", description: ("Specific meeting topic, at most 10 Chinese characters or 8 English words. No date unless essential."), schema: string),
                .init(name: "overview", description: ("One or two sentences stating the main topic and outcome, grounded in the supplied data."), schema: string),
                .init(name: "topics", description: ("Key discussion points. Short sentences." + languageRule), schema: list),
                .init(name: "decisions", description: ("Only explicitly agreed decisions, not proposals. Empty if none stated." + languageRule), schema: list),
                .init(name: "actions", description: ("Explicit next actions. Each item must include the task, its owner AND its stated deadline. Do not omit stated dates. Do not invent a missing deadline. Empty if none stated." + languageRule), schema: list),
                .init(name: "questions", description: ("Explicitly unresolved questions or proposals. Empty if none stated." + languageRule), schema: list)
            ]), dependencies: [])
            let task = "Create a meeting title and summary from this transcript or factual section notes. Do not turn a suggestion into a decision."
            return try await session.respond(to: task + "\n\n<meeting_data>\n\(text)\n</meeting_data>",
                schema: schema, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 1500)).content.jsonString
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw SummaryModelError.contextLimit
        }
    }
}

struct LocalSummaryService {
    typealias Generator = (_ instructions: String, _ text: String, _ output: SummaryOutput) async throws -> String
    var generate: Generator = { try await AppleSummaryModel.generate(instructions: $0, text: $1, output: $2) }
    var unavailableReason: () -> String? = { AppleSummaryModel.unavailableReason }

    func summarize(_ document: MeetingDocument, language: String, incomplete: Bool,
                   progress: @escaping (String, Double) -> Void = { _, _ in }) async throws -> MeetingSummary {
        if let reason = unavailableReason() { throw RecorderError.message(reason) }
        guard document.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw RecorderError.message("没有可用于总结的转录，请先转录录音。")
        }
        let sourceLanguage = NLLanguageRecognizer.dominantLanguage(for: document.segments.map(\.text).joined(separator: "\n"))
        let outputLanguage: String
        switch sourceLanguage {
        case .simplifiedChinese, .traditionalChinese: outputLanguage = "zh-Hans"
        case .english: outputLanguage = "en"
        default: outputLanguage = language
        }
        // Token density varies across languages. Retry with smaller, lossless chunks if needed.
        for limit in [SummaryPrompt.byteLimit, 2500, 1250] {
            do { return try await summarize(document, language: outputLanguage, incomplete: incomplete, limit: limit, progress: progress) }
            catch SummaryModelError.contextLimit { try Task.checkCancellation() }
        }
        throw RecorderError.message("本地模型未能处理此转录。录音和转录已保留，请稍后重试。")
    }
    private func summarize(_ document: MeetingDocument, language: String, incomplete: Bool, limit: Int,
                           progress: @escaping (String, Double) -> Void) async throws -> MeetingSummary {
        let source = SummaryPrompt.source(document)
        let instructions = SummaryPrompt.instructions(english: language == "en")
        var parts = SummaryPrompt.chunks(source, limit: limit)
        let originalChunks = parts.count
        // Bound every request, including the reduction pass. Never silently drop the end of a meeting.
        var pass = 0
        while parts.count > 1 {
            guard pass < 8 else { throw RecorderError.message("会议过长，未能完成汇总。录音和转录已保留。") }
            var notes: [String] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                progress(LF("正在整理第 %d / %d 段…", index + 1, parts.count), min(0.85, 0.15 + Double(index) / Double(parts.count) * 0.65))
                let note = try await generate(instructions, part, .notes)
                try Task.checkCancellation()
                guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.utf8.count < 20_000 else {
                    throw RecorderError.message("模型没有生成有效的标题和总结，请重试。")
                }
                notes.append(note)
            }
            parts = SummaryPrompt.chunks(notes.joined(separator: "\n\n"), limit: limit); pass += 1
        }
        try Task.checkCancellation()
        progress("正在生成标题与会议总结…", 0.9)
        let response = try await generate(instructions, parts[0], .summary)
        try Task.checkCancellation()
        let content: MeetingSummaryContent
        do { content = try JSONDecoder().decode(MeetingSummaryContent.self, from: Data(response.utf8)).validated() }
        catch { throw RecorderError.message("模型没有生成有效的标题和总结，请重试。") }
        return MeetingSummary(recordingID: document.recordingID, content: content, language: language,
            transcriptFingerprint: SummaryPrompt.fingerprint(document), transcriptIncomplete: incomplete || document.segments.contains { !$0.isFinal },
            sourceSegments: document.segments.count, chunks: originalChunks)
    }
}
