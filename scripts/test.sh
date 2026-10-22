#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="${HUISHENG_TEST_OUTPUT_DIR:-$ROOT/.test-output}"
mkdir -p "$TEST_DIR"
swiftc -swift-version 5 -parse-as-library -O -o "$TEST_DIR/audio-check" \
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
  "$ROOT/Tests/HuiShengTests/FeatureTests.swift" \
  "$ROOT/Tests/HuiShengTests/MediaTests.swift"
rm -f "$TEST_DIR/mock-port"
python3 "$ROOT/Tests/mock-api.py" "$TEST_DIR/mock-port" &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
for attempt in {1..50}; do
  if [ -s "$TEST_DIR/mock-port" ]; then break; fi
  sleep 0.1
done
HUISHENG_MOCK_API="http://127.0.0.1:$(cat "$TEST_DIR/mock-port")/v1" HUISHENG_TEST_OUTPUT_DIR="$TEST_DIR" "$TEST_DIR/audio-check"
