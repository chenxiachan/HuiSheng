import AppKit
import ScreenCaptureKit
import AVFoundation

struct CaptureOptions {
    var bundleID: String?
    var microphone: Bool
    var video: Bool
    var displayID: CGDirectDisplayID
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "local.huisheng.media", qos: .userInitiated)
    private var stream: SCStream?
    private var timeline = MediaTimeline()
    private var writers: [SCStreamOutputType: TrackWriter] = [:]
    private var accepting = false
    private var reportedError = false
    private var lastMeter = CMTime.zero
    private var systemLevel: Float = 0
    private var micLevel: Float = 0
    var onLevels: ((Float, Float) -> Void)?
    var onFailure: ((String) -> Void)?
    var onAudio: ((CMSampleBuffer, TranscriptSource) -> Void)?

    func start(options: CaptureOptions, folder: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == options.displayID }) ?? content.displays.first else {
            throw RecorderError.message("没有可用于录制的显示器。")
        }
        let filter: SCContentFilter
        if let bundleID = options.bundleID {
            let apps = content.applications.filter { $0.bundleIdentifier == bundleID || $0.bundleIdentifier.hasPrefix(bundleID + ".") }
            guard !apps.isEmpty else { throw RecorderError.message("选择的会议应用已退出，请先打开应用或改为全部系统声音。") }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }, exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.captureMicrophone = options.microphone
        config.showsCursor = options.video
        config.queueDepth = 5
        let scale = min(1, 1920.0 / Double(max(display.width, display.height)))
        config.width = options.video ? max(2, Int(Double(display.width) * scale) / 2 * 2) : 2
        config.height = options.video ? max(2, Int(Double(display.height) * scale) / 2 * 2) : 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: options.video ? 30 : 1)
        config.streamName = "会声 · 会议录制"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writers[.audio] = TrackWriter(url: folder.appendingPathComponent("system.mov"), type: .audio)
        if options.microphone { writers[.microphone] = TrackWriter(url: folder.appendingPathComponent("microphone.mov"), type: .audio) }
        if options.video { writers[.screen] = TrackWriter(url: folder.appendingPathComponent("screen.mov"), type: .video) }
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if options.microphone { try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        // Register screen output in both modes to drain ScreenCaptureKit's video queue.
        // Audio-only mode never passes a frame to a writer.
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = capture
        queue.sync { accepting = true }
        do { try await capture.startCapture() }
        catch { queue.sync { accepting = false }; stream = nil; throw error }
    }

    func setPaused(_ paused: Bool) {
        queue.sync {
            let time = CMClockGetTime(CMClockGetHostTimeClock())
            if paused { timeline.pause(at: time) } else { timeline.resume(at: time) }
        }
        if paused { onLevels?(0, 0) }
    }

    func stop() async throws -> [URL] {
        if let stream { try? await stream.stopCapture() }
        let allWriters: [TrackWriter] = queue.sync {
            accepting = false
            return Array(writers.values)
        }
        self.stream = nil
        var results: [URL] = []
        var errors: [Error] = []
        for writer in allWriters {
            do { if let url = try await writer.finish() { results.append(url) } }
            catch { errors.append(error) }
        }
        if let first = errors.first { throw first }
        return results
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, CMSampleBufferIsValid(sampleBuffer), let writer = writers[type] else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let adjusted = timeline.offset(for: time) else { return }
        do {
            let aligned = try retimedSample(sampleBuffer, to: adjusted)
            try writer.append(aligned)
            if type == .audio { onAudio?(aligned, .system) }
            if type == .microphone { onAudio?(aligned, .microphone) }
            if type == .audio { systemLevel = audioLevel(sampleBuffer) }
            if type == .microphone { micLevel = audioLevel(sampleBuffer) }
            if (time - lastMeter).seconds > 0.10 {
                lastMeter = time
                onLevels?(systemLevel, micLevel)
            }
        } catch { fail(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.fail("系统已中断录制：\(error.localizedDescription)") }
    }

    private func fail(_ message: String) {
        guard accepting, !reportedError else { return }
        reportedError = true; accepting = false
        onFailure?(message)
    }
}
