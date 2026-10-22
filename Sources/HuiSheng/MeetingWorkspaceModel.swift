import SwiftUI
import AppKit

@MainActor
final class MeetingWorkspaceModel: ObservableObject {
    @Published var document: MeetingDocument?
    @Published var meetingTitle = "实时转录与追问"
    @Published var selection: TranscriptSelection?
    @Published var scope: ContextScope = .selection
    @Published var activeThreadID: UUID?
    @Published var question = ""
    @Published var generating = false
    @Published var error: String?
    @Published var speechStatus = "开始录音后，文字会显示在这里。"
    @Published var speechError: String?
    @Published var settings = QuestionSettings.load()
    @Published var focusSegment: UUID?
    @Published var clearSelectionToken = UUID()
    @Published var showSettings = false
    @Published var isFinalizing = false
    private(set) var directory: URL?
    private var saveTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var requestID: UUID?
    private var generatingTurn: (thread: UUID, turn: UUID)?
    private let questionService: QuestionService

    init(questionService: QuestionService = QuestionService()) { self.questionService = questionService }
    var activeThread: QuestionThread? { document?.threads.first(where: { $0.id == activeThreadID }) }
    var confirmed: [TranscriptSegment] { document?.segments.filter(\.isFinal) ?? [] }
    var provisional: [TranscriptSegment] { document?.segments.filter { !$0.isFinal } ?? [] }

    func clear() {
        stopAnswer(); saveTask?.cancel(); saveTask = nil
        document = nil; directory = nil; selection = nil; activeThreadID = nil
    }
    func begin(recording: Recording, directory: URL) {
        stopAnswer(); flush()
        self.directory = directory; meetingTitle = recording.title
        document = MeetingDocument(recordingID: recording.id)
        selection = nil; activeThreadID = nil; question = ""; speechError = nil; error = nil
        clearSelectionToken = UUID(); scheduleSave()
    }
    func open(recording: Recording, directory: URL, flushCurrent: Bool = true) {
        do {
            if flushCurrent { stopAnswer(); flush() }
            else { saveTask?.cancel(); saveTask = nil }
            let loaded = try MeetingStore.load(in: directory, recordingID: recording.id)
            self.directory = directory; meetingTitle = recording.title; document = loaded
            selection = nil; question = ""; activeThreadID = loaded.threads.last?.id; speechError = nil
            speechStatus = loaded.segments.isEmpty ? "这份录音尚无转录，可在「我的录音」中选择「转为文字」。" : "已打开本地会议记录"
            clearSelectionToken = UUID()
        } catch { self.error = LF("无法打开会议记录：%@", error.localizedDescription) }
    }
    func receive(_ update: TranscriptUpdate, recordingID: UUID) {
        guard document?.recordingID == recordingID else { return }
        document?.apply(update); scheduleSave()
    }
    func updateSelection(_ selection: TranscriptSelection?) {
        if self.selection == nil && selection != nil { scope = .selection }
        self.selection = selection
    }
    func newThread() {
        guard let document, let selection else { return }
        do {
            let thread = try document.makeThread(selection: selection, scope: scope)
            self.document?.threads.append(thread); activeThreadID = thread.id
            question = ""; self.selection = nil; clearSelectionToken = UUID(); scheduleSave()
        } catch { self.error = error.localizedDescription }
    }
    func send() {
        guard !generating, let thread = activeThread else { return }
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let messages = try QuestionPrompt.messages(thread: thread, question: prompt)
            let snapshot = settings
            if snapshot.backend == .api { _ = try snapshot.endpoint("chat/completions") }
            guard snapshot.backend != .api || !snapshot.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showSettings = true; return
            }
            let key = snapshot.backend == .api ? try APIKeyStore.read(for: snapshot.baseURL) : ""
            let turn = ChatTurn(question: prompt)
            guard let index = document?.threads.firstIndex(where: { $0.id == thread.id }) else { return }
            document?.threads[index].turns.append(turn)
            let request = UUID(); requestID = request
            generatingTurn = (thread.id, turn.id); generating = true; question = ""; error = nil; flush()
            answerTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let receive: (String) async -> Void = { [weak self] delta in
                        self?.appendAnswer(delta, request: request, thread: thread.id, turn: turn.id)
                    }
                    if snapshot.backend == .api { try await questionService.answer(settings: snapshot, key: key, messages: messages, onDelta: receive) }
                    else { try await LocalAgentService().answer(settings: snapshot, messages: messages, onDelta: receive) }
                    finishAnswer(request: request, thread: thread.id, turn: turn.id, status: "complete", error: nil)
                } catch {
                    finishAnswer(request: request, thread: thread.id, turn: turn.id,
                        status: Task.isCancelled ? "cancelled" : "failed", error: Task.isCancelled ? nil : error.localizedDescription)
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func appendAnswer(_ delta: String, request: UUID, thread: UUID, turn: UUID) {
        guard requestID == request,
              let i = document?.threads.firstIndex(where: { $0.id == thread }),
              let j = document?.threads[i].turns.firstIndex(where: { $0.id == turn }) else { return }
        document?.threads[i].turns[j].answer += delta
        scheduleSave()
    }
    private func finishAnswer(request: UUID, thread: UUID, turn: UUID, status: String, error: String?) {
        guard requestID == request,
              let i = document?.threads.firstIndex(where: { $0.id == thread }),
              let j = document?.threads[i].turns.firstIndex(where: { $0.id == turn }) else { return }
        document?.threads[i].turns[j].status = status; document?.threads[i].turns[j].error = error
        requestID = nil; generating = false; generatingTurn = nil; answerTask = nil
        flush()
    }
    func stopAnswer() {
        answerTask?.cancel(); requestID = nil; answerTask = nil; generating = false
        if let current = generatingTurn,
           let i = document?.threads.firstIndex(where: { $0.id == current.thread }),
           let j = document?.threads[i].turns.firstIndex(where: { $0.id == current.turn }) {
            document?.threads[i].turns[j].status = "cancelled"
            question = document?.threads[i].turns[j].question ?? ""
        }
        generatingTurn = nil; flush()
    }
    func exportMarkdown() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Recording.safeName(meetingTitle) + (AppLanguage.current == .english ? "-transcript.md" : "-转录与追问.md")
        panel.title = L("导出转录与追问")
        if panel.runModal() == .OK, let url = panel.url {
            do { try document.markdown.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = error.localizedDescription }
        }
    }
    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard let document, let directory else { return }
        do { try MeetingStore.save(document, in: directory) }
        catch { self.error = LF("会议文字保存失败：%@", error.localizedDescription) }
    }
    private func scheduleSave() {
        // At most one pending save; don't postpone an existing save indefinitely under continuous updates.
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            self?.flush()
        }
    }
}
