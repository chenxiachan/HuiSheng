#!/bin/bash
# Opt-in. Uses installed Whisper and Apple's ready on-device LLM; synthetic audio only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="${HUISHENG_TEST_OUTPUT_DIR:-$ROOT/.test-output/summary}"
mkdir -p "$TEST_DIR"
say -v Tingting -r 155 -o "$TEST_DIR/speech.aiff" '今天讨论会议录音软件。大家同意先发布 Mac 版本，暂时不做手机版。小李负责在星期五之前完成录音测试。小王负责整理使用说明，没有确定截止日期。预算还没有决定，需要下周再讨论。有人建议增加视频录制，但还没有通过。'
SOURCES=()
for file in Localization MediaPipeline CaptureEngine RecorderModel LiveTranscription ExecutableLocator TranscriptionSettings WhisperTranscription FileTranscription MeetingDocument MeetingSummary LocalSummaryService QuestionService LocalAgentService MeetingWorkspaceModel TranscriptTextView; do
  SOURCES+=("$ROOT/Sources/HuiSheng/$file.swift")
done
swiftc -swift-version 5 -parse-as-library -O -o "$TEST_DIR/summary-check" "${SOURCES[@]}" "$ROOT/Tests/SummaryCheck.swift"
"$TEST_DIR/summary-check" "$TEST_DIR"
