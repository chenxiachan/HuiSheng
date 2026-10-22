import Foundation
import Darwin

enum QuestionBackend: String, Codable, CaseIterable, Identifiable {
    case api, codex, claude
    var id: String { rawValue }
    var label: String {
        switch self { case .api: return L("OpenAI 兼容 API"); case .codex: return L("本地 Codex CLI"); case .claude: return L("本地 Claude Code") }
    }
    var defaultPath: String {
        ExecutableLocator.locate(rawValue) ?? ""
    }
}

struct LocalCommandInvocation {
    var executable: URL
    var arguments: [String]
    var input: Data
    var output: URL?
    var failureMessage = "本地程序未能完成。请检查安装、模型或登录状态。"
}

enum AgentInvocation {
    static func make(settings: QuestionSettings, messages: [QuestionMessage], directory: URL) throws -> LocalCommandInvocation {
        let path = settings.agentPath.isEmpty ? settings.backend.defaultPath : settings.agentPath
        guard path.hasPrefix("/"), ExecutableLocator.executable(path) else {
            throw RecorderError.message("找不到 Agent 可执行文件。请在问答设置中选择已安装的 CLI，并先在终端完成登录。")
        }
        let prompt = messages.map { "<\($0.role)>\n\($0.content)\n</\($0.role)>" }.joined(separator: "\n\n")
        var args: [String]
        var output: URL?
        switch settings.backend {
        case .api: throw RecorderError.message("请选择本地 Agent。")
        case .codex:
            output = directory.appendingPathComponent("answer.txt")
            args = ["exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "--ignore-user-config", "--ignore-rules",
                    "-c", "features.shell_tool=false", "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0",
                    "-c", "features.memories=false", "-c", "features.plugins=false", "-c", "features.apps=false",
                    "-c", "features.multi_agent=false", "-c", "features.skill_search=false", "-c", "features.skip_host_skill_discovery=true", "--color", "never", "--output-last-message", output!.path]
            if !settings.model.isEmpty { args += ["--model", settings.model] }
            args += ["-"]
        case .claude:
            args = ["--print", "--output-format", "text", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--safe-mode", "--no-session-persistence", "--permission-mode", "dontAsk", "--setting-sources", ""]
            if !settings.model.isEmpty { args += ["--model", settings.model] }
        }
        return LocalCommandInvocation(executable: URL(fileURLWithPath: path), arguments: args, input: Data(prompt.utf8), output: output)
    }
}

// The app launches an executable directly; no prompt or path is interpreted by a shell.
// All process state is protected by the lock. Pipe readers run off the main thread.
final class LocalCommandProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.lock.withLock { if self?.process?.isRunning == true { kill(pid, SIGKILL) } }
                }
            }
        }
    }
    func run(_ invocation: LocalCommandInvocation, directory: URL, diagnostics: ((Data) -> Void)? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
                child.executableURL = invocation.executable; child.arguments = invocation.arguments
                child.currentDirectoryURL = directory
                child.standardInput = input; child.standardOutput = output; child.standardError = errors
                // An incompatible CLI may exit before reading stdin. Never let SIGPIPE kill the recorder.
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                child.environment = ExecutableLocator.environment(for: invocation.executable)
                do {
                    try lock.withLock {
                        if cancelled { throw CancellationError() }
                        process = child; try child.run()
                    }
                } catch { continuation.resume(throwing: error); return }
                let readers = DispatchGroup()
                let capture = BoundedOutput()
                for (pipe, isOutput) in [(output, true), (errors, false)] {
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { readers.leave() }
                        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                            if isOutput { capture.append(chunk) } else { diagnostics?(chunk) }
                            // Drain stderr but never surface diagnostic logs that may contain credentials.
                        }
                    }
                }
                do { try input.fileHandleForWriting.write(contentsOf: invocation.input) } catch { cancel() }
                try? input.fileHandleForWriting.close()
                child.waitUntilExit(); readers.wait()
                let wasCancelled = lock.withLock { let value = cancelled; process = nil; return value }
                if wasCancelled { continuation.resume(throwing: CancellationError()); return }
                guard child.terminationStatus == 0 else {
                    continuation.resume(throwing: RecorderError.message(LF("%@（退出码 %d）", L(invocation.failureMessage), child.terminationStatus))); return
                }
                do {
                    let data = try invocation.output.map { try Data(contentsOf: $0) } ?? capture.data
                    guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw RecorderError.message("本地程序没有返回结果，或输出超过 2 MB。")
                    }
                    continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data { lock.withLock { storage } }
    func append(_ data: Data) { lock.withLock { if storage.count <= 2_000_000 { storage.append(data) } } }
}

final class LocalAgentService {
    func answer(settings: QuestionSettings, messages: [QuestionMessage], onDelta: @escaping (String) async -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HuiSheng-Agent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        await ExecutableLocator.refresh()
        try Task.checkCancellation()
        let invocation = try AgentInvocation.make(settings: settings, messages: messages, directory: directory)
        let process = LocalCommandProcess()
        let watchdog = Task { do { try await Task.sleep(for: .seconds(180)); process.cancel() } catch {} }
        defer { watchdog.cancel() }
        let started = Date()
        do {
            let answer = try await withTaskCancellationHandler {
                try await process.run(invocation, directory: directory)
            } onCancel: { process.cancel() }
            try Task.checkCancellation()
            await onDelta(answer)
        } catch {
            if !Task.isCancelled && Date().timeIntervalSince(started) >= 179 {
                throw RecorderError.message("Agent 超过 180 秒未完成，已停止。可以缩小选段或检查 CLI 状态后重试。")
            }
            throw error
        }
    }
}
