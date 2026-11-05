import Foundation

/// Opt-in integration check using synthetic speech and the actual on-device models.
@main struct SummaryCheck {
    @MainActor static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            let directory = root.appendingPathComponent("recordings/synthetic")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let audio = directory.appendingPathComponent("speech.aiff")
            let input = root.appendingPathComponent("speech.aiff")
            if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
            try FileManager.default.copyItem(at: input, to: audio)
            let originalAudio = try Data(contentsOf: audio)
            await ExecutableLocator.refresh()
            let model = RecorderModel(recordingFolder: directory.deletingLastPathComponent())
            model.transcriptionSettings = try TranscriptionSettings(engine: .whisper, language: "auto",
                whisperExecutable: ProcessInfo.processInfo.environment["WHISPER_CLI"] ?? "",
                whisperModel: ProcessInfo.processInfo.environment["WHISPER_MODEL"] ?? "").validated()
            let record = Recording(title: "未命名会议", source: "Synthetic audio", microphone: false,
                status: "ready", filename: "speech.aiff", folderName: "synthetic", titleOrigin: "placeholder")
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("session.json"))
            // Start with an empty transcript, exactly as a recording with live transcription disabled.
            try MeetingStore.save(MeetingDocument(recordingID: record.id), in: directory)
            model.workspace.open(recording: record, directory: directory)
            model.enqueueSummary(record, directory: directory, incomplete: false)
            var status = ""
            for _ in 0..<1200 where model.hasSummaryWork {
                if let next = model.summaryJobs[record.id]?.status, next != status { print(next); status = next }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard !model.hasSummaryWork else { model.cancelAllSummaries(); throw RecorderError.message("FAIL: integration timed out") }
            if let error = model.summaryJobs[record.id]?.error { throw RecorderError.message(error) }
            let doc = try MeetingStore.load(in: directory, recordingID: record.id)
            guard let result = try MeetingSummaryStore.load(in: directory, recordingID: record.id), result.isCurrent(for: doc),
                !result.content.title.isEmpty, !result.content.decisions.isEmpty, !result.content.actions.isEmpty,
                !result.content.questions.isEmpty else { throw RecorderError.message("FAIL: missing summary fields") }
            let saved = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
            guard result.content.actions.joined().contains("星期五") || result.content.actions.joined().contains("周五") else {
                print(result.markdown); throw RecorderError.message("FAIL: explicit action deadline was omitted")
            }
            guard saved.title == result.content.title, saved.filename == record.filename,
                  try Data(contentsOf: audio) == originalAudio else { throw RecorderError.message("FAIL: title or audio persistence") }
            print("TRANSCRIPT:\n" + doc.plainTranscript)
            print("SUMMARY:\n" + result.markdown)
            print("PASS: actual Whisper auto-language → Apple local LLM → automatic title and summary, original audio unchanged")
            var englishDocument = MeetingDocument(recordingID: UUID())
            englishDocument.apply(.init(source: .system, start: 0, end: 30, text: "We agreed to release the Mac version first and postpone the mobile version. Alice will finish recording tests by Friday. Bob will prepare the user manual; no deadline was set for Bob. The budget is undecided and will be discussed next week. Video recording was suggested but not approved.", isFinal: true))
            let english = try await LocalSummaryService().summarize(englishDocument, language: "zh-Hans", incomplete: false)
            guard english.content.actions.joined().contains("Friday"), english.content.actions.joined().contains("Alice"), english.language == "en" else {
                print(english.markdown); throw RecorderError.message("FAIL: English actions must retain the deadline and original owner name")
            }
            try JSONEncoder().encode(english).write(to: root.appendingPathComponent("english-summary.json"))
            print("ENGLISH:\n" + english.markdown)
            print("PASS: English summary generation")
            model.workspace.clear()
        } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
}
