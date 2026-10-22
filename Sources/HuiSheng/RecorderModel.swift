import SwiftUI
import AppKit
import AVFoundation
import Combine

struct Recording: Codable, Identifiable {
    var id = UUID()
    var title: String
    var date = Date()
    var source: String
    var microphone: Bool
    var duration: Double = 0
    var status = "recording"
    var filename: String?
    var note: String?
    var folderName: String

    static func safeName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\n\r\t").union(.controlCharacters)
        let cleaned = value.components(separatedBy: invalid).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "未命名会议" : String(cleaned.prefix(60))
    }
}

struct AudioSource: Identifiable, Hashable {
    var id: String
    var name: String
}

enum RecorderPhase { case idle, starting, recording, paused, saving }

@MainActor
final class RecorderModel: ObservableObject {
    @Published var phase: RecorderPhase = .idle
    @Published var title = ""
    @Published var sourceID = "all"
    @Published var useMicrophone = true
    @Published var useTranscription = LiveTranscription.supported
    @Published var transcriptionLocale = "zh-CN"
    let workspace = MeetingWorkspaceModel()
    private var transcription: LiveTranscription?
    private var preparationTask: Task<Void, Error>?
    private var startCancelled = false
    @Published var sources: [AudioSource] = []
    @Published var recordings: [Recording] = []
    @Published var folder: URL
    @Published var screenAllowed = false
    @Published var micAllowed = false
    @Published var systemLevel: Float = 0
    @Published var micLevel: Float = 0
    @Published var elapsed: Double = 0
    @Published var message: String?
    @Published var search = ""
    @Published var playingID: UUID?
    private var player: AVAudioPlayer?
    private var engine: CaptureEngine?
    private var current: Recording?
    private var timer: Timer?
    private var activeSince: Date?
    private var accumulated: Double = 0
    private var activity: NSObjectProtocol?
    private var captureFailure: String?
    private var ticks = 0
    private var reloadID = UUID()

    var busy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording || phase == .paused }
    var sourceName: String { sources.first(where: { $0.id == sourceID })?.name ?? "全部系统声音" }
    var filteredRecordings: [Recording] {
        recordings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) }
    }
    var totalDuration: Double { recordings.reduce(0) { $0 + $1.duration } }

    init() {
        let saved = UserDefaults.standard.string(forKey: "recordingFolder")
        folder = saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("会声", isDirectory: true)
        refreshPermissions(); refreshSources(); reload()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func refreshPermissions() {
        screenAllowed = CGPreflightScreenCaptureAccess()
        micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func refreshSources() {
        var seen = Set<String>()
        sources = NSWorkspace.shared.runningApplications.compactMap { app -> AudioSource? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return AudioSource(id: id, name: app.localizedName ?? id)
        }.sorted {
            func priority(_ source: AudioSource) -> Int {
                let s = (source.name + source.id).lowercased()
                return ["zoom", "teams", "wemeet", "voov", "腾讯会议"].contains(where: s.contains) ? 0 : 1
            }
            return priority($0) == priority($1) ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : priority($0) < priority($1)
        }
        if !busy && sourceID != "all" && !sources.contains(where: { $0.id == sourceID }) { sourceID = "all" }
    }

    func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "保存到这里"; panel.message = "选择录音保存位置"
        if panel.runModal() == .OK, let selected = panel.url {
            stopPlayback(); folder = selected
            UserDefaults.standard.set(selected.path, forKey: "recordingFolder")
            reload()
        }
    }

    func openFolder() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch { message = error.localizedDescription }
    }

    func openPermissionSettings(microphone: Bool = false) {
        let value = microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(value)") { NSWorkspace.shared.open(url) }
    }

    func start() async {
        guard phase == .idle else { return }
        startCancelled = false
        phase = .starting; message = nil; captureFailure = nil; stopPlayback()
        elapsed = 0; accumulated = 0; systemLevel = 0; micLevel = 0
        do {
            if useMicrophone {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else { throw RecorderError.message("麦克风权限未开启。请到系统设置中允许「会声」访问麦克风，或关闭「录入我的声音」后重试。") }
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try checkDisk(minimum: 512 * 1024 * 1024)
            workspace.speechError = nil
            if useTranscription {
                let speech = LiveTranscription()
                speech.onStatus = { [weak self] status in Task { @MainActor in self?.workspace.speechStatus = status } }
                speech.onFailure = { [weak self] text in Task { @MainActor in self?.workspace.speechError = text } }
                let locale = transcriptionLocale, microphone = useMicrophone
                let preparing = Task { try await speech.prepare(locale: locale, microphone: microphone) }
                preparationTask = preparing
                do { try await preparing.value; transcription = speech }
                catch {
                    if startCancelled { throw CancellationError() }
                    workspace.speechError = error.localizedDescription; workspace.speechStatus = "本地识别未就绪，正在仅录音"; transcription = nil
                }
                preparationTask = nil
            } else { workspace.speechStatus = "此场会议未启用实时转录" }
            if startCancelled { throw CancellationError() }
            let name = Recording.safeName(title)
            let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let folderName = "\(stamp.string(from: Date()))_\(name)_\(UUID().uuidString.prefix(6))"
            let record = Recording(title: name, source: sourceName, microphone: useMicrophone, folderName: folderName)
            current = record
            try persist(record)
            let previousSpeechError = workspace.speechError
            workspace.begin(recording: record, directory: folder.appendingPathComponent(folderName))
            workspace.speechError = previousSpeechError
            transcription?.onUpdate = { [weak self] update in
                Task { @MainActor in self?.workspace.receive(update, recordingID: record.id) }
            }
            let capture = CaptureEngine()
            if let transcription { capture.onAudio = { [weak transcription] sample, source in transcription?.append(sample, source: source) } }
            capture.onLevels = { [weak self] system, microphone in
                Task { @MainActor [weak self] in
                    guard let self, self.phase == .recording else { return }
                    self.systemLevel = system; self.micLevel = microphone
                }
            }
            capture.onFailure = { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.captureFailure = text
                    if self.isRecording { await self.stop(reason: text) }
                }
            }
            engine = capture
            try await capture.start(options: CaptureOptions(bundleID: sourceID == "all" ? nil : sourceID,
                microphone: useMicrophone, video: false, displayID: CGMainDisplayID()),
                folder: folder.appendingPathComponent(folderName).appendingPathComponent("原始音轨"))
            if startCancelled { throw CancellationError() }
            if let captureFailure { throw RecorderError.message(captureFailure) }
            refreshPermissions()
            activeSince = Date()
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "正在录制会议音频")
            phase = .recording
            if transcription != nil { workspace.speechStatus = "正在本地转录" }
        } catch {
            _ = try? await engine?.stop()
            await transcription?.cancel(); transcription = nil
            engine = nil
            if var record = current {
                let directory = folder.appendingPathComponent(record.folderName)
                let raw = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("原始音轨"), includingPropertiesForKeys: nil)) ?? []
                if raw.contains(where: { $0.pathExtension == "mov" }) {
                    record.status = "interrupted"; record.note = error.localizedDescription; try? persist(record)
                } else {
                    // This directory was created by this failed start and contains no captured media.
                    workspace.clear()
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            preparationTask = nil
            current = nil; phase = .idle; refreshPermissions(); reload()
            if startCancelled { workspace.speechStatus = "已取消准备，可以重新开始录音。"; return }
            message = "未能开始录音：\(error.localizedDescription)\n首次使用还需要在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许「会声」。授权后若仍失败，请退出并重新打开。"
        }
    }

    func cancelStart() {
        guard phase == .starting else { return }
        startCancelled = true; preparationTask?.cancel()
        workspace.speechStatus = "正在取消准备…"
    }
    func pauseOrResume() {
        guard isRecording else { return }
        if phase == .recording {
            engine?.setPaused(true)
            accumulated = elapsedNow(); activeSince = nil; elapsed = accumulated
            phase = .paused; systemLevel = 0; micLevel = 0
            if transcription != nil { workspace.speechStatus = "已暂停 · 不接收新的音频" }
        } else {
            engine?.setPaused(false)
            activeSince = Date(); phase = .recording
            if transcription != nil { workspace.speechStatus = "正在本地转录" }
        }
    }

    func stop(reason: String? = nil) async {
        guard isRecording, let engine, var record = current else { return }
        elapsed = elapsedNow(); phase = .saving; activeSince = nil
        systemLevel = 0; micLevel = 0
        defer {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil; self.engine = nil; current = nil; phase = .idle; reload()
        }
        do {
            let tracks = try await engine.stop()
            if let transcription {
                workspace.isFinalizing = true
                await transcription.finish(); self.transcription = nil
                workspace.isFinalizing = false
                workspace.speechStatus = workspace.speechError == nil ? "转录已保存到本地" : "已保存收到的文字 · 请检查转录提示"
            }
            workspace.flush()
            let directory = folder.appendingPathComponent(record.folderName)
            let destination = directory.appendingPathComponent("\(record.title).m4a")
            record.duration = try await MediaExporter.export(tracks: tracks, to: destination, video: false)
            record.filename = destination.lastPathComponent; record.status = "ready"; record.note = reason
            try persist(record)
            title = ""
            message = reason.map { "\($0)\n已成功保存中断前的录音。" }
        } catch {
            await transcription?.cancel(); transcription = nil
            workspace.isFinalizing = false; workspace.flush()
            record.status = "interrupted"; record.duration = elapsed; record.note = error.localizedDescription
            try? persist(record)
            message = "导出未完成：\(error.localizedDescription)\n原始音轨已保留，可在录音列表中尝试「恢复导出」。"
        }
    }

    func recover(_ record: Recording) async {
        guard !busy else { return }
        phase = .saving; stopPlayback()
        defer { phase = .idle; reload() }
        do {
            var updated = record
            let directory = folder.appendingPathComponent(record.folderName)
            let tracks = (try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("原始音轨"), includingPropertiesForKeys: nil)).filter { $0.pathExtension == "mov" }
            let destination = directory.appendingPathComponent("\(record.title)_恢复_\(UUID().uuidString.prefix(4)).m4a")
            updated.duration = try await MediaExporter.export(tracks: tracks, to: destination, video: false)
            updated.filename = destination.lastPathComponent; updated.status = "ready"; updated.note = "已从原始音轨恢复。"
            try persist(updated)
        } catch { message = "恢复失败：\(error.localizedDescription)\n原始文件仍保留在录音文件夹中。" }
    }

    func openTranscript(_ record: Recording) {
        guard !busy else { return }
        workspace.open(recording: record, directory: folder.appendingPathComponent(record.folderName))
    }
    func play(_ record: Recording) {
        guard !busy, let url = fileURL(record) else { return }
        if playingID == record.id { stopPlayback(); return }
        do {
            stopPlayback(); player = try AVAudioPlayer(contentsOf: url)
            guard player?.play() == true else { throw RecorderError.message("无法播放这份录音。") }
            playingID = record.id
        } catch { message = error.localizedDescription }
    }

    func stopPlayback() { player?.stop(); player = nil; playingID = nil }
    func reveal(_ record: Recording) { NSWorkspace.shared.activateFileViewerSelecting([fileURL(record) ?? folder.appendingPathComponent(record.folderName)]) }
    func fileURL(_ record: Recording) -> URL? { record.filename.map { folder.appendingPathComponent(record.folderName).appendingPathComponent($0) } }

    func reload() {
        let requestedFolder = folder, currentID = current?.id, request = UUID()
        reloadID = request
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                RecordingLibrary.load(folder: requestedFolder, activeID: currentID)
            }.value
            guard let self, self.reloadID == request, self.folder == requestedFolder else { return }
            self.recordings = loaded
        }
    }

    private func persist(_ record: Recording) throws {
        let directory = folder.appendingPathComponent(record.folderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
    private func elapsedNow() -> Double { accumulated + (activeSince.map { Date().timeIntervalSince($0) } ?? 0) }
    private func checkDisk(minimum: Int64) throws {
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < minimum {
            throw RecorderError.message("保存位置剩余空间不足，请释放磁盘空间或更换保存位置。")
        }
    }
    private func tick() {
        ticks += 1
        if phase == .recording { elapsed = elapsedNow() }
        if ticks % 3 == 0 { refreshPermissions(); refreshSources() }
        if ticks % 10 == 0, isRecording {
            do { try checkDisk(minimum: 100 * 1024 * 1024) }
            catch { Task { await stop(reason: error.localizedDescription) } }
        }
        if playingID != nil && player?.isPlaying != true { stopPlayback() }
    }
}

// File providers and folder access prompts can block reads. Keep library I/O off the UI thread.
enum RecordingLibrary {
    static func load(folder: URL, activeID: UUID?) -> [Recording] {
        guard let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return children.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                  var record = try? JSONDecoder().decode(Recording.self, from: data),
                  record.folderName == directory.lastPathComponent,
                  record.filename == nil || record.filename == URL(fileURLWithPath: record.filename!).lastPathComponent else { return nil }
            if record.status == "recording", record.id != activeID { record.status = "interrupted" }
            if record.status == "interrupted", record.filename == nil {
                let raw = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("原始音轨"), includingPropertiesForKeys: nil)) ?? []
                guard raw.contains(where: { $0.pathExtension == "mov" }) else { return nil }
            }
            return record
        }.sorted { $0.date > $1.date }
    }
}

func durationText(_ value: Double) -> String {
    let seconds = max(0, Int(value.isFinite ? value : 0))
    return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
}
