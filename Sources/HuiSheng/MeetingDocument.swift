import Foundation

enum TranscriptSource: String, Codable, CaseIterable {
    case system, microphone
    var label: String { self == .system ? "会议声音" : "我的麦克风" }
}

struct TranscriptSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var source: TranscriptSource
    var start: Double
    var end: Double
    var text: String
    var isFinal: Bool
}

struct TranscriptUpdate {
    var source: TranscriptSource
    var start: Double
    var end: Double
    var text: String
    var isFinal: Bool
}

struct TranscriptSelection: Equatable {
    var text: String
    var segments: [TranscriptSegment]
    var selectedEvidence: [ChatEvidence]? = nil
    var start: Double { segments.map(\.start).min() ?? 0 }
    var end: Double { segments.map(\.end).max() ?? start }
}

enum ContextScope: String, CaseIterable, Identifiable {
    case selection, nearby, meeting
    var id: String { rawValue }
    var label: String {
        switch self { case .selection: return "仅选中文字"; case .nearby: return "选段与前后各两段"; case .meeting: return "当前全部转录" }
    }
}

struct ChatEvidence: Codable, Identifiable, Equatable {
    var id: UUID
    var source: TranscriptSource
    var start: Double
    var end: Double
    var text: String
}

struct ChatTurn: Codable, Identifiable, Equatable {
    var id = UUID()
    var question: String
    var answer = ""
    var status = "pending"
    var error: String?
    var date = Date()
}

struct QuestionThread: Codable, Identifiable, Equatable {
    var id = UUID()
    var quote: String
    var start: Double
    var end: Double
    var evidence: [ChatEvidence]
    var scope: String
    var date = Date()
    var turns: [ChatTurn] = []
}

struct MeetingDocument: Codable {
    var version = 1
    var recordingID: UUID
    var segments: [TranscriptSegment] = []
    var threads: [QuestionThread] = []

    mutating func apply(_ update: TranscriptUpdate) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, update.start.isFinite, update.end.isFinite, update.end >= update.start else { return }
        // Speech emits revisions over ranges. Preserve an ID when finalizing the same range.
        let overlapping = segments.indices.filter { i in
            let s = segments[i]
            return s.source == update.source && (abs(s.start - update.start) < 0.04 || (s.start < update.end && s.end > update.start))
        }
        // A late provisional result must never replace committed text.
        if !update.isFinal && overlapping.contains(where: { segments[$0].isFinal }) { return }
        let identity = overlapping.first.map { segments[$0].id } ?? UUID()
        segments = segments.enumerated().filter { !overlapping.contains($0.offset) }.map(\.element)
        segments.append(TranscriptSegment(id: identity, source: update.source, start: max(0, update.start), end: update.end, text: text, isFinal: update.isFinal))
        segments.sort { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }
    }

    func makeThread(selection: TranscriptSelection, scope: ContextScope) throws -> QuestionThread {
        let quote = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, !selection.segments.isEmpty else { throw RecorderError.message("请先在转录中选中文字。") }
        let evidence: [ChatEvidence]
        if scope == .selection {
            // Only the selected characters leave the app, not the rest of their containing paragraphs.
            evidence = selection.selectedEvidence ?? [ChatEvidence(id: selection.segments[0].id, source: selection.segments[0].source,
                start: selection.start, end: selection.end, text: quote)]
        } else {
            let finalized = segments
            let indices = finalized.indices.filter { i in selection.segments.contains(where: { $0.id == finalized[i].id }) }
            guard let first = indices.min(), let last = indices.max() else { throw RecorderError.message("选段已变更，请重新选择。") }
            let chosen = scope == .meeting ? finalized : Array(finalized[max(0, first - 2)...min(finalized.count - 1, last + 2)])
            evidence = chosen.map { ChatEvidence(id: $0.id, source: $0.source, start: $0.start, end: $0.end, text: $0.text) }
        }
        guard evidence.reduce(0, { $0 + $1.text.count }) <= 40_000 else { throw RecorderError.message("所选上下文超过 40,000 字符，请缩小选段或选择「仅选中文字」。") }
        let provisionalIDs = Set(segments.filter { !$0.isFinal }.map(\.id))
        let hasProvisional = selection.segments.contains { !$0.isFinal } || evidence.contains { provisionalIDs.contains($0.id) }
        return QuestionThread(quote: quote, start: selection.start, end: selection.end, evidence: evidence,
            scope: scope.label + (hasProvisional ? " · 含未定稿" : ""))
    }

    var plainTranscript: String {
        segments.map { "[\(durationText($0.start))] \($0.source.label)\($0.isFinal ? "" : "（未定稿）")\n\($0.text)" }.joined(separator: "\n\n")
    }

    var markdown: String {
        var value = "# 会议转录\n\n" + plainTranscript + "\n\n# 选段追问\n"
        for thread in threads {
            value += "\n## \(durationText(thread.start)) · \(thread.scope)\n\n> " + thread.quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n"
            for turn in thread.turns {
                value += "\n**问：** \(turn.question)\n\n**答：** \(turn.answer)\n"
                if turn.status != "complete" { value += "\n（\(turn.status == "cancelled" ? "已停止" : "未完成")）\n" }
            }
            value += "\n引用来源：\n"
            for (index, evidence) in thread.evidence.enumerated() {
                value += "\n- [[\(index + 1)]] \(durationText(evidence.start)) \(evidence.source.label)：\(evidence.text)\n"
            }
        }
        return value
    }
}

enum MeetingStore {
    static func save(_ document: MeetingDocument, in folder: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
    }
    static func load(in folder: URL, recordingID: UUID) throws -> MeetingDocument {
        let url = folder.appendingPathComponent("meeting.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return MeetingDocument(recordingID: recordingID) }
        var document = try JSONDecoder().decode(MeetingDocument.self, from: Data(contentsOf: url))
        guard document.recordingID == recordingID, document.version == 1 else { throw RecorderError.message("会议文档版本或录音标识不匹配。") }
        for i in document.threads.indices {
            for j in document.threads[i].turns.indices where document.threads[i].turns[j].status == "pending" {
                document.threads[i].turns[j].status = "cancelled"
            }
        }
        return document
    }
}
