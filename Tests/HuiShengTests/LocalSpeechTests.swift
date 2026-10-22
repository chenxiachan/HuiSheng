import Foundation

enum LocalSpeechTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw RecorderError.message("FAIL: " + message) }
    }
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("HuiSheng-Discovery-Test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let older = root.appendingPathComponent(".nvm/versions/node/v9.0.0/bin"), newer = root.appendingPathComponent(".nvm/versions/node/v24.0.0/bin")
        let fnm = root.appendingPathComponent("Library/Application Support/fnm/node-versions/v22.0.0/installation/bin")
        for directory in [older, newer, fnm] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        func executable(_ url: URL, _ contents: String = "#!/bin/sh\nprintf detected") throws {
            try Data(contents.utf8).write(to: url); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let cliName = "huisheng-test-cli"
        try executable(older.appendingPathComponent(cliName)); try executable(newer.appendingPathComponent(cliName))
        let paths = ExecutableLocator.searchDirectories(environment: ["PATH": "/usr/bin:/bin:.:/usr/bin"], home: root.path)
        try require(paths.count == Set(paths).count && !paths.contains("."), "路径去重并忽略相对目录")
        try require(ExecutableLocator.locate(cliName, in: paths) == newer.appendingPathComponent(cliName).path, "访达稀疏 PATH 中找到最新 NVM 安装")
        try require(paths.contains(fnm.path), "发现含空格的 FNM 路径")
        try require(!ExecutableLocator.executable(newer.path), "目录不能被当作可执行文件")
        try require(ExecutableLocator.locate("../" + cliName, in: paths) == nil, "拒绝路径穿越名称")
        try executable(newer.appendingPathComponent("fake-runtime"), "#!/bin/sh\nprintf runtime-ok")
        let script = newer.appendingPathComponent("agent")
        try executable(script, "#!/usr/bin/env fake-runtime\n")
        let answer = try await LocalCommandProcess().run(.init(executable: script, arguments: [], input: Data(), output: nil), directory: root)
        try require(answer == "runtime-ok", "子进程 PATH 包含 CLI 所在目录，支持 env shebang")

        let json = Data(#"{"result":{"language":"zh"},"transcription":[{"offsets":{"from":200,"to":1500},"text":" 星期五 "},{"offsets":{"from":1500,"to":12000},"text":"本地"},{"offsets":{"from":12000,"to":13000},"text":"越界"}]}"#.utf8)
        let chunk = SpeechAudioChunk(url: root.appendingPathComponent("test.wav"), source: .microphone, start: 3, duration: 10)
        let result = try WhisperResult.decode(json, chunk: chunk)
        try require(result.language == "zh" && result.updates.count == 2, "解析检测语言并丢弃越界片段")
        try require(result.updates[0].start == 3.2 && result.updates[0].end == 4.5 && result.updates[1].end == 13, "毫秒偏移转为秒，保留音轨起始时间")
        try require(result.updates.allSatisfy { $0.source == .microphone && $0.isFinal }, "保留音轨与定稿标志")
        let model = root.appendingPathComponent("ggml-small.en.bin"); try Data().write(to: model)
        let settings = TranscriptionSettings(engine: .whisper, language: "auto", whisperExecutable: script.path, whisperModel: model.path)
        do { _ = try settings.validated(); throw RecorderError.message("FAIL: 英语专用模型不能用于自动识别") }
        catch { if error.localizedDescription.hasPrefix("FAIL:") { throw error } }

        let id = UUID(), folder = root.appendingPathComponent("recording")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var original = MeetingDocument(recordingID: id)
        original.apply(.init(source: .system, start: 0, end: 1, text: "原文", isFinal: true))
        try MeetingStore.save(original, in: folder)
        let expected = try FileTranscription.documentData(in: folder)
        var replacement = MeetingDocument(recordingID: id)
        replacement.apply(.init(source: .system, start: 0, end: 2, text: "新转录", isFinal: true))
        try FileTranscription.commit(replacement, in: folder, expected: expected)
        try await checkWorkspaceReload(original: original, replacement: replacement, folder: root.appendingPathComponent("workspace"))
        let backups = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("meeting-backup-") }
        try require(backups.count == 1 && (try Data(contentsOf: backups[0])) == expected, "替换前逐字备份原文")
        do { try FileTranscription.commit(original, in: folder, expected: expected); throw RecorderError.message("FAIL: 已修改转录必须拒绝覆盖") }
        catch { if error.localizedDescription.hasPrefix("FAIL:") { throw error } }
        replacement.threads = [try replacement.makeThread(selection: .init(text: "新转录", segments: replacement.segments), scope: .selection)]
        try MeetingStore.save(replacement, in: folder)
        do { try FileTranscription.commit(original, in: folder, expected: FileTranscription.documentData(in: folder)); throw RecorderError.message("FAIL: 不能替换已有追问的转录") }
        catch { if error.localizedDescription.hasPrefix("FAIL:") { throw error } }
        let record = Recording(title: "合成", source: "test", microphone: true, filename: "mixed.m4a", folderName: "recording")
        try Data().write(to: folder.appendingPathComponent("mixed.m4a"))
        let raw = folder.appendingPathComponent("原始音轨"); try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        try Data().write(to: raw.appendingPathComponent("system.mov"))
        let fallback = try FileTranscription.inputs(recording: record, directory: folder)
        try require(fallback.count == 1 && fallback[0].url.lastPathComponent == "mixed.m4a", "原始双轨缺一轨时回退混合文件")
        try Data().write(to: raw.appendingPathComponent("microphone.mov"))
        let dual = try FileTranscription.inputs(recording: record, directory: folder)
        try require(dual.count == 2 && dual[1].source == .microphone, "优先完整原始双轨")
        print("PASS：Agent 自动发现、子进程 PATH、Whisper 时间戳、模型校验、原文备份与覆盖保护。")
    }
    @MainActor private static func checkWorkspaceReload(original: MeetingDocument, replacement: MeetingDocument, folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try MeetingStore.save(original, in: folder)
        let workspace = MeetingWorkspaceModel()
        let record = Recording(id: original.recordingID, title: "Synthetic", source: "test", microphone: false, folderName: folder.lastPathComponent)
        workspace.open(recording: record, directory: folder)
        workspace.stopAnswer(); workspace.flush()
        try FileTranscription.commit(replacement, in: folder, expected: FileTranscription.documentData(in: folder))
        workspace.open(recording: record, directory: folder, flushCurrent: false)
        let stored = try MeetingStore.load(in: folder, recordingID: record.id)
        try require(stored.segments == replacement.segments && workspace.document?.segments == replacement.segments,
                    "事后转录完成后，旧工作区不得覆盖新落盘的文字")
        workspace.clear()
    }
}
