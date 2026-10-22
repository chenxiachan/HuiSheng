import AVFoundation

final class MediaTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48000) }

    func testPauseRemovesGapAndRejectsStaleSamples() throws {
        var timeline = MediaTimeline()
        checkEqual(try require(timeline.offset(for: time(100))).seconds, 0, accuracy: 0.0001)
        checkEqual(try require(timeline.offset(for: time(100.5))).seconds, 0.5, accuracy: 0.0001)
        timeline.pause(at: time(101))
        checkNil(timeline.offset(for: time(101.5)))
        timeline.resume(at: time(103))
        checkNil(timeline.offset(for: time(102.99)))
        checkEqual(try require(timeline.offset(for: time(103))).seconds, 1, accuracy: 0.0001)
        timeline.pause(at: time(104)); timeline.resume(at: time(110))
        checkEqual(try require(timeline.offset(for: time(110.5))).seconds, 2.5, accuracy: 0.0001)
    }

    func testPauseBeforeFirstSampleDoesNotEraseAudio() throws {
        var timeline = MediaTimeline()
        timeline.pause(at: time(1)); timeline.resume(at: time(4))
        checkEqual(try require(timeline.offset(for: time(4.1))).seconds, 0, accuracy: 0.0001)
    }

    func testSafeFilenameAndDuration() {
        checkEqual(Recording.safeName("../会议/一:二\n"), ".. 会议 一 二")
        checkEqual(Recording.safeName(".."), "未命名会议")
        checkEqual(Recording.safeName("  "), "未命名会议")
        checkEqual(durationText(3661), "01:01:01")
    }

    func testTwoFormatsMixWithOffsetAndPause() async throws {
        let root = ProcessInfo.processInfo.environment["HUISHENG_TEST_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("HuiShengTests")
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let system = TrackWriter(url: folder.appendingPathComponent("system.mov"), type: .audio)
        let mic = TrackWriter(url: folder.appendingPathComponent("microphone.mov"), type: .audio)
        var timeline = MediaTimeline()
        for index in 0..<100 {
            if index == 50 { timeline.pause(at: time(101)); timeline.resume(at: time(103)) }
            let pts = 100 + Double(index) * 0.02 + (index >= 50 ? 2 : 0)
            let offset = try require(timeline.offset(for: time(pts)))
            let systemSample = try makeAudio(rate: 48000, channels: 2, frequency: 440, start: Double(index) * 0.02, pts: pts)
            try system.append(retimedSample(systemSample, to: offset))
            if index >= 18 {
                let micSample = try makeAudio(rate: 44100, channels: 1, frequency: 880, start: Double(index) * 0.02, pts: pts)
                try mic.append(retimedSample(micSample, to: offset))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let finishedSystem = try await system.finish()
        let a = try require(finishedSystem)
        let finishedMic = try await mic.finish()
        let b = try require(finishedMic)
        let output = folder.appendingPathComponent("mixed.m4a")
        let duration = try await MediaExporter.export(tracks: [a, b], to: output, video: false)
        checkEqual(duration, 2, accuracy: 0.08)
        let asset = AVURLAsset(url: output)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        checkEqual(audio.count, 1)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        check(videoTracks.isEmpty)
        let exportedDuration = try await asset.load(.duration)
        checkEqual(exportedDuration.seconds, 2, accuracy: 0.08)
        let samples = try decode(asset: asset, track: require(audio.first))
        let early = Array(samples[4800..<12000])
        let middle = Array(samples[24000..<38400])
        let tail = Array(samples[72000..<86400])
        checkGreater(energy(early, frequency: 440), 0.05)
        checkLess(energy(early, frequency: 880), 0.01, "麦克风在开始 0.36 秒后才出现，起始偏移必须保留")
        for part in [middle, tail] {
            checkGreater(energy(part, frequency: 440), 0.04, "系统声音必须保留")
            checkGreater(energy(part, frequency: 880), 0.04, "麦克风声音必须保留，暂停后不能丢失")
        }
        checkLess(samples.map(abs).max() ?? 0, 0.99)
        print("音频验证文件：\(output.path)")
    }

    func testEmptyExportFailsWithoutCreatingFinalFile() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
        do { _ = try await MediaExporter.export(tracks: [], to: destination, video: false); fail("空录音应报告错误") }
        catch { checkFalse(FileManager.default.fileExists(atPath: destination.path)) }
    }

    private func makeAudio(rate: Double, channels: Int, frequency: Double, start: Double, pts: Double) throws -> CMSampleBuffer {
        let frames = Int(rate * 0.02)
        var values = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let value = Float(0.35 * sin(2 * .pi * frequency * (start + Double(frame) / rate)))
            for channel in 0..<channels { values[frame * channels + channel] = value }
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(channels * 4),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        checkEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        let size = values.count * 4
        checkEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: size, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: size, flags: 0, blockBufferOut: &block), noErr)
        let data = try require(block)
        values.withUnsafeBytes { bytes in
            checkEqual(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: size), noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: time(pts), decodeTimeStamp: .invalid)
        var sampleSize = channels * 4
        var sample: CMSampleBuffer?
        checkEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize, sampleBufferOut: &sample), noErr)
        return try require(sample)
    }

    private func decode(asset: AVAsset, track: AVAssetTrack) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); check(reader.startReading())
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            values.withUnsafeMutableBytes { ptr in
                checkEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!), noErr)
            }
            samples.append(contentsOf: values)
        }
        checkEqual(reader.status, .completed)
        return samples
    }

    private func energy(_ samples: [Float], frequency: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for (index, value) in samples.enumerated() {
            let phase = 2 * .pi * frequency * Double(index) / 48000
            real += Double(value) * cos(phase); imaginary += Double(value) * sin(phase)
        }
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(samples.count)
    }
}


// Small standalone runner: works with Apple's Command Line Tools, without full Xcode/XCTest.
private var failureCount = 0
private func fail(_ message: String) { failureCount += 1; print("FAIL: \(message)") }
private func check(_ value: Bool, _ message: String = "条件未满足") { if !value { fail(message) } }
private func checkFalse(_ value: Bool) { check(!value) }
private func checkNil<T>(_ value: T?) { check(value == nil) }
private func checkEqual<T: Equatable>(_ a: T, _ b: T) { check(a == b, "\(a) != \(b)") }
private func checkEqual(_ a: Double, _ b: Double, accuracy: Double) { check(abs(a-b) <= accuracy, "\(a) 与 \(b) 偏差超过 \(accuracy)") }
private func checkGreater<T: Comparable>(_ a: T, _ b: T, _ message: String = "数值过小") { check(a > b, message) }
private func checkLess<T: Comparable>(_ a: T, _ b: T, _ message: String = "数值过大") { check(a < b, message) }
private func require<T>(_ value: T?) throws -> T { guard let value else { throw RecorderError.message("缺少测试数据") }; return value }

@main struct VerificationRunner {
    static func main() async {
        let tests = MediaTests()
        do {
            try tests.testPauseRemovesGapAndRejectsStaleSamples()
            try tests.testPauseBeforeFirstSampleDoesNotEraseAudio()
            tests.testSafeFilenameAndDuration()
            try await tests.testTwoFormatsMixWithOffsetAndPause()
            try await tests.testEmptyExportFailsWithoutCreatingFinalFile()
            try await FeatureTests().run()
        } catch { fail(error.localizedDescription) }
        if failureCount == 0 { print("PASS：全部检查通过（含 5 项音频检查、转录与追问检查）。") }
        exit(failureCount == 0 ? 0 : 1)
    }
}
