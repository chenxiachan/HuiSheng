import SwiftUI
import AppKit
import Combine

@main
struct HuiShengApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = RecorderModel()
    var body: some Scene {
        WindowGroup("会声") {
            ContentView(model: model)
                .frame(minWidth: 1120, minHeight: 740)
                .preferredColorScheme(.light)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1360, height: 850)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("录音") {
                Button(model.isRecording ? "结束并保存" : "开始录音") {
                    Task { if model.isRecording { await model.stop() } else { await model.start() } }
                }.keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.phase == .starting || model.phase == .saving)
                Button("暂停 / 继续") { model.pauseOrResume() }
                    .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!model.isRecording)
                Button("打开录音文件夹") { model.openFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecorderModel? {
        didSet {
            observation = model?.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { self?.updateStatus() }
            }
            updateStatus()
        }
    }
    private var statusItem: NSStatusItem?
    private var observation: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatus()
        NSApp.activate(ignoringOtherApps: true)
    }
    private func updateStatus() {
        guard let statusItem else { return }
        let recording = model?.isRecording == true
        statusItem.button?.title = recording ? "\(model?.phase == .paused ? "Ⅱ" : "●") \(durationText(model?.elapsed ?? 0))" : ""
        statusItem.button?.image = recording ? nil : NSImage(systemSymbolName: "waveform", accessibilityDescription: "会声")
        statusItem.button?.toolTip = recording ? "会声正在录音，点击管理" : "会声 · 本地会议录音"
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "打开会声", action: #selector(showWindow), keyEquivalent: "")
        open.target = self
        if recording {
            menu.addItem(.separator())
            let pause = menu.addItem(withTitle: model?.phase == .paused ? "继续录音" : "暂停录音", action: #selector(togglePause), keyEquivalent: "")
            pause.target = self
            let stop = menu.addItem(withTitle: "结束并保存", action: #selector(stopRecording), keyEquivalent: "")
            stop.target = self
        }
        statusItem.menu = menu
    }
    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
    @objc private func togglePause() { model?.pauseOrResume() }
    @objc private func stopRecording() { Task { await model?.stop() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.busy else { model.workspace.stopAnswer(); model.workspace.flush(); return .terminateNow }
        let alert = NSAlert()
        alert.messageText = model.isRecording ? "录音尚未保存" : "正在处理录音"
        alert.informativeText = model.isRecording ? "结束并保存当前录音后退出？" : "请等当前操作完成后再退出。"
        if model.isRecording {
            alert.addButton(withTitle: "结束并保存"); alert.addButton(withTitle: "继续录音")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await model.stop(); model.workspace.stopAnswer(); model.workspace.flush(); sender.reply(toApplicationShouldTerminate: true) }
                return .terminateLater
            }
        } else { alert.addButton(withTitle: "继续等待"); alert.runModal() }
        return .terminateCancel
    }
}
