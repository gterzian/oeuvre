#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x "dist/Agent Browser.app/Contents/MacOS/agent-browser" ]]; then
  scripts/build-app.sh
fi
export AGENT_BROWSER_MODEL="${AGENT_BROWSER_MODEL:-$(cd .. && pwd)/Models/Qwen3.5-4B-MLX-4bit}"
export AGENT_BROWSER_DATA_DIR="${AGENT_BROWSER_DATA_DIR:-$PWD/.data}"
exec "dist/Agent Browser.app/Contents/MacOS/agent-browser" "$@"
