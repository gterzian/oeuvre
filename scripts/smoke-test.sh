#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -x "dist/Agent Browser.app/Contents/MacOS/agent-browser" ]]; then
  scripts/build-app.sh
fi

scripts/stop-app.sh

NAME=hello
DATA_DIR="${AGENT_BROWSER_DATA_DIR:-$PWD/.data}"
DEST="$DATA_DIR/environments/$NAME"
mkdir -p "$DEST/site"
cp -R examples/hello/site/. "$DEST/site/"
cp examples/hello/test.json "$DEST/test.json"
export AGENT_BROWSER_DATA_DIR="$DATA_DIR"

if [[ -z "${AGENT_BROWSER_MODEL:-}" ]]; then
  export AGENT_BROWSER_MODEL="$HOME/Projects/Models/Qwen3.5-4B-MLX-4bit"
fi

echo "Model: $AGENT_BROWSER_MODEL"
echo "Launching $NAME..."
.agents/skills/agent-browser-test/scripts/launch "$NAME"

echo "Prompting the browser agent..."
.agents/skills/agent-browser-test/scripts/prompt \
  "Type Ada into the name field, tick the agree checkbox, then click Submit." \
  --timeout 180

echo "Verifying..."
.agents/skills/agent-browser-test/scripts/verify "$NAME"
