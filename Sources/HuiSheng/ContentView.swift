import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject private var language = AppSettings.shared
    @State private var tab = 0
    @State private var showQuestionSettings = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if tab == 3 {
                MeetingWorkspaceView(workspace: model.workspace, recorder: model)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Text(L(tab == 0 ? "录音" : tab == 1 ? "我的录音" : "设置"))
                            .font(.system(size: 28, weight: .semibold))
                        if tab == 0 {
                            recorder
                            if !model.screenAllowed || (model.useMicrophone && !model.micAllowed) {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                                    Text(L("录音需要系统音频与麦克风权限。")).foregroundStyle(.secondary)
                                    Spacer()
                                    Button(L("设置权限")) { tab = 2 }
                                }.font(.system(size: 14))
                            }
                            if !model.recordings.isEmpty { library(limit: 3) }
                        } else if tab == 1 { library(limit: nil) }
                        else { settings }
                    }.frame(maxWidth: 1000, alignment: .leading).padding(32).frame(maxWidth: .infinity)
                }.background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .font(.system(size: 16))
        .environment(\.locale, language.language.locale)
        .onChange(of: model.phase) { _, phase in if phase == .recording && model.useTranscription { tab = 3 } }
        .onChange(of: model.transcriptOpened) { _, _ in tab = 3 }
        .sheet(item: $model.pendingTranscription) { record in FileTranscriptionView(model: model, recording: record) }
        .alert(L("会声"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(L("好")) { model.message = nil }
        } message: { Text(L(model.message ?? "")) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("会声")).font(.system(size: 22, weight: .semibold)).padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 20)
            navigation("录音", symbol: "waveform", index: 0)
            navigation("转录与追问", symbol: "text.bubble", index: 3)
            navigation("我的录音", symbol: "folder", index: 1)
            navigation("设置", symbol: "gearshape", index: 2)
            Spacer()
            Picker(L("界面语言"), selection: $language.language) {
                Text("中文").tag(AppLanguage.chinese)
                Text("English").tag(AppLanguage.english)
            }.pickerStyle(.segmented).labelsHidden().help(L("界面语言"))
        }.padding(16).frame(width: 220).background(.bar)
    }
    private func navigation(_ title: String, symbol: String, index: Int) -> some View {
        Button { tab = index } label: {
            Label(L(title), systemImage: symbol)
                .font(.system(size: 16, weight: tab == index ? .medium : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 12)
                .background(tab == index ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(tab == index ? .isSelected : [])
    }

    private var recorder: some View {
        VStack(spacing: 28) {
            HStack(alignment: .center, spacing: 32) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("会议名称")).fontWeight(.medium)
                        TextField(L("未命名会议"), text: $model.title).textFieldStyle(.roundedBorder).controlSize(.large)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("声音来源")).fontWeight(.medium)
                            Spacer()
                            Button { model.refreshSources() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).help(L("刷新应用列表"))
                        }
                        Picker(L("声音来源"), selection: $model.sourceID) {
                            Text(L("全部系统声音")).tag("all")
                            ForEach(model.sources) { source in Text(source.name).tag(source.id) }
                        }.labelsHidden().controlSize(.large).id(language.language)
                    }
                    Toggle(L("录入麦克风"), isOn: $model.useMicrophone).toggleStyle(.switch)
                    TranscriptionOptionsView(model: model, workspace: model.workspace)
                }.frame(maxWidth: .infinity).disabled(model.busy)
                Divider()
                VStack(spacing: 20) {
                    Text(durationText(model.elapsed)).font(.system(size: 48, weight: .light, design: .rounded)).monospacedDigit()
                    Text(stateText).foregroundStyle(.secondary).font(.system(size: 14))
                    VStack(spacing: 12) {
                        level("会议声音", value: model.systemLevel)
                        if model.useMicrophone { level("麦克风", value: model.micLevel) }
                    }.padding(.vertical, 4)
                    controls
                    if model.phase == .starting { Button(L("取消准备")) { model.cancelStart() } }
                }.frame(width: 275)
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(28).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
    private func level(_ title: String, value: Float) -> some View {
        HStack(spacing: 12) {
            Text(L(title)).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            ProgressView(value: Double(model.phase == .recording ? value : 0), total: 1)
                .accessibilityLabel(L(title)).accessibilityValue("\(Int(value * 100))%")
        }
    }
    private var controls: some View {
        HStack(spacing: 12) {
            if model.isRecording {
                Button { model.pauseOrResume() } label: { Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill") }
                    .help(L(model.phase == .paused ? "继续录音" : "暂停录音"))
                Button(L("结束并保存")) { Task { await model.stop() } }.buttonStyle(.borderedProminent)
            } else {
                Button { Task { await model.start() } } label: {
                    HStack(spacing: 8) {
                        if model.busy { ProgressView().controlSize(.small) }
                        else { Image(systemName: "record.circle") }
                        Text(L(model.phase == .transcribing ? "正在转录…" : model.phase == .saving ? "正在保存…" : model.phase == .starting ? "正在准备…" : "开始录音"))
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(model.busy)
            }
        }.controlSize(.large).font(.system(size: 16, weight: .medium))
    }
    private var stateText: String {
        switch model.phase {
        case .idle: return L("准备就绪")
        case .starting: return L("正在准备")
        case .recording: return L("录音中")
        case .paused: return L("已暂停")
        case .saving: return L("正在保存")
        case .transcribing: return L("正在转录…")
        }
    }

    private func library(limit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if limit != nil { Text(L("最近录音")).font(.system(size: 19, weight: .semibold)) }
                else {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("搜索录音"), text: $model.search).textFieldStyle(.plain)
                    }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer(minLength: 16)
                if limit != nil { Button(L("查看全部")) { tab = 1 } }
                else { Button { model.openFolder() } label: { Image(systemName: "folder") }.help(L("打开录音文件夹")) }
            }
            let records = limit.map { Array(model.recordings.prefix($0)) } ?? model.filteredRecordings
            if records.isEmpty {
                Text(L(model.search.isEmpty ? "暂无录音" : "没有匹配的录音"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140)
            } else {
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        recordingRow(record)
                        if record.id != records.last?.id { Divider().padding(.leading, 64) }
                    }
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    private func recordingRow(_ record: Recording) -> some View {
        HStack(spacing: 16) {
            Button { model.play(record) } label: {
                Image(systemName: model.playingID == record.id ? "stop.fill" : "play.fill").frame(width: 30, height: 30)
            }.buttonStyle(.borderless).disabled(record.filename == nil || model.busy).help(L("播放 / 停止"))
            VStack(alignment: .leading, spacing: 6) {
                Text(record.title).font(.system(size: 17, weight: .medium)).lineLimit(1)
                Text("\(record.date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(language.language.locale))) · \(L(record.source))")
                    .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            if record.status == "interrupted" {
                Button(L("恢复导出")) { Task { await model.recover(record) } }.disabled(model.busy)
            } else { Text(durationText(record.duration)).monospacedDigit().font(.system(size: 14)).foregroundStyle(.secondary) }
            Button(L("转为文字")) { model.prepareFileTranscription(record) }
                .disabled(model.busy || record.filename == nil)
            Button { model.openTranscript(record); tab = 3 } label: { Image(systemName: "text.bubble").frame(width: 22, height: 22) }
                .disabled(model.busy).help(L("查看转录"))
            Button { model.reveal(record) } label: { Image(systemName: "folder").frame(width: 22, height: 22) }
                .buttonStyle(.borderless).help(L("在访达中显示"))
        }.padding(18)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 28) {
            settingsSection("通用") {
                HStack {
                    Text(L("界面语言")); Spacer()
                    Picker(L("界面语言"), selection: $language.language) {
                        Text("中文").tag(AppLanguage.chinese); Text("English").tag(AppLanguage.english)
                    }.labelsHidden().frame(width: 180)
                }
                Divider()
                HStack {
                    Text(L("追问模型")); Spacer()
                    Button(L("配置 API 或本地 Agent")) { showQuestionSettings = true }
                }
            }
            settingsSection("保存位置") {
                Text(model.folder.path).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button(L("选择文件夹…")) { model.chooseFolder() }.disabled(model.busy)
                    Button(L("在访达中打开")) { model.openFolder() }
                }
            }
            settingsSection("系统权限") {
                permissionRow("屏幕与系统音频录制", granted: model.screenAllowed, mic: false)
                Divider()
                permissionRow("麦克风", granted: model.micAllowed, mic: true)
            }
            DisclosureGroup(L("录音说明")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("全部系统声音包含通知音；只录会议时，请选择对应应用。"))
                    Text(L("会议软件的静音与这里的麦克风开关独立。建议使用耳机。"))
                    Text(L("录音前请告知参会者；会声不会向会议发送录制通知。"))
                    Text(L("录制期间请保持 Mac 开盖。音频和转录保存在本机。"))
                }.font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 12)
            }
        }.sheet(isPresented: $showQuestionSettings) { QuestionSettingsView(workspace: model.workspace) }
    }
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L(title)).font(.system(size: 19, weight: .semibold))
            VStack(alignment: .leading, spacing: 18, content: content).padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private func permissionRow(_ title: String, granted: Bool, mic: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle" : "circle").foregroundStyle(.secondary)
            Text(L(title)); Spacer()
            Button(L(granted ? "查看设置" : "前往开启")) { model.openPermissionSettings(microphone: mic) }
        }
    }
}
