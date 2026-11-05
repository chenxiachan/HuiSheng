import SwiftUI

struct MeetingSummaryView: View {
    @ObservedObject var workspace: MeetingWorkspaceModel
    @ObservedObject var recorder: RecorderModel
    @ObservedObject private var language = AppSettings.shared
    private var job: SummaryJobState? { workspace.document.flatMap { recorder.summaryJobs[$0.recordingID] } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("会议总结")).font(.system(size: 19, weight: .semibold))
                Spacer()
                if job?.running == true {
                    Button(L("停止")) { if let id = workspace.document?.recordingID { recorder.cancelSummary(id) } }
                } else {
                    Button(L(workspace.summary == nil ? "生成总结" : "重新生成")) { recorder.summarizeCurrentMeeting() }
                        .disabled(recorder.busy || workspace.document == nil)
                }
            }.padding(22)
            if let job {
                VStack(alignment: .leading, spacing: 8) {
                    if job.running { ProgressView(value: job.progress); Text(L(job.status)).foregroundStyle(.secondary) }
                    if let error = job.error { Text(L(error)).foregroundStyle(.orange) }
                }.font(.system(size: 14)).padding(.horizontal, 22).padding(.bottom, job.running || job.error != nil ? 16 : 0)
            }
            if let summary = workspace.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(summary.content.title).font(.system(size: 20, weight: .semibold))
                        Text(summary.content.overview).font(.system(size: 18)).lineSpacing(5)
                        if let document = workspace.document, !summary.isCurrent(for: document) {
                            Text(L("转录已更新，此总结可能已过时。")).font(.system(size: 14)).foregroundStyle(.orange)
                        }
                        if summary.transcriptIncomplete {
                            Text(L("转录可能不完整或含未定稿；此总结仅覆盖现有文字。")).font(.system(size: 14)).foregroundStyle(.orange)
                        }
                        section("讨论要点", summary.content.topics)
                        section("已确认决定", summary.content.decisions)
                        section("待办事项", summary.content.actions)
                        section("待确认问题", summary.content.questions)
                        Text(L("由本机模型生成，重要信息请回听核对。")).font(.system(size: 13)).foregroundStyle(.secondary)
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(22)
                }
            } else {
                VStack(spacing: 14) {
                    Text(L(job?.running == true ? "录音已保存，正在本机处理。" : "录音结束后，自动生成标题与会议总结。"))
                        .font(.system(size: 17)).multilineTextAlignment(.center)
                    if job?.running != true {
                        Text(L("也可以为已有录音生成总结；缺少文字时会先转录。"))
                            .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func section(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(title)).font(.system(size: 17, weight: .semibold))
            if items.isEmpty { Text(L("转录中未明确。")).font(.system(size: 16)).foregroundStyle(.secondary) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 9) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 17)).lineSpacing(4)
            }
        }
    }
}
