import Foundation
import Speech
import AVFoundation
import CoreMedia

func pcmBuffer(from sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
    guard let description = CMSampleBufferGetFormatDescription(sample) else { throw RecorderError.message("缺少音频格式。") }
    let format = AVAudioFormat(cmAudioFormatDescription: description)
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else {
        throw RecorderError.message("无法读取转录音频格式。")
    }
    output.frameLength = output.frameCapacity
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(output.frameLength), into: output.mutableAudioBufferList)
    guard status == noErr else { throw RecorderError.message(LF("无法复制转录音频（%d）。", status)) }
    return output
}

final class LiveTranscription {
    var onUpdate: ((TranscriptUpdate) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private var pipeline: AnyObject?

    static var supported: Bool {
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    func prepare(locale: String, microphone: Bool) async throws {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
            throw RecorderError.message("本地实时转录需要支持 SpeechTranscriber 的 macOS 26 或更新版本；录音仍可单独使用。")
        }
        let instance = SpeechPipeline(onUpdate: { [weak self] in self?.onUpdate?($0) }, onFailure: { [weak self] in self?.onFailure?($0) })
        pipeline = instance
        do { try await instance.prepare(locale: locale, microphone: microphone, status: { [weak self] in self?.onStatus?($0) }) }
        catch { await instance.cancel(); pipeline = nil; throw error }
    }

    func append(_ sample: CMSampleBuffer, source: TranscriptSource) {
        if #available(macOS 26.0, *), let pipeline = pipeline as? SpeechPipeline { pipeline.append(sample, source: source) }
    }
    func finish() async {
        if #available(macOS 26.0, *), let pipeline = pipeline as? SpeechPipeline { await pipeline.finish() }
        pipeline = nil
    }
    func cancel() async {
        if #available(macOS 26.0, *), let pipeline = pipeline as? SpeechPipeline { await pipeline.cancel() }
        pipeline = nil
    }
}

@available(macOS 26.0, *)
private final class SpeechChannel {
    let module: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let format: AVAudioFormat
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    var converter: AVAudioConverter?
    var analysisTask: Task<Void, Never>?
    var resultsTask: Task<Void, Never>?
    var closed = false
    var nextOutputTime: CMTime?
    var previousInputEnd: Double?

    init(locale: Locale, source: TranscriptSource, onUpdate: @escaping (TranscriptUpdate) -> Void, onFailure: @escaping (String) -> Void) async throws {
        module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .utility, modelRetention: .whileInUse))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw RecorderError.message("没有可用于本地识别的音频格式。") }
        self.format = format
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(400))
        continuation = pair.continuation
        try await analyzer.prepareToAnalyze(in: format)
        let module = module, analyzer = analyzer
        resultsTask = Task {
            do {
                for try await result in module.results {
                    guard !Task.isCancelled else { break }
                    onUpdate(TranscriptUpdate(source: source, start: result.range.start.seconds,
                        end: CMTimeRangeGetEnd(result.range).seconds, text: String(result.text.characters), isFinal: result.isFinal))
                }
            } catch { if !Task.isCancelled { onFailure(LF("%@转录中断：%@", L(source.label), error.localizedDescription)) } }
        }
        analysisTask = Task {
            do { try await analyzer.start(inputSequence: pair.stream) }
            catch { if !Task.isCancelled { onFailure(LF("%@转录输入失败：%@", L(source.label), error.localizedDescription)) } }
        }

    }

    // Called only on SpeechPipeline.queue, separately from the recording queue.
    func append(_ sample: CMSampleBuffer) throws {
        guard !closed else { return }
        let original = try pcmBuffer(from: sample)
        let inputTime = CMSampleBufferGetPresentationTimeStamp(sample)
        if nextOutputTime == nil { nextOutputTime = inputTime }
        if let previousInputEnd {
            let gap = inputTime.seconds - previousInputEnd
            if gap > 0.025 {
                nextOutputTime = CMTimeAdd(nextOutputTime!, CMTime(seconds: gap, preferredTimescale: 48000))
                converter?.reset()
            }
        }
        previousInputEnd = inputTime.seconds + Double(original.frameLength) / original.format.sampleRate
        let output: AVAudioPCMBuffer
        if original.format == format { output = original }
        else {
            if converter?.inputFormat != original.format { converter = AVAudioConverter(from: original.format, to: format) }
            guard let converter,
                  let converted = AVAudioPCMBuffer(pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(ceil(Double(original.frameLength) * format.sampleRate / original.format.sampleRate)) + 64) else {
                throw RecorderError.message("无法转换本地转录音频。")
            }
            var supplied = false, error: NSError?
            let result = converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return original
            }
            guard result != .error else { throw error ?? RecorderError.message("转录重采样失败。") }
            output = converted
        }
        guard output.frameLength > 0 else { return }
        // A converter may buffer frames across calls. Timestamp converted output by its
        // actual frame count, rather than reusing each input chunk's PTS (which overlaps).
        let outputTime = nextOutputTime!
        nextOutputTime = CMTimeAdd(outputTime, CMTime(value: Int64(output.frameLength), timescale: Int32(format.sampleRate)))
        if case .dropped = continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: outputTime)) {
            closed = true; continuation.finish()
            throw RecorderError.message("本地识别处理速度不足，已停止转录以保护录音。请结束后检查文字完整性。")
        }
    }

    func finishInput() { closed = true; continuation.finish() }
    func finish() async {
        await analysisTask?.value
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { await analyzer.cancelAndFinishNow() }
        await resultsTask?.value
    }
    func cancel() async {
        analysisTask?.cancel(); resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

@available(macOS 26.0, *)
private final class SpeechPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.huisheng.transcription", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var accepting = false
    private var channels: [TranscriptSource: SpeechChannel] = [:]
    private let onUpdate: (TranscriptUpdate) -> Void
    private let onFailure: (String) -> Void

    init(onUpdate: @escaping (TranscriptUpdate) -> Void, onFailure: @escaping (String) -> Void) {
        self.onUpdate = onUpdate; self.onFailure = onFailure
    }
    func prepare(locale identifier: String, microphone: Bool, status: @escaping (String) -> Void) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw RecorderError.message("这台 Mac 不支持所选转录语言。")
        }
        status("正在准备本地语音识别…")
        try await AssetInventory.reserve(locale: locale)
        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            status("正在准备或从 Apple 下载本地识别组件，音频不会上传…")
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        for source in (microphone ? TranscriptSource.allCases : [.system]) {
            channels[source] = try await SpeechChannel(locale: locale, source: source, onUpdate: onUpdate, onFailure: onFailure)
        }
        lock.withLock { accepting = true }
        try Task.checkCancellation()
        status("本地转录已就绪")
    }
    func append(_ sample: CMSampleBuffer, source: TranscriptSource) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        guard pending < 400 else {
            accepting = false; lock.unlock()
            onFailure("转录队列已满，转录已停止，录音继续。")
            return
        }
        pending += 1; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer { lock.lock(); pending -= 1; lock.unlock() }
            do { try channels[source]?.append(sample) }
            catch {
                lock.lock(); let notify = accepting; accepting = false; lock.unlock()
                if notify { onFailure(error.localizedDescription) }
            }
        }
    }
    private func drain() async -> [SpeechChannel] {
        lock.withLock { accepting = false }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                channels.values.forEach { $0.finishInput() }
                continuation.resume(returning: Array(channels.values))
            }
        }
    }
    func finish() async {
        let active = await drain()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            onFailure("转录收尾超时，已保留收到的文字；末尾可能未定稿。录音仍会保存。")
            for channel in active { await channel.cancel() }
        }
        for channel in active { await channel.finish() }
        timeout.cancel()
    }
    func cancel() async { for channel in await drain() { await channel.cancel() } }
}
