import Foundation
import AVFoundation
import Speech

enum FileTranscription {
    static func documentData(in directory: URL) throws -> Data? {
        let file = directory.appendingPathComponent("meeting.json")
        return FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }
    static func commit(_ document: MeetingDocument, in directory: URL, expected: Data?) throws {
        guard try documentData(in: directory) == expected else { throw RecorderError.message("原转录已被修改，本次结果未覆盖。请重新打开录音后重试。") }
        if let expected {
            let old = try JSONDecoder().decode(MeetingDocument.self, from: expected)
            guard old.threads.isEmpty else { throw RecorderError.message("这份转录已有追问，请打开现有转录。为保留引用关系，暂不替换其原文。") }
            if !old.segments.isEmpty {
                try expected.write(to: directory.appendingPathComponent("meeting-backup-" + UUID().uuidString + ".json"), options: .atomic)
            }
        }
        try MeetingStore.save(document, in: directory)
    }
    struct Input { var url: URL; var source: TranscriptSource }
    static func inputs(recording: Recording, directory: URL) throws -> [Input] {
        let raw = directory.appendingPathComponent("原始音轨")
        let sources: [TranscriptSource] = recording.microphone ? [.system, .microphone] : [.system]
        let tracks = sources.map { Input(url: raw.appendingPathComponent($0.rawValue + ".mov"), source: $0) }
        if tracks.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.url.path) }) { return tracks }
        guard let filename = recording.filename, filename == URL(fileURLWithPath: filename).lastPathComponent,
              FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(filename).path) else {
            throw RecorderError.message("未找到可读取的录音，请先恢复导出。")
        }
        return [Input(url: directory.appendingPathComponent(filename), source: .system)]
    }

    /// Only the caller commits the completed result. Cancellation never writes a partial transcript.
    static func transcribe(recording: Recording, directory: URL, settings: TranscriptionSettings,
                           progress: @escaping (Double) -> Void) async throws -> MeetingDocument {
        await ExecutableLocator.refresh()
        let settings = try settings.validated()
        let inputs = try inputs(recording: recording, directory: directory)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("HuiSheng-File-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        var document = MeetingDocument(recordingID: recording.id)
        for (index, input) in inputs.enumerated() {
            let base = Double(index) / Double(inputs.count), weight = 1 / Double(inputs.count)
            let conversion = Task.detached(priority: .utility) {
                try await convert(input, in: temporary) { progress(base + weight * $0 * 0.15) }
            }
            let chunks = try await withTaskCancellationHandler { try await conversion.value } onCancel: { conversion.cancel() }
            for (part, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let report: (Double) -> Void = { value in
                    progress(base + weight * (0.15 + 0.85 * (Double(part) + value) / Double(chunks.count)))
                }
                let updates: [TranscriptUpdate]
                if settings.engine == .whisper {
                    updates = try await WhisperService.transcribe(chunk, settings: settings, progress: report).updates
                } else if #available(macOS 26.0, *) {
                    updates = try await apple(chunk, language: settings.language, progress: report)
                } else { throw RecorderError.message("Apple 本地转录需要 macOS 26 和支持的 Mac。") }
                for update in updates { document.apply(update) }
                try? FileManager.default.removeItem(at: chunk.url)
            }
            progress(base + weight)
        }
        try Task.checkCancellation()
        guard !document.segments.isEmpty else { throw RecorderError.message("没有识别到语音。请检查录音声音或改用指定语言重试。") }
        return document
    }

    static func convert(_ input: Input, in directory: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> [SpeechAudioChunk] {
        let asset = AVURLAsset(url: input.url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw RecorderError.message("录音中没有音轨。") }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.message("无法读取录音。") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let writer = SpeechWAVWriter(directory: directory, source: input.source)
        var chunks: [SpeechAudioChunk] = [], lastReport = -1
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            chunks += try writer.append(sample, live: false)
            let percent = duration > 0 ? min(100, Int(100 * CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)) : 0
            if percent != lastReport { lastReport = percent; progress(Double(percent) / 100) }
        }
        guard reader.status == .completed else { throw reader.error ?? RecorderError.message("无法读取录音。") }
        if let chunk = writer.finish() { chunks.append(chunk) }
        progress(1)
        return chunks
    }

    @available(macOS 26.0, *)
    private static func apple(_ chunk: SpeechAudioChunk, language: String, progress: @escaping (Double) -> Void) async throws -> [TranscriptUpdate] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw RecorderError.message("这台 Mac 不支持所选转录语言。")
        }
        try await AssetInventory.reserve(locale: locale)
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await request.downloadAndInstall() }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .utility, modelRetention: .whileInUse))
        let results = Task { () throws -> [TranscriptUpdate] in
            var updates: [TranscriptUpdate] = []
            for try await result in module.results {
                try Task.checkCancellation()
                updates.append(TranscriptUpdate(source: chunk.source, start: chunk.start + result.range.start.seconds,
                    end: chunk.start + CMTimeRangeGetEnd(result.range).seconds, text: String(result.text.characters), isFinal: true))
                progress(min(1, CMTimeRangeGetEnd(result.range).seconds / max(0.01, chunk.duration)))
            }
            return updates
        }
        do {
            return try await withTaskCancellationHandler {
                let audio = try AVAudioFile(forReading: chunk.url)
                _ = try await analyzer.analyzeSequence(from: audio)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let value = try await results.value
                try Task.checkCancellation()
                return value
            } onCancel: { results.cancel(); Task { await analyzer.cancelAndFinishNow() } }
        } catch {
            results.cancel(); await analyzer.cancelAndFinishNow(); _ = try? await results.value
            throw error
        }
    }
}
