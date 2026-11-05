import Foundation

enum SummaryTests {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw RecorderError.message("FAIL: " + message) }
    }
    static let content = MeetingSummaryContent(title: "客户端测试安排", overview: "讨论客户端交付及待确认预算。", topics: ["客户端测试"],
        decisions: ["先做 Mac 版"], actions: ["小李周五完成登录页"], questions: ["预算未定"])
    static func run() async throws {
        let text = String(repeating: "这是一场中文会议，讨论录音测试和交付时间。 English 👩🏽‍💻。\n", count: 1500) + "尾部决定保留"
        let parts = SummaryPrompt.chunks(text)
        try require(parts.count > 1 && parts.joined() == text && parts.allSatisfy { $0.utf8.count <= SummaryPrompt.byteLimit }, "长会议分段保留全部文字及 Unicode")
        var document = MeetingDocument(recordingID: UUID())
        document.apply(.init(source: .system, start: 0, end: 10, text: text, isFinal: true))
        let calls = SummaryCalls()
        let json = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
        let service = LocalSummaryService(generate: { instructions, data, kind in
            try require(instructions.contains("untrusted DATA"), "模型提示必须将转录作为数据")
            await calls.add(data)
            if kind == .notes { return data.contains("尾部决定保留") ? "尾部决定保留" : "讨论要点" }
            try require(data.contains("尾部决定保留"), "最终汇总必须覆盖会议末尾")
            return json
        }, unavailableReason: { nil })
        let summary = try await service.summarize(document, language: "zh-Hans", incomplete: false)
        try require(summary.chunks > 1 && summary.isCurrent(for: document), "多段总结关联原始转录")
        try require(summary.markdown.contains("## 待办事项") && !summary.transcriptIncomplete, "总结导出包含结构与完整性状态")
        let requests = await calls.values
        try require(requests.allSatisfy { $0.utf8.count <= SummaryPrompt.byteLimit }, "每次模型请求都控制上下文大小")
        let retry = LocalSummaryService(generate: { _, data, kind in
            if data.utf8.count > 2500 { throw SummaryModelError.contextLimit }
            if kind == .notes { return data.contains("尾部决定保留") ? "尾部决定保留" : "讨论要点" }
            try require(data.contains("尾部决定保留"), "容量重试也保留末尾内容")
            return json
        }, unavailableReason: { nil })
        let retried = try await retry.summarize(document, language: "zh-Hans", incomplete: false)
        try require(retried.chunks > summary.chunks, "超出模型容量时自动缩小分段重试")
        var englishDocument = MeetingDocument(recordingID: UUID())
        englishDocument.apply(.init(source: .system, start: 0, end: 10, text: "We agreed to release the application next week. Alice will test the recording on Friday. The budget is still undecided.", isFinal: true))
        let englishService = LocalSummaryService(generate: { instructions, _, _ in
            try require(instructions.contains("Output in English"), "英文会议自动使用英文总结")
            return json
        }, unavailableReason: { nil })
        let detected = try await englishService.summarize(englishDocument, language: "zh-Hans", incomplete: false)
        try require(detected.language == "en", "总结语言由原文自动检测")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HuiSheng-Summary-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try MeetingStore.save(document, in: root)
        try MeetingSummaryStore.save(summary, in: root)
        let before = try Data(contentsOf: root.appendingPathComponent("summary.json"))
        document.threads = [try document.makeThread(selection: .init(text: "中文", segments: [document.segments[0]]), scope: .selection)]
        try require(summary.isCurrent(for: document), "新增追问不会使总结失效")
        try MeetingStore.save(document, in: root)
        let persisted = try MeetingSummaryStore.load(in: root, recordingID: document.recordingID)
        try require(persisted == summary, "总结可重新打开")
        document.apply(.init(source: .system, start: 11, end: 12, text: "后来修改", isFinal: true))
        try MeetingStore.save(document, in: root)
        do { try MeetingSummaryStore.save(summary, in: root); throw RecorderError.message("FAIL: 不得保存过时总结") }
        catch { if error.localizedDescription.hasPrefix("FAIL:") { throw error } }
        try require(try Data(contentsOf: root.appendingPathComponent("summary.json")) == before, "失败不覆盖已有总结")
        var record = Recording(id: summary.recordingID, title: "未命名会议", source: "synthetic", microphone: false, status: "ready", filename: "audio.m4a", folderName: root.lastPathComponent)
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("session.json"))
        let renamed = try MeetingSummaryStore.updateTitle(for: record, summary: summary, in: root)
        try require(renamed.title == content.title && renamed.filename == "audio.m4a" && renamed.folderName == record.folderName, "自动命名保持音频路径与录音 ID")
        record.title = "我手动起的名"; record.titleOrigin = "manual"
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("session.json"))
        let manual = try MeetingSummaryStore.updateTitle(for: record, summary: summary, in: root)
        try require(manual.title == record.title, "保留手动名称")
        try await checkJobs(root: root)
        print("PASS：总结分段覆盖、上下文限额、保存与过期保护、标题兼容、后台队列、取消和会议隔离。")
    }
    @MainActor private static func checkJobs(root: URL) async throws {
        let json = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
        let service = LocalSummaryService(generate: { _, _, _ in try await Task.sleep(for: .milliseconds(220)); return json }, unavailableReason: { nil })
        let model = RecorderModel(summaryService: service, recordingFolder: root)
        func create(_ name: String) throws -> (Recording, URL) {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = Recording(title: name, source: "synthetic", microphone: false, status: "ready", filename: "audio.m4a", folderName: name, titleOrigin: "placeholder")
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("session.json"))
            var doc = MeetingDocument(recordingID: record.id)
            doc.apply(.init(source: .system, start: 0, end: 5, text: "讨论 Mac 客户端，小李周五完成登录页。", isFinal: true))
            try MeetingStore.save(doc, in: directory)
            return (record, directory)
        }
        let (a, dirA) = try create("A"), (b, dirB) = try create("B")
        model.workspace.open(recording: b, directory: dirB)
        model.enqueueSummary(a, directory: dirA, incomplete: false)
        model.enqueueSummary(b, directory: dirB, incomplete: true)
        try require(!model.busy && model.hasSummaryWork, "总结在后台运行，不阻止下一次录音")
        for _ in 0..<100 where model.hasSummaryWork { try await Task.sleep(for: .milliseconds(30)) }
        try require(!model.hasSummaryWork && model.summaryJobs[a.id]?.error == nil && model.summaryJobs[b.id]?.error == nil, "依次完成两个会议")
        let savedA = try MeetingSummaryStore.load(in: dirA, recordingID: a.id), savedB = try MeetingSummaryStore.load(in: dirB, recordingID: b.id)
        try require(savedA?.recordingID == a.id && savedB?.recordingID == b.id && savedB?.transcriptIncomplete == true, "总结分别保存到自己的会议")
        try require(model.workspace.document?.recordingID == b.id && model.workspace.summary?.recordingID == b.id, "旧任务不能切换当前工作区")
        let existing = try Data(contentsOf: dirB.appendingPathComponent("summary.json"))
        model.enqueueSummary(b, directory: dirB, incomplete: false)
        try await Task.sleep(for: .milliseconds(50)); model.cancelSummary(b.id)
        for _ in 0..<100 where model.hasSummaryWork { try await Task.sleep(for: .milliseconds(20)) }
        try require(model.summaryJobs[b.id]?.error != nil && !model.hasSummaryWork, "取消结束后台任务")
        try require(try Data(contentsOf: dirB.appendingPathComponent("summary.json")) == existing, "取消保留已有总结")
        model.workspace.clear()
    }
}
private actor SummaryCalls {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
