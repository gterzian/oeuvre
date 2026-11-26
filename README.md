# Agent Browser

An embodied browser use proof of concept: a small local model looks at a page
as an image, acts through pointer and keyboard input, and the app shows the
person the same frames. The harness is Swift with AppKit; formal-web is the
engine, and MLX Swift runs Qwen3.5-4B-MLX-4bit on the Mac.

## Build

The repository expects the formal-web clone beside it (`../formal-web`) and
the model snapshots in `../Models/`. `scripts/setup.sh` accepts that layout or
clones formal-web at `formal-web.pin` and applies `patches/formal-web.patch`.

```bash
scripts/setup.sh
scripts/build-app.sh
open "dist/Agent Browser.app"
```

The app needs `AGENT_BROWSER_MODEL` (a local snapshot directory) and
`AGENT_BROWSER_EXTENSIONS` (the directory holding `formal-web-content`,
`formal-web-net` and `formal-web-graphics`) when it runs outside the bundle.
`scripts/run-app.sh` fills both for the development layout.

## Run and test

The coding agent uses the `agent-browser-test` skill in
`.agents/skills/agent-browser-test/`. It writes a web app in the data
directory, launches it, prompts the browser agent, verifies the app's log and
rates the run. The CDP endpoint is off unless `--cdp-port` is passed; the test
skill starts a launch with it on.

The design document is `DESIGN.md`. The data directory is `.data/` in this
repository: git-ignored, holding environments, trajectories, adapters and the
app log. `scripts/run-app.sh` and `scripts/run-app-test.sh` point the app at
it, and the test skill defaults to it. The app falls back to
`~/Library/Application Support/agent-browser/` when nothing sets a data
directory.

## Status

The app builds and the test skill is in place. The first launch, the model
warm-up and a full run need a session outside the sandbox: MLX builds its
Metal library on first use, and the formal-web helper processes need their
Mach bootstrap environment. See `formal-web/AGENTS.md` for the sandbox note.
