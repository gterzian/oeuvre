#!/usr/bin/env bash
# Run the agent browser outside the coding agent's sandbox, with the test data
# directory the skill reads. The app needs this because MLX builds its Metal
# kernels at run time and the sandbox blocks that.
set -euo pipefail
cd "$(dirname "$0")/.."

export AGENT_BROWSER_DATA_DIR="${AGENT_BROWSER_DATA_DIR:-$PWD/.data}"
export AGENT_BROWSER_MODEL="${AGENT_BROWSER_MODEL:-$HOME/Projects/Models/Qwen3.5-4B-MLX-4bit}"
export AGENT_BROWSER_CDP_PORT="${AGENT_BROWSER_CDP_PORT:-9222}"

mkdir -p "$AGENT_BROWSER_DATA_DIR"
exec "dist/Agent Browser.app/Contents/MacOS/agent-browser" \
  --cdp-port "$AGENT_BROWSER_CDP_PORT" \
  --data-dir "$AGENT_BROWSER_DATA_DIR" \
  --model "$AGENT_BROWSER_MODEL" \
  "$@"
