import Foundation
import AVFoundation

@main struct SpeechCheck {
    static func main() async {
        let path = CommandLine.arguments[1], locale = CommandLine.arguments[2]
        let speech = LiveTranscription()
        let results = Results()
        speech.onStatus = { print("STATUS:", $0) }
        speech.onFailure = { results.failure($0); print("ERROR:", $0) }
        speech.onUpdate = { results.add($0); print($0.isFinal ? "FINAL:" : "PARTIAL:", $0.source.rawValue, $0.start, $0.end, $0.text) }
        do {
            try await speech.prepare(locale: locale, microphone: true)
            async let system: Void = feed(path: path, speech: speech, source: .system, rate: 48000, channels: 2, planar: false)
            async let microphone: Void = feed(path: path, speech: speech, source: .microphone, rate: 44100, channels: 1, planar: true)
            _ = try await (system, microphone)
            print("FINAL_SOURCES_BEFORE_STOP:",results.sources.count)
            print("FINISHING")
            await speech.finish()
            let expected = locale == "zh-CN" ? ["星期五", "本地", "10"] : ["Friday", "locally", "10"]
            guard TranscriptSource.allCases.allSatisfy({ source in expected.allSatisfy { results.text(for: source).localizedCaseInsensitiveContains($0) } }), results.sources.count == 2, !results.hasFailure else { throw RecorderError.message("转录关键词/双声源验证失败") }
            print("PASS: real local ASR", locale)
        } catch { print("FAIL:",error.localizedDescription); exit(1) }
    }
    static func feed(path: String, speech: LiveTranscription, source: TranscriptSource, rate: Double, channels: Int, planar: Bool) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:rate, AVNumberOfChannelsKey:channels, AVLinearPCMBitDepthKey:32, AVLinearPCMIsFloatKey:true, AVLinearPCMIsNonInterleaved:planar])
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        while let sample = output.copyNextSampleBuffer() {
            speech.append(sample, source: source)
            try await Task.sleep(for: .seconds(Double(CMSampleBufferGetNumSamples(sample))/rate))
        }
        guard reader.status == .completed else { throw reader.error ?? RecorderError.message("合成语音读取失败") }
    }

}
final class Results: @unchecked Sendable {
    let lock = NSLock(); var updates: [TranscriptUpdate] = []; var errors: [String] = []
    func add(_ u: TranscriptUpdate) { lock.withLock { updates.append(u) } }
    func failure(_ s: String) { lock.withLock { errors.append(s) } }
    func text(for source: TranscriptSource) -> String { lock.withLock { updates.filter { $0.isFinal && $0.source == source }.map(\.text).joined() } }
    var sources: Set<TranscriptSource> { lock.withLock { Set(updates.filter(\.isFinal).map(\.source)) } }
    var hasFailure: Bool { lock.withLock { !errors.isEmpty } }
}
func durationText(_ value: Double) -> String { String(value) }
