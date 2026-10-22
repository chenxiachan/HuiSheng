import SwiftUI

private let ink = Color(red: 0.10, green: 0.18, blue: 0.17)
private let accent = Color(red: 0.10, green: 0.40, blue: 0.33)
private let muted = Color(red: 0.47, green: 0.51, blue: 0.49)
private let paper = Color(red: 0.965, green: 0.969, blue: 0.953)
private let line = Color(red: 0.89, green: 0.91, blue: 0.88)

struct ContentView: View {
    @ObservedObject var model: RecorderModel
    @State private var tab = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(line).frame(width: 1)
            if tab == 3 {
                MeetingWorkspaceView(workspace: model.workspace, recorder: model)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if tab == 0 {
                        recorder
                        permissions
                        library(limit: 3)
                    } else if tab == 1 {
                        library(limit: nil)
                    } else { settings }
                }.padding(32)
            }.background(paper)
            }
        }
        .foregroundStyle(ink)
        .font(.system(size: 13))
        .tint(accent)
        .onChange(of: model.phase) { _, phase in if phase == .recording && model.useTranscription { tab = 3 } }
        .alert("会声", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("知道了") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(accent).frame(width: 42, height: 42)
                    Image(systemName: "waveform").font(.system(size: 23, weight: .medium)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("会声").font(.system(size: 23, weight: .semibold))
                    Text("留住每一次交流").font(.system(size: 10)).foregroundStyle(muted)
                }
            }.padding(.top, 38).padding(.bottom, 42)

            navigation("开始录音", symbol: "waveform.circle", index: 0)
            navigation("转录与追问", symbol: "text.bubble", index: 3)
            navigation("我的录音", symbol: "square.stack", index: 1)
            navigation("录音设置", symbol: "slider.horizontal.3", index: 2)

            VStack(alignment: .leading, spacing: 14) {
                Text("适用于你的会议工具").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                platform("腾讯会议", symbol: "video.fill", color: Color(red: 0.20, green: 0.49, blue: 0.85))
                platform("Microsoft Teams", symbol: "person.2.fill", color: Color(red: 0.40, green: 0.37, blue: 0.69))
                platform("Zoom", symbol: "video.fill", color: Color(red: 0.25, green: 0.49, blue: 0.95))
                Text("以及浏览器中的在线会议").font(.system(size: 10)).foregroundStyle(muted)
            }.padding(.horizontal, 12).padding(.top, 38)

            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 9) {
                Label("只在本机保存", systemImage: "internaldrive").font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                Text("录音和转录留在本机。\n追问可接 API 或本地 Agent。")
                    .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            Text("会声  /  会议录音与追问  v0.2").font(.system(size: 9)).foregroundStyle(muted).padding(.top, 17)
        }.padding(.horizontal, 18).padding(.bottom, 22).frame(width: 210).background(Color.white.opacity(0.72))
    }

    private func navigation(_ title: String, symbol: String, index: Int) -> some View {
        Button { tab = index } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 17)).frame(width: 22)
                Text(title).fontWeight(tab == index ? .semibold : .regular)
                Spacer()
                if index == 1 { Text("\(model.recordings.count)").font(.system(size: 11)).foregroundStyle(muted) }
            }.padding(.horizontal, 13).padding(.vertical, 13)
                .foregroundStyle(tab == index ? accent : muted)
                .background(tab == index ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).padding(.bottom, 5)
    }

    private func platform(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color)
                .frame(width: 23, height: 23).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            Text(title).font(.system(size: 11)).foregroundStyle(ink.opacity(0.75))
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tab == 0 ? "专注交流，让会声记录。" : tab == 1 ? "每一段交流，都在这里。" : "按你的习惯录音。")
                    .font(.system(size: 27, weight: .semibold))
                Text(tab == 0 ? "会议声音与麦克风，一起保存到你的 Mac。" : tab == 1 ? "本地录音 · 随时回听 · 自由分享文件" : "保存位置、音频权限与使用说明。")
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            Label("本地运行", systemImage: "checkmark.shield")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(accent.opacity(0.07), in: Capsule()).padding(.top, 5)
        }.padding(.top, 12)
    }

    private var recorder: some View {
        VStack(spacing: 0) {
            HStack {
                Label("新建会议录音", systemImage: "waveform").font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.phase == .recording ? Color.red.opacity(0.8) : model.phase == .paused ? .orange : accent.opacity(0.6)).frame(width: 6, height: 6)
                    Text(stateText).font(.system(size: 11)).foregroundStyle(muted)
                }
            }.padding(.horizontal, 23).padding(.vertical, 17)
            Rectangle().fill(line).frame(height: 1)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("会议名称", trailing: "可选")
                        TextField("例如：每周项目讨论", text: $model.title)
                            .textFieldStyle(.plain).padding(12)
                            .background(paper, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(line))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("录制声音来源")
                        Picker("声音来源", selection: $model.sourceID) {
                            Text("全部系统声音 · 推荐").tag("all")
                            ForEach(model.sources) { source in Text(source.name).tag(source.id) }
                        }.labelsHidden().controlSize(.large).frame(maxWidth: .infinity)
                        Text(model.sourceID == "all" ? "包含会议、浏览器和通知声音。" : "仅录制所选应用的声音；网页会议请选择浏览器。")
                            .font(.system(size: 10)).foregroundStyle(muted)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: model.useMicrophone ? "mic" : "mic.slash").font(.system(size: 17)).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("录入我的声音").font(.system(size: 12, weight: .medium))
                            Text("使用系统默认麦克风").font(.system(size: 10)).foregroundStyle(muted)
                        }
                        Spacer()
                        Toggle("录入我的声音", isOn: $model.useMicrophone).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    TranscriptionOptionsView(model: model, workspace: model.workspace)
                }.frame(maxWidth: .infinity).disabled(model.busy)
                Rectangle().fill(line).frame(width: 1, height: 238)
                VStack(spacing: 14) {
                    Text(durationText(model.elapsed)).font(.system(size: 40, weight: .light, design: .monospaced)).tracking(-2)
                        .contentTransition(.numericText()).padding(.top, 8)
                    LevelBars(system: model.systemLevel, microphone: model.micLevel, active: model.phase == .recording)
                        .frame(height: 42).padding(.horizontal, 2)
                    HStack(spacing: 14) {
                        meterLegend("会议声音", value: model.systemLevel, color: accent)
                        meterLegend("麦克风", value: model.micLevel, color: Color(red: 0.70, green: 0.55, blue: 0.32))
                    }
                    controls.padding(.top, 6)
                    if model.phase == .starting { Button("取消准备") { model.cancelStart() }.font(.caption) }
                    Text(model.isRecording ? (model.phase == .paused ? "已暂停，点击继续恢复录音" : "正在写入本地音轨") : "⌘ ⇧ R  开始 / 结束录音")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }.frame(width: 265)
            }.padding(23)
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(muted)
                Text(model.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).foregroundStyle(muted)
                Spacer()
                Button("更改") { model.chooseFolder() }.buttonStyle(.plain).foregroundStyle(accent).disabled(model.busy)
                Text("·").foregroundStyle(muted)
                Text("M4A 音频").foregroundStyle(muted)
            }.font(.system(size: 10)).padding(.horizontal, 23).padding(.vertical, 13).background(paper.opacity(0.7))
        }.background(.white, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(line))
    }

    private var controls: some View {
        HStack(spacing: 9) {
            if model.isRecording {
                Button { model.pauseOrResume() } label: {
                    Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill").frame(width: 42, height: 43)
                        .background(paper, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).help(model.phase == .paused ? "继续录音" : "暂停录音")
                Button { Task { await model.stop() } } label: {
                    Label("结束并保存", systemImage: "stop.fill").font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 43).foregroundStyle(.white)
                        .background(accent, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            } else {
                Button { Task { await model.start() } } label: {
                    HStack(spacing: 9) {
                        if model.busy { ProgressView().controlSize(.small).tint(.white) }
                        else { Circle().fill(.white).frame(width: 10, height: 10) }
                        Text(model.phase == .saving ? "正在保存…" : model.phase == .starting ? "正在准备…" : "开始录音")
                    }.font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 43)
                        .foregroundStyle(.white).background(accent, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(model.busy)
            }
        }
    }

    private var permissions: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: model.screenAllowed && (!model.useMicrophone || model.micAllowed) ? "checkmark.circle" : "info.circle")
                .font(.system(size: 16)).foregroundStyle(accent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.screenAllowed && (!model.useMicrophone || model.micAllowed) ? "音频权限已准备" : "首次使用，需要允许录音权限")
                    .font(.system(size: 11, weight: .medium))
                Text("系统声音需要「屏幕与系统音频录制」权限；本版本只保存音频。建议佩戴耳机，避免扬声器回声。")
                    .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                Text("开始前，请告知参会者。会议软件静音不会关闭这里的麦克风。")
                    .font(.system(size: 10)).foregroundStyle(muted)
            }
            Spacer(minLength: 0)
            Button("权限设置 ↗") { tab = 2 }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(accent).padding(.top, 2)
        }.padding(.horizontal, 3)
    }

    private func library(limit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(limit == nil ? "我的录音" : "最近录音").font(.system(size: 16, weight: .semibold))
                Text("\(model.recordings.count)").font(.system(size: 10)).foregroundStyle(muted).padding(.horizontal, 6).padding(.vertical, 3).background(line.opacity(0.5), in: Capsule())
                Spacer()
                if limit != nil { Button("查看全部 →") { tab = 1 }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 11)) }
                else { Button { model.openFolder() } label: { Label("打开文件夹", systemImage: "folder") }.buttonStyle(.plain).foregroundStyle(accent) }
            }
            if limit == nil {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(muted); TextField("搜索会议名称或声音来源", text: $model.search).textFieldStyle(.plain) }
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
            let records = limit.map { Array(model.filteredRecordings.prefix($0)) } ?? model.filteredRecordings
            if records.isEmpty {
                HStack(spacing: 17) {
                    Image(systemName: "waveform.path").font(.system(size: 28, weight: .light)).foregroundStyle(accent.opacity(0.45))
                        .frame(width: 54, height: 54).background(accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.search.isEmpty ? "你的第一段录音，从这里开始" : "没有匹配的录音").font(.system(size: 12, weight: .medium))
                        Text(model.search.isEmpty ? "结束录制后，录音会自动出现在这里。" : "试试其他会议名称。")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Spacer()
                }.padding(23).frame(maxWidth: .infinity)
                    .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            } else {
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        recordingRow(record)
                        if record.id != records.last?.id { Divider().padding(.leading, 64) }
                    }
                }.background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(line))
            }
        }
    }

    private func recordingRow(_ record: Recording) -> some View {
        HStack(spacing: 14) {
            Button { model.play(record) } label: {
                Image(systemName: model.playingID == record.id ? "stop.fill" : "play.fill").font(.system(size: 13))
                    .foregroundStyle(accent).frame(width: 38, height: 38).background(accent.opacity(0.07), in: Circle())
            }.buttonStyle(.plain).disabled(record.filename == nil || model.busy).help("播放 / 停止")
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(record.date.formatted(date: .abbreviated, time: .shortened))  ·  \(record.source)")
                    .font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
            }
            Spacer()
            if record.status == "interrupted" {
                Button("恢复导出") { Task { await model.recover(record) } }.font(.system(size: 10)).disabled(model.busy)
            } else { Text(durationText(record.duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(muted) }
            Button("查看文字") { model.openTranscript(record); tab = 3 }.font(.system(size: 10)).disabled(model.busy)
            Button { model.reveal(record) } label: { Image(systemName: "folder").foregroundStyle(muted) }.buttonStyle(.plain).help("在访达中显示")
        }.padding(15)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text("保存位置").font(.system(size: 15, weight: .semibold))
                Text(model.folder.path).font(.system(size: 12)).foregroundStyle(muted).textSelection(.enabled)
                HStack {
                    Button("选择文件夹…") { model.chooseFolder() }.disabled(model.busy)
                    Button("在访达中打开") { model.openFolder() }
                }
                Text("每场会议独立保存，包含 M4A 录音与原始音轨。更换位置后，列表显示新文件夹中的录音。")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }.padding(23).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 18) {
                Text("系统权限").font(.system(size: 15, weight: .semibold))
                permissionRow("屏幕与系统音频录制", detail: "用于获取会议声音；不会保存屏幕画面。", granted: model.screenAllowed, mic: false)
                Divider()
                permissionRow("麦克风", detail: "用于录入你的声音，可在录音前关闭。", granted: model.micAllowed, mic: true)
            }.padding(23).background(.white, in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 12) {
                Text("录音小提示").font(.system(size: 15, weight: .semibold))
                tip("headphones", "建议佩戴耳机，避免对方声音被麦克风重复录入。")
                tip("speaker.wave.2", "会议应用需要实际播放声音。应用专属模式没有声音时，可改用全部系统声音。")
                tip("mic", "会议软件里的静音与会声独立；会声会持续录制启用的麦克风。")
                tip("laptopcomputer", "录制期间保持 Mac 开盖；更换音频设备后请检查两个音量指示。")
                tip("person.2", "录音前告知参会者。此工具不会向会议中发送录制通知。")
            }.padding(23).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool, mic: Bool) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(granted ? accent : muted)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(muted)
            }
            Spacer()
            Button(granted ? "查看设置" : "前往开启") { model.openPermissionSettings(microphone: mic) }
        }
    }
    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(accent)
            Text(text).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
    private func fieldLabel(_ text: String, trailing: String = "") -> some View {
        HStack { Text(text).font(.system(size: 11, weight: .medium)); Spacer(); Text(trailing).font(.system(size: 10)).foregroundStyle(muted) }
    }
    private func meterLegend(_ text: String, value: Float, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(value > 0.12 ? color : line).frame(width: 5, height: 5); Text(text).font(.system(size: 10)).foregroundStyle(muted) }
    }
    private var stateText: String {
        switch model.phase { case .idle: return "准备就绪"; case .starting: return "正在准备"; case .recording: return "录音中"; case .paused: return "已暂停"; case .saving: return "正在保存" }
    }
}

private struct LevelBars: View {
    var system: Float
    var microphone: Float
    var active: Bool
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<36) { index in
                    let level = index < 18 ? system : microphone
                    let envelope = 0.30 + 0.70 * abs(sin(Double(index) * 0.79))
                    Capsule().fill(active && level > 0.05 ? accent.opacity(index < 18 ? 0.8 : 0.45) : line)
                        .frame(width: max(2, (geometry.size.width - 140) / 36), height: 4 + (active ? CGFloat(level) * envelope * 37 : 0))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).animation(.easeOut(duration: 0.12), value: system)
        }.accessibilityLabel("会议声音 \(Int(system * 100))，麦克风 \(Int(microphone * 100))")
    }
}
