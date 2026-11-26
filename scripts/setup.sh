#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -d formal-web/.git ]]; then
  remote="${FORMAL_WEB_REMOTE:-https://github.com/gterzian/formal-web.git}"
  git clone "$remote" formal-web
  git -C formal-web checkout "$(cat formal-web.pin)"
fi

# The local development clone carries the embedder changes this repository
# needs. A fresh clone gets them from the patch; a clone that already has them
# passes the reverse check and is left alone.
PATCH="$PWD/patches/formal-web.patch"
if ! git -C formal-web apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  git -C formal-web apply "$PATCH"
fi

(cd formal-web && cargo build --release \
  --bin formal-web-content \
  --bin formal-web-net \
  --bin formal-web-graphics)

(cd Engine && cargo build --release)

(cd formal-web/.agents/skills/browser-debug && npm install)
