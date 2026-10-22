import Foundation
import AVFoundation
import CoreMedia

struct SpeechAudioChunk {
    var url: URL
    var source: TranscriptSource
    var start: Double
    var duration: Double
}

/// Serial access only. Normalize to mono 16 kHz and write bounded live chunks,
/// or one complete WAV for a saved recording. No resampling runs on the capture queue.
final class SpeechWAVWriter {
    private let directory: URL
    private let source: TranscriptSource
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var url: URL?
    private var start: Double = 0
    private var frames: Int64 = 0
    private var previousEnd: Double?
    private var peak: Float = 0
    private var silence: Double = 0
    init(directory: URL, source: TranscriptSource) { self.directory = directory; self.source = source }
    func append(_ sample: CMSampleBuffer, live: Bool) throws -> [SpeechAudioChunk] {
        var chunks: [SpeechAudioChunk] = []
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard time.isFinite else { throw RecorderError.message("音频时间戳无效。") }
        if let previousEnd, time - previousEnd > 0.1 {
            if let chunk = finish() { chunks.append(chunk) }; converter?.reset()
        }
        let input = try pcmBuffer(from: sample)
        previousEnd = time + Double(input.frameLength) / input.format.sampleRate
        let output: AVAudioPCMBuffer
        if input.format == format { output = input }
        else {
            if converter?.inputFormat != input.format { converter = AVAudioConverter(from: input.format, to: format) }
            guard let converter, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 64) else {
                throw RecorderError.message("无法转换本地转录音频。")
            }
            var supplied = false, error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            guard status != .error else { throw error ?? RecorderError.message("转录重采样失败。") }
            output = buffer
        }
        guard output.frameLength > 0 else { return chunks }
        if file == nil {
            start = time; frames = 0; peak = 0; silence = 0
            let destination = directory.appendingPathComponent(UUID().uuidString + ".wav"); url = destination
            file = try AVAudioFile(forWriting: destination, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        var currentPeak: Float = 0
        if let data = output.floatChannelData?[0] { for i in 0..<Int(output.frameLength) { currentPeak = max(currentPeak, abs(data[i])) } }
        peak = max(peak, currentPeak)
        silence = currentPeak < 0.003 ? silence + Double(output.frameLength) / 16000 : 0
        try file?.write(from: output); frames += Int64(output.frameLength)
        let duration = Double(frames) / 16000
        // Prefer a pause in speech; cap chunks so the live view remains responsive.
        if live && (duration >= 20 || (duration >= 8 && silence >= 0.5)) {
            if let chunk = finish() { chunks.append(chunk) }
        }
        return chunks
    }
    func finish() -> SpeechAudioChunk? {
        file = nil
        guard let url else { return nil }
        self.url = nil
        guard frames > 0, peak > 0.0001 else { try? FileManager.default.removeItem(at: url); return nil }
        return SpeechAudioChunk(url: url, source: source, start: start, duration: Double(frames) / 16000)
    }
}

struct WhisperResult {
    var updates: [TranscriptUpdate]
    var language: String
    static func decode(_ data: Data, chunk: SpeechAudioChunk) throws -> Self {
        struct Output: Decodable {
            struct Result: Decodable { var language: String }
            struct Segment: Decodable {
                struct Offsets: Decodable { var from: Double; var to: Double }
                var offsets: Offsets; var text: String
            }
            var result: Result; var transcription: [Segment]
        }
        let output = try JSONDecoder().decode(Output.self, from: data)
        let updates = output.transcription.compactMap { segment -> TranscriptUpdate? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = max(0, segment.offsets.from / 1000), end = min(chunk.duration, segment.offsets.to / 1000)
            guard !text.isEmpty, start.isFinite, end.isFinite, end > start else { return nil }
            return TranscriptUpdate(source: chunk.source, start: chunk.start + start, end: chunk.start + end, text: text, isFinal: true)
        }
        return Self(updates: updates, language: output.result.language)
    }
}

final class WhisperProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
    func receive(_ data: Data) {
        let values: [Double] = lock.withLock {
            pending += String(decoding: data, as: UTF8.self)
            let lines = pending.components(separatedBy: "\n"); pending = String((lines.last ?? "").suffix(1024))
            return lines.dropLast().compactMap { line in
                guard let range = line.range(of: "progress ="), let percent = line[range.upperBound...].split(separator: "%").first,
                      let value = Double(percent.trimmingCharacters(in: .whitespaces)), (0...100).contains(value) else { return nil }
                return value / 100
            }
        }
        values.forEach(report)
    }
}

enum WhisperService {
    static func transcribe(_ chunk: SpeechAudioChunk, settings: TranscriptionSettings, progress: @escaping (Double) -> Void = { _ in }) async throws -> WhisperResult {
        try Task.checkCancellation()
        let prefix = chunk.url.deletingPathExtension(), output = prefix.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: output) }
        let command = LocalCommandInvocation(executable: URL(fileURLWithPath: settings.whisperExecutable),
            arguments: ["-m", settings.whisperModel, "-l", settings.whisperLanguage, "-oj", "-pp", "-of", prefix.path, "-f", chunk.url.path],
            input: Data(), output: output, failureMessage: "Whisper 转录失败，请检查程序与模型是否兼容。")
        let process = LocalCommandProcess(), parser = WhisperProgress(progress)
        let limit = max(300, chunk.duration * 4), started = Date()
        let timeout = Task { do { try await Task.sleep(for: .seconds(limit)); process.cancel() } catch {} }
        defer { timeout.cancel() }
        do {
            let text = try await withTaskCancellationHandler {
                try await process.run(command, directory: chunk.url.deletingLastPathComponent(), diagnostics: parser.receive)
            } onCancel: { process.cancel() }
            try Task.checkCancellation()
            return try WhisperResult.decode(Data(text.utf8), chunk: chunk)
        } catch {
            if !Task.isCancelled && Date().timeIntervalSince(started) >= limit - 1 { throw RecorderError.message("Whisper 转录超时，请选择较小的模型后重试。") }
            throw error
        }
    }
}

/// Independent from the capture queue. Live WAVs queue up to a bounded limit;
/// if recognition cannot keep up, recording continues for a later transcription.
final class WhisperLiveTranscription: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.huisheng.whisper.audio", qos: .utility)
    private let lock = NSLock()
    private var accepting = true
    private var pendingSamples = 0
    private var writers: [TranscriptSource: SpeechWAVWriter] = [:]
    private var chunks: [SpeechAudioChunk] = []
    private var worker: Task<Void, Never>?
    private var failed = false
    private var cancelled = false
    private let settings: TranscriptionSettings
    private let directory: URL
    private let onUpdate: (TranscriptUpdate) -> Void
    private let onFailure: (String) -> Void
    init(settings: TranscriptionSettings, onUpdate: @escaping (TranscriptUpdate) -> Void, onFailure: @escaping (String) -> Void) throws {
        self.settings = settings; self.onUpdate = onUpdate; self.onFailure = onFailure
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HuiSheng-Live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func append(_ sample: CMSampleBuffer, source: TranscriptSource) {
        let accepted = lock.withLock { () -> Bool in
            guard accepting else { return false }
            guard pendingSamples < 200 else { return false }
            pendingSamples += 1; return true
        }
        guard accepted else {
            if lock.withLock({ accepting }) { fail("转录处理不及，已停止转录；录音继续，可在结束后重新转录。") }
            return
        }
        queue.async { [self] in
            defer { lock.withLock { pendingSamples -= 1 } }
            do {
                if writers[source] == nil { writers[source] = SpeechWAVWriter(directory: directory, source: source) }
                for chunk in try writers[source]!.append(sample, live: true) { enqueue(chunk) }
            } catch { fail(error.localizedDescription) }
        }
    }
    private func fail(_ text: String) {
        let notify = lock.withLock { let notify = !failed && !cancelled; failed = true; accepting = false; return notify }
        if notify { onFailure(text) }
    }
    private func enqueue(_ chunk: SpeechAudioChunk) {
        let overflow = lock.withLock { () -> Bool in
            guard !cancelled, chunks.count < 12 else { return true }
            chunks.append(chunk)
            if worker == nil { worker = Task { [weak self] in await self?.consume() } }
            return false
        }
        if overflow { try? FileManager.default.removeItem(at: chunk.url); fail("转录处理不及，已停止转录；录音继续，可在结束后重新转录。") }
    }
    private func consume() async {
        while !Task.isCancelled {
            let next = lock.withLock { () -> SpeechAudioChunk? in
                guard !chunks.isEmpty else { worker = nil; return nil }
                return chunks.removeFirst()
            }
            guard let chunk = next else { return }
            do {
                let result = try await WhisperService.transcribe(chunk, settings: settings)
                if !Task.isCancelled { result.updates.forEach(onUpdate) }
            } catch { if !Task.isCancelled { fail(error.localizedDescription) } }
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }
    private func drain() async {
        lock.withLock { accepting = false }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                for writer in writers.values { if let chunk = writer.finish() { enqueue(chunk) } }
                writers.removeAll(); continuation.resume()
            }
        }
    }
    func finish() async {
        await drain()
        let current = lock.withLock { worker }
        let deadline = Task { do { try await Task.sleep(for: .seconds(60)); current?.cancel(); onFailure("转录收尾超时，已保存收到的文字。") } catch {} }
        await current?.value; deadline.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
    func cancel() async {
        lock.withLock { cancelled = true; accepting = false; worker?.cancel() }
        await drain(); let current = lock.withLock { worker }; current?.cancel(); await current?.value
        try? FileManager.default.removeItem(at: directory)
    }
}
