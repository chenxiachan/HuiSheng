#!/bin/bash
# Opt-in: requires whisper-cli and a multilingual ggml model; no model download.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="${HUISHENG_TEST_OUTPUT_DIR:-$ROOT/.test-output}"
mkdir -p "$TEST_DIR"
say -v Tingting -r 155 -o "$TEST_DIR/chinese.aiff" '今天我们讨论会议录音软件。请在星期五之前完成测试，并把报告保存在本地。下一次会议安排在下周一上午十点。'
say -v Samantha -r 160 -o "$TEST_DIR/english.aiff" 'Today we are discussing the meeting recorder. Please finish the tests by Friday and save the report locally. Our next meeting is on Monday morning at ten.'
swiftc -swift-version 5 -parse-as-library -O -o "$TEST_DIR/local-speech-check" \
  "$ROOT/Sources/HuiSheng/Localization.swift" \
  "$ROOT/Sources/HuiSheng/MediaPipeline.swift" \
  "$ROOT/Sources/HuiSheng/CaptureEngine.swift" \
  "$ROOT/Sources/HuiSheng/RecorderModel.swift" \
  "$ROOT/Sources/HuiSheng/LiveTranscription.swift" \
  "$ROOT/Sources/HuiSheng/ExecutableLocator.swift" \
  "$ROOT/Sources/HuiSheng/TranscriptionSettings.swift" \
  "$ROOT/Sources/HuiSheng/WhisperTranscription.swift" \
  "$ROOT/Sources/HuiSheng/FileTranscription.swift" \
  "$ROOT/Sources/HuiSheng/MeetingDocument.swift" \
  "$ROOT/Sources/HuiSheng/QuestionService.swift" \
  "$ROOT/Sources/HuiSheng/LocalAgentService.swift" \
  "$ROOT/Sources/HuiSheng/MeetingWorkspaceModel.swift" \
  "$ROOT/Sources/HuiSheng/TranscriptTextView.swift" \
  "$ROOT/Tests/HuiShengTests/LocalSpeechTests.swift" \
  "$ROOT/Tests/LocalSpeechCheck.swift"
"$TEST_DIR/local-speech-check" "$TEST_DIR"
