#!/usr/bin/env bash
set -euo pipefail
for pattern in \
  "Agent Browser.app/Contents/MacOS/agent-browser" \
  ".build/out/Products/Debug/agent-browser" \
  ".build/out/Products/Release/agent-browser" \
  ".build/debug/agent-browser" \
  ".build/release/agent-browser"; do
  pkill -f "$pattern" 2>/dev/null || true
done
for helper in formal-web-content formal-web-net formal-web-graphics formal-web-media; do
  pkill -f "$helper" 2>/dev/null || true
done
