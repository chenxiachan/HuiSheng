#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="${HUISHENG_TEST_OUTPUT_DIR:-$ROOT/.test-output}"
mkdir -p "$TEST_DIR"
swiftc -swift-version 5 -parse-as-library -O -o "$TEST_DIR/audio-check" \
  "$ROOT/Sources/HuiSheng/MediaPipeline.swift" \
  "$ROOT/Sources/HuiSheng/CaptureEngine.swift" \
  "$ROOT/Sources/HuiSheng/RecorderModel.swift" \
  "$ROOT/Tests/HuiShengTests/MediaTests.swift"
HUISHENG_TEST_OUTPUT_DIR="$TEST_DIR" "$TEST_DIR/audio-check"
