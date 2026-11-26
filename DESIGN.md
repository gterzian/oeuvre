# Agent Browser: design

The agent browser is a macOS app that lets a small local model work in web
pages the way a person does. A person writes a task in plain words, the model
looks at the page as an image and acts through pointer and keyboard input, and
the window shows the person the same frames the model sees.

Two agents share the project. The coding agent (pi) writes the app, writes web
apps for the model to work in, gives the model tasks and rates the runs. The
browser agent is the model inside the Swift loop. The proof of concept answers
two questions: whether a small local model can interact with a page in this
embodied way, and whether the loop of coding agent and app makes the model
better at the work.

## Stages

The first stage uses single-page web apps with text fields, buttons,
checkboxes, radio buttons, select menus and scrolling. Its goal is to see
whether the model can place pointer actions and key presses from captures
alone. The second stage uses longer tasks on one page: a todo list on which
the model adds several tasks, completes some, deletes one and filters; a
shopping cart with quantities; pages that update after a delay. Later stages
add cross-origin frames, several tabs and permission boundaries.

## Guiding principle

The browser agent uses the browser the way a person does. Pixels and input
events are the default; interpretation stays with the model. The engine
delivers a page as layers, the capture service composes them, and the window
shows the same composition.

## What the model sees and does

A task starts with one agent tab. A capture is an image of the page area, taken
after the page settles. The model may request a region at higher resolution or
a short sequence of frames. Captures carry a grid overlay. The model's tools
are pointer moves, clicks, drags, scrolls, key presses, typing, captures and
waits. Input actions arrive in one batch per tool call; the tool result carries
the capture taken at the settled point after the batch.

## Grid overlay

Columns carry letters and rows numbers along the edges, and every cell shows
its label in a corner, such as `F7`. The grid exists in the image the model
receives and as a view option in the window. A pointer action names a cell and
may name fractions of the cell for a smaller target. A refined capture of a
region carries a finer grid whose labels are local to the region; an action on
that capture maps back through the region. The capture service draws the grid
as the last step of composition.

## Agent loop

The loop is Swift code. It runs Qwen3.5-4B-MLX-4bit through MLX Swift, with an
optional LoRA adapter chosen in settings. The conversation is rendered through
the model's chat template together with the browser tool declarations. The
loop parses tool calls, asks the harness to apply them, appends the results and
captures, and calls the model again. A reply without tool calls ends the task.

The conversation file is written after every message. A tool call in flight at
an interruption receives an interrupted result on resume, so the model asks
for a capture and every action runs once. A person's message joins at the next
point between tool calls. The loop sits behind a small interface so it can
move into its own process later.

## Actions as UI events

The harness supplies positions in points from the top-left of the web area and
calls `WebviewProvider::send_ui_event`, the same entry point platform input
takes. A click is a pointer move, pointer down and pointer up with the main
button. A move places the pointer without pressing. A drag moves, presses,
moves along a path and releases. A scroll turns the wheel at the cell. A key
press carries a key name, physical code and modifier set. Typing sends key
events for ASCII and IME commit events for other text. The harness keeps the
pointer button state.

The `act` tool carries a `note` and a list of actions: `click`, `move`,
`drag`, `scroll`, `key`, `type`, `wait`. The `capture` tool takes an optional
cell region and an optional frame count. Result lines say `delivered` or name
why an action was rejected, followed by the settled status.

## Capture timing

The engine renders when a rendering opportunity and a UI state update are both
present. Only the embedder raises opportunities. The harness raises one after
a batch, on a capture call, and at the end of a wait. The window repaints from
the capture service's layers and raises none of its own.

While the loop waits for the model, no opportunity is granted. Timers, network
responses and scripts still run and collect as one batched update. Work tied to
rendering—animation frame callbacks, CSS animation sampling, observers—advances
at the next opportunity.

A tab is settled when no update is queued, no render is in flight, the scene
reports no animation, and no navigation or network request the page started is
outstanding. In this implementation the harness follows the composition stream
from the engine, re-grants an opportunity whenever `request_next_frame`
arrives, and waits for a quiet interval; a page that never settles gets a
capture after a deadline with a `still active` note. Each composition carries
its kind: content update, deadline, or out-of-band video frame. Frames rendered
during settling enter a short buffer of recent captures.

## The app

The window holds a task panel on the left, the composed agent tab in the
center, and a debug panel at the bottom. The task panel shows the task text,
status, step history, a message box and a stop control. The main area shows
the capture service's composition. The debug panel has a toolbar, a table of
entries and a detail pane: the toolbar holds the task selector, kind filters, a
text filter, follow, clear, copy, reveal and the adapter name; the detail tabs
are Prompt, Thinking, Output and Timing. The View menu toggles the panel. The
settings window chooses the adapter and sets the trainer budget and capture
options.

## Harness components

- **App shell**: AppKit windows, task panel, debug panel, agent tab view.
- **Engine bridge**: owns the `WebviewProvider`, implements `Embedder`,
  forwards callbacks to Swift, and presents captures.
- **Capture service**: keeps the latest topology and surface of every layer,
  composes, draws the grid, resolves cells, encodes images, and runs the
  capture points and settling loop.
- **Agent loop**: conversation, model turn, tool calls, persistence, debug and
  CDP reporting.
- **CDP service**: formal-web's server inside the binding crate, with the
  `Agent` domain routed to the loop.

## Testing with a coding agent

A test writes a web app, launches it, prompts the browser agent, verifies the
app's log and rates the run. The skill `agent-browser-test` offers one command
per step and uses CDP internally. Web apps record pointer, key, scroll, focus,
input and submit events and call `trace(name, data)` at each logical step. The
page keeps the log in `window.__agentBrowserLog`; `prompt` reads it over CDP
after the task and writes `app-log.jsonl` into the run directory. Keeping the
test app to one page keeps the log available for the whole task.

`launch <name>` copies `trace.js` next to the site, opens its `index.html` from
a `file://` URL in the agent tab, starts or reuses the app with the CDP
endpoint, and prints the URL. `prompt "<text>" --timeout <seconds>` starts a
task, prints each step and the final reply, saves the run and marks a timeout.
`verify <name>` evaluates `test.json`, prints the check report and pointer-miss
share, ends the run and returns the verdict in its exit code.
`rate <score> "<justification>"` stores the coding agent's rating in the run
directory.

Checks are `entry`, `sequence`, `absent`, `value` and `budget`. The verdict is
success when every required check passes and the weighted score reaches the
threshold, partial when required checks pass below the threshold, and failure
when a required check fails.

## CDP control endpoint

The endpoint starts only when `--cdp-port` is passed. The agent tab is a page
target. The standard `Page`, `Runtime`, `Input`, `DOM` and `Accessibility`
methods operate on it through the automation host. The added `Agent` domain
offers `startTask`, `sendMessage`, `stopTask` and `getState`, and emits
`stepAdded` and `taskFinished`. The prompt command uses this domain over the
same connection as the standard methods.

## Local model and fine-tuning loop

The model is Qwen3.5-4B-MLX-4bit. The app adds MLX Swift and can train through
LoRA. Training is enabled with `--training`, which the test skill passes when
`AGENT_BROWSER_TRAINING` is set.

The coding agent is task setter, environment author and reward model. It
writes web apps and tasks, launches and prompts, verifies and rates. Training
is a property of the app; the ordinary testing work is the experience the app
trains on.

A trajectory is the complete record of a run: system prompt, messages, tool
calls, results, captures, the web app log, task, seed, site label, adapter and
rating. A training example is one step: the window the model received and the
reply it generated. Runs scoring 50 or higher supply examples; among successful
runs of one task and seed, the highest score enters first and the shortest wins
a tie; a step enters when its actions were delivered and its pointer events
landed on interactive elements.

The trainer watches the trajectories directory. It takes steps on the base
model the loop has loaded, holds optimizer state only while training, and
yields after the current step when a task starts. A session starts when enough
new examples exist, mixes them with older examples, and ends after the set
number of passes. Checkpoints are written atomically every few minutes and a
session resumes from its latest checkpoint. The last checkpoint becomes a
candidate adapter with a manifest recording the base model, parent, experience
hash, hyperparameters, system prompt, grid and window settings.

When a task starts, the app assigns the active adapter or, with a set
probability, the candidate. A candidate run on a site it never trained on is
an evaluation run. The app promotes the candidate when it has enough evaluation
runs, when its mean rating beats the active adapter by the margin, and when no
run scored 0. Otherwise it discards the candidate. The adapter store keeps
every promoted adapter and its manifest.

The trainer's budget is a maximum number of steps, a maximum data-directory
size and a maximum number of consecutive discards. The progress view shows the
trainer state, step and loss, latest checkpoint, candidate and active means,
and promotion history.

## Data directory

The data directory holds `environments/<name>/` (site, `test.json`, tasks and
a copy of the site at run time),
`trajectories/<run>/` (conversation, captures, app log, task, seed, site
label, adapter and rating), `adapters/<id>/` (manifest and checkpoints), and
`journal.md` (the coding agent's rounds and next plan). The data directory is
`.data/` in the repository for development and training runs, and
`~/Library/Application Support/agent-browser/` when the app runs with neither
a `--data-dir` argument nor `AGENT_BROWSER_DATA_DIR`.

## Repository and embedding

The Swift app, binding crate, build scripts, test skill and this document live
in this repository. `formal-web/` is a local clone of formal-web at the pin in
`formal-web.pin`; version control ignores it. The binding crate depends on the
`webview` package, and the build copies the helper executables into the app
bundle's resources. The engine receives that directory as
`extensions_directory`.

Changes made in formal-web for this embedding are general embedder
capabilities: the composition kind travels with composed layers; the CDP server
lets the embedder register a domain and emit events on it; the `Input` domain
delivers key and text events; `Runtime.callFunctionOn`, `DOM.getBoxModel` and
`DOM.getContentQuads` answer; pointer down/up produce a trusted DOM click.
`patches/formal-web.patch` carries these changes until the pin moves to the
pushed formal-web commit.

## Open questions

- How accurately does the model place clicks on the grid, and does refinement
  pay for its extra capture?
- Which cell size gives the most accurate clicks, with the grid on and off?
- How are labels drawn to stay legible over light and dark content?
- Does the chat template accept an image inside a tool result?
- What does a resumed tab restore beyond its URL?
- Does typing long or non-Latin text use IME or paste?
- How much visible change ends a wait until change?
- What default and upper bound fit `max_ms`?
- Does a task continue when the CDP client disconnects?
- How many image tokens does one capture cost at the default viewport?
- How much memory does LoRA training with captures need, and how many steps
  per minute does the target Mac sustain?
- How many rated runs before the model completes the easy starter tasks?
- Which selection rules and hyperparameters give the largest gain?
- How many evaluation runs and which margin make a reliable promotion?
- Which share of older examples keeps earlier skills from fading?
- When does training on pairs of successful and failed runs add value?
- How closely do coding-agent ratings agree with the person's?
- Does a rating need the captures, or do the log and notes suffice?
- Does thinking pay for its generation time?
