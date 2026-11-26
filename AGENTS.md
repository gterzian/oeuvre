# AGENTS.md

This repository is the agent browser: a Swift/AppKit harness around a local
`formal-web/` clone and an MLX model runtime. `formal-web/AGENTS.md` and
`formal-web/SKILLS.md` are part of this repository's guidance — read them
first and follow them. Their Rust-, cargo-, WPT- and vendor-specific rules
apply to the `formal-web/` clone; the general rules (scope, file boundaries,
documentation chain, naming, logging, dead code, end-of-task flow) apply to
every file here and are restated below so a task that never opens formal-web
still has them. When the two disagree, `formal-web/AGENTS.md` owns the general
rule and this file owns what is specific to the harness.

## Rule Number One

Only ever perform an action if it directly relates to a coding task in this
repository.

## Rule Number Two: external network

Never navigate to an external domain or make a request to an external host
without explicit prior approval. Use local resources only: `localhost`,
`file://`, and artifacts in the repository or the data directory.

## File system boundaries

Read and write freely inside the repository and the system temp directories.
The data directory (`AGENT_BROWSER_DATA_DIR`, default
`~/Library/Application Support/agent-browser`) is a task artifact store:
environments, trajectories and adapters are written there by the app and the
skills. Everything else — other repositories, `~/.config`, shared
directories — needs explicit approval before a write, move or delete.

## Documentation chain

Read from general to specific before touching code:

1. `AGENTS.md` (this file).
2. `formal-web/AGENTS.md` when the task touches the engine, the helpers or
   the CDP surface, plus the `README.md` of every directory from
   `formal-web/` down to the files you change.
3. `SKILLS.md` before running or changing a skill.

There is exactly one `AGENTS.md` per repository; every other directory
documents itself with a `README.md`. A README sits at the lowest point in the
tree that still covers all the code beneath it, and it never restates what a
README above it, this file, or formal-web's chain already says — point at the
file that owns the fact instead. Prose describes the code as it is now: no
history, no "previously", no session narration. A README carries guidance,
remaining work, and dead ends for currently-unfixed issues; nothing else.

## Skills

Skills live in `.agents/skills/` and follow the conventions in
`formal-web/SKILLS.md`. `agent-browser-test` runs the end-to-end tests of the
agent browser; read its `SKILL.md` before using it and report, rather than
improvise, when a skill cannot run.

## Verification

- Build and run the app, then verify through the repo's own browser. CDP work
  uses `formal-web/.agents/skills/browser-debug` (`browser.mjs`, `cdp.mjs`);
  there is no other browser in the loop. Never reach for Chrome, Firefox or
  Safari to check a page.
- The app is AppKit-headed and its CDP endpoint is the app's, so the app must
  be running. It has to be started outside the coding agent's sandbox: MLX
  builds its Metal kernels at run time and the sandbox blocks that.
- A web app written for a task is verified against formal-web before it is
  used for training or rated. Read the rendered layout and drive the controls
  over CDP: cell-aligned controls are checked by comparing each control's
  rect with the grid descriptor, and the flow is checked by clicking cell
  centres and reading the page's own trace entries.
- Every test failure is a regression until proven otherwise. Verify a baseline
  before calling a failure pre-existing.
- Document only verified facts: state what was observed, what was tried, and
  what was ruled out.

## Naming and imports

- Descriptive names throughout; single-letter locals (`s`, `el`, `p`) are
  prohibited in new code.
- No wildcard imports and no fully-qualified call paths: import with `use` or
  `import` at the top of the file and call unqualified.
- Name a shared mechanism for what it is, not for its first user.
- Do not bulk-rename with scripts; rename incrementally when touching nearby
  code.

## Dead code and comments

- Remove unused code instead of annotating around it: no `#[allow(dead_code)]`,
  no `_`-prefixed bindings, no `let _ =` used to discard a result.
- Comments carry what the code cannot show: a spec step, an external
  constraint, a cross-process reason. They never paraphrase the line they sit
  on and never narrate an earlier design.
- A method implementing a spec algorithm carries only the spec anchor above
  it; explanation lives in `//` comments below the relevant step.

## Logging

`AgentLog.write` is the harness's file and stderr log; formal-web uses `log`
with `env_logger`. Log every error before it is discarded and name the
operation that failed. Development tracing is removed when the work lands;
keep only toggles that serve ongoing diagnosis (`AGENT_BROWSER_GRID`,
`AGENT_BROWSER_TRACE_LAYERS`).

## formal-web

- `formal-web/` is a local clone at the revision the pin records. Change
  formal-web there when a task needs it, and verify the change with the
  agent-browser-test skill.
- A task that changed formal-web ends with the change committed and pushed in
  the formal-web repository and `formal-web.pin` moved to the pushed commit.
  While the clone is local, `patches/formal-web.patch` carries the embedder
  changes so a fresh clone reproduces the build.
- Read the AppKit embedder before adding to the binding. The embedding API is
  asynchronous and message-passing; do not add blocking waits or shared
  mutable state to the Rust side.

## Swift

- The harness is Swift with AppKit. The engine helper processes and the
  binding crate are Rust.
- `Sources/AgentBrowserCore` holds the harness, the loop and the UI. Keep the
  UI on the main actor and the loop off it.
- The model runtime is the only target that imports `mlx-swift-lm`,
  `swift-huggingface` and `swift-transformers`.

## Data directory

The data directory holds what a session produces: environments, trajectories,
adapters and the app log. For work in this repository it is `.data/` at the
repository root, git-ignored; `scripts/run-app.sh`,
`scripts/run-app-test.sh` and the agent-browser-test skill all point there.
The app falls back to `~/Library/Application Support/agent-browser/` when
nothing sets a data directory.

- Put it under the repository rather than a temp directory: a training run or
  a teacher dataset is costly to reproduce, `/tmp` does not survive a restart,
  and the coding agent's sandbox cannot read Application Support.
- Never commit a trajectory, an adapter, a web app or the app log from the
  data directory. The repository holds the code, the skills and the design.

## End-of-task flow

1. Stop every process the session started: the app, the CDP endpoint and the
   formal-web helpers. A left-over endpoint blocks the next launch.
2. Remove session artifacts from the repository; artifacts under the data
   directory and `/tmp` stay there.
3. Build and verify what changed. A changeset that touches only documentation
   skips the build, and the report says so.
4. Re-read the documentation chain and update it where the session taught a
   general lesson; prune any completion narration the task's code now covers.
5. Suggest a commit message for the current diff, read from `git diff HEAD`,
   and nothing else: no test runs, no session narration. End the message at
   its last prose line; no `Signed-off-by`.
6. Re-read the session and confirm Rule Number One held; say so if it did not.
