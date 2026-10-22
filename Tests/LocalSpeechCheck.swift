import Foundation
import AVFoundation

@main struct LocalSpeechCheck {
    static func main() async {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        do {
            await ExecutableLocator.refresh()
            let settings = try TranscriptionSettings(engine: .whisper, language: "auto",
                whisperExecutable: ProcessInfo.processInfo.environment["WHISPER_CLI"] ?? "",
                whisperModel: ProcessInfo.processInfo.environment["WHISPER_MODEL"] ?? "").validated()
            for (file, words) in [("chinese.aiff", ["星期五", "本地"]), ("english.aiff", ["Friday", "locally"])] {
                let record = Recording(title: "Synthetic", source: "test", microphone: false, filename: file, folderName: root.lastPathComponent)
                let document = try await FileTranscription.transcribe(recording: record, directory: root, settings: settings) { _ in }
                let text = document.segments.map(\.text).joined()
                try LocalSpeechTests.require(words.allSatisfy { text.localizedCaseInsensitiveContains($0) }, "Whisper 自动语言识别 " + text)
                print("PASS: Whisper automatic file transcription", file, text)
            }
            let saved = root.appendingPathComponent("meeting.json")
            try Data("unchanged".utf8).write(to: saved)
            let cancelRecord = Recording(title: "Synthetic", source: "test", microphone: false, filename: "chinese.aiff", folderName: root.lastPathComponent)
            let cancelled = Task { try await FileTranscription.transcribe(recording: cancelRecord, directory: root, settings: settings) { _ in } }
            try await Task.sleep(for: .milliseconds(900)); cancelled.cancel()
            do { _ = try await cancelled.value; throw RecorderError.message("FAIL: 取消任务应抛错") } catch is CancellationError {} catch { throw error }
            try LocalSpeechTests.require(try Data(contentsOf: saved) == Data("unchanged".utf8), "取消不能改已有文字")
            print("PASS: file cancellation preserves original")
            let results = SpeechResults(), speech = LiveTranscription()
            speech.onUpdate = { results.add($0) }; speech.onFailure = { results.fail($0) }
            try await speech.prepare(settings: settings, microphone: true)
            async let a: Void = feed(root.appendingPathComponent("chinese.aiff"), speech: speech, source: .system, rate: 48000, channels: 2)
            async let b: Void = feed(root.appendingPathComponent("english.aiff"), speech: speech, source: .microphone, rate: 44100, channels: 1)
            _ = try await (a, b)
            // Allow the last full chunk to finish before stopping; trailing fragments are drained below.
            try await Task.sleep(for: .seconds(4))
            let beforeStop = results.count
            await speech.finish()
            try LocalSpeechTests.require(beforeStop > 0, "停止前应出现实时文字")
            try LocalSpeechTests.require(results.text(.system).contains("星期五") && results.text(.microphone).localizedCaseInsensitiveContains("Friday"), "双路分别自动识别中文和英文")
            try LocalSpeechTests.require(results.errors.isEmpty, "实时识别不应失败: " + results.errors.joined())
            print("PASS: live automatic Chinese/English, two formats/tracks, updates before stop:", beforeStop)
            if LiveTranscription.supported {
                var apple = settings; apple.engine = .apple; apple.language = "zh-CN"
                let document = try await FileTranscription.transcribe(recording: cancelRecord, directory: root, settings: apple) { _ in }
                try LocalSpeechTests.require(document.plainTranscript.contains("星期五"), "Apple 本地事后识别")
                print("PASS: Apple on-device file transcription")
            }
            print("PASS: all real local speech checks (synthetic audio only)")
        } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
    static func feed(_ url: URL, speech: LiveTranscription, source: TranscriptSource, rate: Double, channels: Int) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        for repetition in 0..<2 {
        let reader = try AVAssetReader(asset: asset), tracks = try await asset.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: channels == 1])
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        while let sample = output.copyNextSampleBuffer() {
            let shifted = try retimedSample(sample, to: CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(seconds: Double(repetition) * duration, preferredTimescale: 48000)))
            speech.append(shifted, source: source)
            try await Task.sleep(for: .seconds(Double(CMSampleBufferGetNumSamples(sample)) / rate))
        }
        guard reader.status == .completed else { throw reader.error ?? RecorderError.message("合成音频读取失败") }
        }
    }
}
final class SpeechResults: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [TranscriptUpdate] = [], failures: [String] = []
    func add(_ update: TranscriptUpdate) { lock.withLock { updates.append(update) } }
    func fail(_ text: String) { lock.withLock { failures.append(text) } }
    var errors: [String] { lock.withLock { failures } }
    var count: Int { lock.withLock { updates.count } }
    func text(_ source: TranscriptSource) -> String { lock.withLock { updates.filter { $0.source == source }.map(\.text).joined() } }
}
