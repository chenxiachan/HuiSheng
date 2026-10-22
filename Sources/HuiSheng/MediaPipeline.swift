import AVFoundation
import CoreMedia

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return L(text) }; return nil }
}

/// All access is serialized on CaptureEngine's media queue.
struct MediaTimeline {
    private(set) var origin: CMTime?
    private(set) var pausedAt: CMTime?
    private(set) var removed = CMTime.zero
    private var resumeCutoff: CMTime?

    mutating func pause(at time: CMTime) { if pausedAt == nil { pausedAt = time } }
    mutating func resume(at time: CMTime) {
        guard let start = pausedAt else { return }
        // A pause before the first received sample must not shift its origin.
        if origin != nil { removed = removed + CMTimeMaximum(.zero, time - start) }
        pausedAt = nil
        resumeCutoff = time
    }
    mutating func offset(for time: CMTime) -> CMTime? {
        guard pausedAt == nil, time.isNumeric else { return nil }
        if let cutoff = resumeCutoff, time < cutoff { return nil }
        if origin == nil { origin = time }
        let result = time - origin! - removed
        return result >= .zero ? result : nil
    }
}

func retimedSample(_ sample: CMSampleBuffer, to presentation: CMTime) throws -> CMSampleBuffer {
    var count = 0
    var status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    guard status == noErr, count > 0 else { throw RecorderError.message("无法读取音视频时间戳。") }
    var timings = Array(repeating: CMSampleTimingInfo(), count: count)
    status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
    guard status == noErr else { throw RecorderError.message("无法读取音视频时间戳。") }
    let shift = CMSampleBufferGetPresentationTimeStamp(sample) - presentation
    for i in timings.indices {
        timings[i].presentationTimeStamp = timings[i].presentationTimeStamp - shift
        if timings[i].decodeTimeStamp.isNumeric { timings[i].decodeTimeStamp = timings[i].decodeTimeStamp - shift }
    }
    var result: CMSampleBuffer?
    status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
        sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &result)
    guard status == noErr, let result else { throw RecorderError.message(LF("音视频时间同步失败（%d）。", status)) }
    return result
}

final class TrackWriter {
    let url: URL
    let type: AVMediaType
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var sampleCount = 0
    private(set) var droppedFrames = 0
    private(set) var endTime = CMTime.zero

    init(url: URL, type: AVMediaType) { self.url = url; self.type = type }

    func append(_ sample: CMSampleBuffer) throws {
        guard CMSampleBufferDataIsReady(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        if writer == nil {
            let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
            newWriter.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            let settings: [String: Any]
            if type == .audio {
                settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160000]
            } else {
                let size = CMVideoFormatDescriptionGetDimensions(format)
                settings = [AVVideoCodecKey: AVVideoCodecType.h264,
                            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000,
                                AVVideoMaxKeyFrameIntervalKey: 60, AVVideoAllowFrameReorderingKey: false]]
            }
            let newInput = AVAssetWriterInput(mediaType: type, outputSettings: settings, sourceFormatHint: format)
            newInput.expectsMediaDataInRealTime = true
            guard newWriter.canAdd(newInput) else { throw RecorderError.message("无法创建录制轨道。") }
            newWriter.add(newInput)
            guard newWriter.startWriting() else { throw newWriter.error ?? RecorderError.message("无法写入录制文件。") }
            newWriter.startSession(atSourceTime: .zero)
            writer = newWriter; input = newInput
        }
        guard let writer, let input else { return }
        guard writer.status == .writing else { throw writer.error ?? RecorderError.message("录制文件写入已中断。") }
        guard input.isReadyForMoreMediaData else {
            if type == .video { droppedFrames += 1; return }
            throw RecorderError.message("磁盘写入速度不足，音频录制已停止；已录内容将保留。")
        }
        guard input.append(sample) else { throw writer.error ?? RecorderError.message("无法写入音视频数据。") }
        sampleCount += 1
        let duration = CMSampleBufferGetDuration(sample)
        endTime = CMTimeMaximum(endTime, CMSampleBufferGetPresentationTimeStamp(sample) + (duration.isNumeric ? duration : .zero))
    }

    func finish() async throws -> URL? {
        guard let writer, sampleCount > 0 else { return nil }
        if writer.status == .writing {
            input?.markAsFinished()
            await writer.finishWriting()
        }
        guard writer.status == .completed else { throw writer.error ?? RecorderError.message("录制轨道未能完整保存。") }
        return url
    }
}

enum MediaExporter {
    /// Retains source offsets, mixes the two independent audio clocks and exports a single playable track.
    static func export(tracks: [URL], to destination: URL, video: Bool) async throws -> Double {
        let composition = AVMutableComposition()
        var audioParameters: [AVMutableAudioMixInputParameters] = []
        for url in tracks {
            let asset = AVURLAsset(url: url)
            for source in try await asset.load(.tracks) {
                let type = source.mediaType
                guard type == .audio || (video && type == .video),
                      let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let range = try await source.load(.timeRange)
                guard range.duration > .zero else { continue }
                try target.insertTimeRange(range, of: source, at: range.start)
                if type == .audio { audioParameters.append(AVMutableAudioMixInputParameters(track: target)) }
                if type == .video { target.preferredTransform = try await source.load(.preferredTransform) }
            }
        }
        guard composition.duration > .zero else { throw RecorderError.message("没有收到可保存的音视频。请确认会议正在播放声音。") }
        if video && composition.tracks(withMediaType: .video).isEmpty {
            throw RecorderError.message("没有收到屏幕画面，原始音轨已保留。")
        }
        let mix = AVMutableAudioMix()
        let gain: Float = audioParameters.count > 1 ? 0.5 : 1
        for parameter in audioParameters { parameter.setVolume(gain, at: .zero) }
        mix.inputParameters = audioParameters
        let preset = video ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw RecorderError.message("无法启动本地文件导出。")
        }
        exporter.audioMix = mix
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("export-\(UUID().uuidString).\(video ? "mp4" : "m4a")")
        do {
            try await exporter.export(to: temporary, as: video ? .mp4 : .m4a)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return composition.duration.seconds
    }
}

func audioLevel(_ sample: CMSampleBuffer) -> Float {
    guard let format = CMSampleBufferGetFormatDescription(sample),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM else { return 0 }
    var size = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size,
        bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
        flags: 0, blockBufferOut: nil)
    guard size > 0 else { return 0 }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { memory.deallocate() }
    let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
    var block: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
        bufferListOut: list, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
        flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block) == noErr else { return 0 }
    var peak: Float = 0
    for buffer in UnsafeMutableAudioBufferListPointer(list) {
        guard let data = buffer.mData else { continue }
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32 {
            let values = data.assumingMemoryBound(to: Float.self)
            for index in stride(from: 0, to: Int(buffer.mDataByteSize) / 4, by: 8) { peak = max(peak, abs(values[index])) }
        } else if asbd.mBitsPerChannel == 16 {
            let values = data.assumingMemoryBound(to: Int16.self)
            for index in stride(from: 0, to: Int(buffer.mDataByteSize) / 2, by: 8) { peak = max(peak, abs(Float(values[index])) / 32768) }
        }
    }
    return min(1, max(0, (20 * log10(max(peak, 0.0001)) + 60) / 60))
}
