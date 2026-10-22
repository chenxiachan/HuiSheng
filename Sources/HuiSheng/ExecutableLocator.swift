import Foundation
import Darwin

/// Finder launches have a sparse PATH. Like ThoughtDAG/TextFold, search the terminal
/// PATH, common install locations and version managers; pass that PATH to children too.
/// Implemented independently in Swift; no other app's credentials are read or copied.
enum ExecutableLocator {
    private static let lock = NSLock()
    private static var cached: [String] = []
    static var directories: [String] {
        let saved = lock.withLock { cached }
        return saved.isEmpty ? searchDirectories(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory()) : saved
    }
    static func refresh() async {
        let result = await Task.detached(priority: .utility) {
            searchDirectories(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory(), loginPath: loginPath())
        }.value
        lock.withLock { cached = result }
    }
    static func locate(_ name: String, in directories: [String]? = nil) -> String? {
        guard !name.contains("/"), !name.isEmpty else { return nil }
        return (directories ?? self.directories).map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { executable($0) }
    }
    static func executable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
    static func environment(for executable: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let paths = [executable.deletingLastPathComponent().path] + directories
        env["PATH"] = unique(paths).joined(separator: ":")
        for key in ["USER", "LOGNAME"] where env[key]?.isEmpty != false { env[key] = NSUserName() }
        return env
    }
    static func searchDirectories(environment env: [String: String], home: String, loginPath: String = "") -> [String] {
        let fm = FileManager.default
        func versions(_ base: String, _ suffix: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: base)) ?? []).sorted {
                $0.compare($1, options: .numeric) == .orderedDescending
            }.map { base + "/" + $0 + "/" + suffix }
        }
        var paths = (env["PATH"] ?? "").components(separatedBy: ":") + loginPath.components(separatedBy: ":")
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", home + "/.local/bin", home + "/.claude/local", home + "/.codex/bin", home + "/.bun/bin", home + "/.npm-global/bin"]
        paths += versions((env["NVM_DIR"] ?? home + "/.nvm") + "/versions/node", "bin")
        for base in [env["FNM_DIR"], home + "/.fnm", home + "/.local/share/fnm", home + "/Library/Application Support/fnm"].compactMap({ $0 }) {
            paths += [base + "/aliases/default/bin"] + versions(base + "/node-versions", "installation/bin")
        }
        paths += [".volta/bin", "n/bin", ".nodenv/shims", ".asdf/shims", ".local/share/mise/shims", ".proto/shims", "Library/pnpm", ".local/share/pnpm", ".yarn/bin", ".config/yarn/global/node_modules/.bin", ".deno/bin", ".cargo/bin", "bin"].map { home + "/" + $0 }
        if let prefix = env["N_PREFIX"] { paths.append(prefix + "/bin") }
        return unique(paths).filter { path in
            var directory: ObjCBool = false
            return path.hasPrefix("/") && fm.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
    }
    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private static func loginPath() -> String {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"].flatMap { executable($0) ? $0 : nil } ?? "/bin/zsh"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HuiSheng-Path-" + UUID().uuidString)
        let file = directory.appendingPathComponent("path")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: file); defer { try? output.close() }
            let process = Process(); process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = shell.hasSuffix("fish") ? ["-l", "-c", "string join : $PATH"] : ["-ilc", "printf '%s' \"$PATH\""]
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = output
            var environment = env; environment["TERM"] = "dumb"; process.environment = environment
            try process.run()
            let deadline = Date().addingTimeInterval(4)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.1); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            let data = try input.read(upToCount: 65_536) ?? Data()
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        } catch { return "" }
    }
}
