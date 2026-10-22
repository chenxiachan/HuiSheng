import Foundation
import AppKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw RecorderError.message("FAIL: " + message) }
}
private func expectFailure(_ message: String, _ work: () throws -> Void) throws {
    do { try work() } catch { return }
    throw RecorderError.message("FAIL: " + message)
}

struct FeatureTests {
    @MainActor private func testLanguageSwitch() throws {
        let original = AppSettings.shared.language
        defer { AppSettings.shared.language = original }
        let segment = TranscriptSegment(source: .system, start: 1, end: 2, text: "报告 Friday 👩🏽‍💻 保留原文", isFinal: false)
        let document = MeetingDocument(recordingID: UUID(), segments: [segment])
        let zh = TranscriptLayout(segments: [segment])
        let range = (zh.text.string as NSString).range(of: "Friday 👩🏽‍💻")
        let selected = zh.selection(in: range)!
        let thread = try document.makeThread(selection: selected, scope: .selection)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(thread)
        AppSettings.shared.language = .english
        try expect(AppLanguage.current == .english && L("开始录音") == "Start recording", "界面语言即时切换并持久保存")
        try expect(LF("已选 %d 字 · %@", 12, "00:00:01") == "12 characters · 00:00:01", "动态英文文案保留参数")
        try expect(localizedScope(thread.scope) == "Selected text only · Includes draft text", "旧版追问范围显示英文而不改写快照")
        let en = TranscriptLayout(segments: [segment])
        let englishRange = (en.text.string as NSString).range(of: "Friday 👩🏽‍💻")
        try expect(en.selection(in: englishRange) == selected, "语言改变元数据长度后仍能准确圈选 UTF-16 原文")
        let after = try encoder.encode(thread)
        try expect(before == after && en.text.string.contains("Meeting audio"), "语言切换不修改会议或引用")
        try expect(RecorderError.message("无法播放这份录音。").localizedDescription == "Cannot play this recording.", "错误提示遵循界面语言")
        AppSettings.shared.language = .chinese
        try expect(L("开始录音") == "开始录音" && localizedScope(thread.scope) == thread.scope, "支持切回中文")
        print("PASS：语言切换、持久化、旧版范围显示、跨语言原文圈选。")
    }
    func run() async throws {
        try await testLanguageSwitch()
        var document = MeetingDocument(recordingID: UUID())
        document.apply(.init(source: .system, start: 0, end: 2, text: "初稿", isFinal: false))
        let id = document.segments[0].id
        document.apply(.init(source: .system, start: 0, end: 2, text: "机密前文。星期五交付报告。机密后文。", isFinal: true))
        document.apply(.init(source: .system, start: 0, end: 2, text: "迟到的初稿", isFinal: false))
        try expect(document.segments.count == 1 && document.segments[0].id == id && document.segments[0].isFinal, "定稿必须保留 ID 并拒绝迟到初稿")
        for i in 1...6 { document.apply(.init(source: .system, start: Double(i * 3), end: Double(i * 3 + 2), text: "其他材料\(i)", isFinal: true)) }
        var live = MeetingDocument(recordingID: UUID())
        live.apply(.init(source: .microphone, start: 0, end: 5, text: "实时初稿", isFinal: false))
        let liveSelection = TranscriptSelection(text: "初稿", segments: live.segments)
        let liveThread = try live.makeThread(selection: liveSelection, scope: .selection)
        live.apply(.init(source: .microphone, start: 0, end: 5, text: "修改后的定稿", isFinal: true))
        try expect(liveThread.scope.contains("未定稿") && liveThread.quote == "初稿", "识别中选区需标记且保留原快照")
        try expect(liveThread.evidence[0].id == live.segments[0].id, "定稿后原引用仍可定位")
        let selection = TranscriptSelection(text: "星期五交付报告", segments: [document.segments[0]])
        var thread = try document.makeThread(selection: selection, scope: .selection)
        let messages = try QuestionPrompt.messages(thread: thread, question: "什么时候交付？")
        let sent = messages.map(\.content).joined()
        try expect(sent.contains("星期五") && !sent.contains("机密") && !sent.contains("其他材料"), "仅选中文字不得泄漏未选材料")
        let nearby = try document.makeThread(selection: selection, scope: .nearby)
        try expect(nearby.evidence.count == 3, "附近上下文只取两段")
        let all = try document.makeThread(selection: selection, scope: .meeting)
        try expect(all.evidence.count == 7, "整场范围需显式加入")
        document.apply(.init(source: .system, start: 30, end: 32, text: "后来新增内容", isFinal: true))
        try expect(all.evidence.count == 7, "新转录不可自动扩展旧线程")
        thread.turns = [ChatTurn(question: "失败问题", answer: "失败回答", status: "failed"), ChatTurn(question: "完成问题", answer: "完成回答", status: "complete")]
        let history = try QuestionPrompt.messages(thread: thread, question: "继续") .map(\.content).joined()
        try expect(!history.contains("失败回答") && history.contains("完成回答"), "只带入已完成历史")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        thread.turns.append(ChatTurn(question: "中断问题")); document.threads = [thread]
        try MeetingStore.save(document, in: folder)
        let reopened = try MeetingStore.load(in: folder, recordingID: document.recordingID)
        try expect(reopened.threads[0].turns.last?.status == "cancelled", "重启后 pending 必须成为 cancelled")
        try expectFailure("拒绝其他会议 ID") { _ = try MeetingStore.load(in: folder, recordingID: UUID()) }
        let layout = TranscriptLayout(segments: document.segments)
        let ns = layout.text.string as NSString
        let selected = layout.selection(in: ns.range(of: "星期五交付报告"))
        try expect(selected?.text == "星期五交付报告", "原生 UTF-16 选区必须提取原字")
        let cross = layout.selection(in: NSRange(location: layout.spans[0].range.location, length: NSMaxRange(layout.spans[1].range) - layout.spans[0].range.location))
        try expect(cross?.segments.count == 2 && !(cross?.text.contains("会议声音") ?? true), "跨段选择不包含元数据")
        var sse = SSEDecoder()
        try expect(sse.consume(line: ": heartbeat") == nil, "SSE 心跳")
        _ = sse.consume(line: "data: 一"); _ = sse.consume(line: "data: 二")
        try expect(sse.consume(line: "") == "一\n二", "SSE 多行")
        var settings = QuestionSettings()
        for bad in ["http://example.com/v1", "https://user:pass@example.com/v1", "https://example.com/v1?key=secret"] {
            settings.baseURL = bad; try expectFailure("拒绝非安全地址") { _ = try settings.endpoint("chat/completions") }
        }
        settings.baseURL = "http://127.0.0.1:11434/v1"; _ = try settings.endpoint("chat/completions")
        print("PASS: 选区、范围快照、多轮上下文、原子存储、引用定位、SSE 和地址校验")
        if let base = ProcessInfo.processInfo.environment["HUISHENG_MOCK_API"] {
            try await network(base: base, messages: messages)
            try await workspaceState(base: base, folder: folder)
        }
        try await agent(folder: folder, messages: messages)
    }
    func network(base: String, messages: [QuestionMessage]) async throws {
        var settings = QuestionSettings(); settings.baseURL = base; settings.model = "success"
        let service = QuestionService(); let output = Output()
        try await service.answer(settings: settings, key: "test-only-key", messages: messages) { await output.add($0) }
        let answer = await output.text
        try expect(answer == "星期五交付。[[1]]", "流式中文内容应完整，实际=\(answer)")
        for mode in ["unauthorized", "incomplete", "redirect", "length", "server-error"] {
            settings.model = mode
            var failed = false
            do { try await service.answer(settings: settings, key: "test-only-key", messages: messages) { _ in } } catch { failed = true }
            try expect(failed, "接口异常必须报错：" + mode)
        }
        settings.model = "slow"
        let snapshot = settings
        let pending = Task { try await service.answer(settings: snapshot, key: "", messages: messages) { _ in } }
        try await Task.sleep(for: .milliseconds(150)); pending.cancel()
        var cancelled = false
        do { try await pending.value } catch { cancelled = true }
        try expect(cancelled, "取消网络请求")
        print("PASS: 真 HTTP/SSE 中文流、未选内容隔离、401、断流、重定向、输出上限、服务错误、取消")
    }
    @MainActor
    func workspaceState(base: String, folder: URL) async throws {
        let model = MeetingWorkspaceModel()
        let recording = Recording(title: "合成验证", source: "system", microphone: false, folderName: folder.lastPathComponent)
        model.begin(recording: recording, directory: folder)
        model.receive(.init(source: .system, start: 0, end: 2, text: "星期五交付报告", isFinal: true), recordingID: recording.id)
        let selected = model.confirmed[0]
        model.selection = TranscriptSelection(text: selected.text, segments: [selected]); model.newThread()
        model.settings.baseURL = base; model.settings.model = "slow"; model.question = "第一次"; model.send()
        try await Task.sleep(for: .milliseconds(120)); model.stopAnswer()
        model.settings.model = "success"; model.question = "第二次"; model.send()
        for _ in 0..<80 { if !model.generating { break }; try await Task.sleep(for: .milliseconds(50)) }
        try expect(!model.generating, "第二次请求应完成")
        try expect(model.activeThread?.turns.map(\.status) == ["cancelled", "complete"], "旧请求取消不能覆盖新回答")
        try expect(model.activeThread?.turns.last?.answer == "星期五交付。[[1]]", "新回答应完整")
        model.flush()
        let reopened = try MeetingStore.load(in: folder, recordingID: recording.id)
        try expect(reopened.threads[0].turns.count == 2, "问答状态必须保存")
        print("PASS: 取消后立即重试、过期回答隔离、问答状态落盘")
    }
    func agent(folder: URL, messages: [QuestionMessage]) async throws {
        let script = folder.appendingPathComponent("mock-agent")
        try "#!/usr/bin/python3\nimport sys\ns=sys.stdin.read()\nassert '星期五' in s and '机密' not in s\nassert '--tools' in sys.argv and '--no-session-persistence' in sys.argv\nprint('本地 Agent 测试回答。[[1]]')\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var settings = QuestionSettings(); settings.backend = .claude; settings.agentPath = script.path
        let output = Output()
        try await LocalAgentService().answer(settings: settings, messages: messages) { await output.add($0) }
        let answer = await output.text
        try expect(answer == "本地 Agent 测试回答。[[1]]", "本地进程 stdin/stdout")
        try "#!/usr/bin/python3\nimport sys,pathlib\ns=sys.stdin.read()\nassert '--ignore-user-config' in sys.argv and 'features.plugins=false' in sys.argv\nassert '星期五' in s and '机密' not in s\np=pathlib.Path(sys.argv[sys.argv.index('--output-last-message')+1])\np.write_text('Codex 模拟回答。[[1]]')\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        settings.backend = .codex
        let codexOutput = Output()
        try await LocalAgentService().answer(settings: settings, messages: messages) { await codexOutput.add($0) }
        let codexAnswer = await codexOutput.text
        try expect(codexAnswer == "Codex 模拟回答。[[1]]", "Codex 最终消息文件读取")
        settings.backend = .claude
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let snapshot = settings
        let pending = Task { try await LocalAgentService().answer(settings: snapshot, messages: messages) { _ in } }
        try await Task.sleep(for: .milliseconds(150)); let start = Date(); pending.cancel()
        var cancelled = false
        do { try await pending.value } catch { cancelled = true }
        try expect(cancelled && Date().timeIntervalSince(start) < 5, "Agent 停止必须及时返回")
        try "#!/bin/sh\nexit 2\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var rejected = false
        do { try await LocalAgentService().answer(settings: settings, messages: [QuestionMessage(role: "user", content: String(repeating: "早退测试", count: 20_000))]) { _ in } } catch { rejected = true }
        try expect(rejected, "CLI 早退应返回错误而不是 SIGPIPE 结束应用")
        print("PASS: 本地 Agent 标准输入隔离、完整输出、取消终止、早退错误（模拟 CLI）")
    }
}
private actor Output {
    var text = ""
    func add(_ value: String) { text += value }
}
