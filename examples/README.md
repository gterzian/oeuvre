# Examples

`hello/` is a small test environment for a quick inference run: one text
field, one checkbox and a submit button. Its app log records a `submitted`
entry with the typed name and the checkbox state.

Install it into the data directory (`.data/` in the repository by default):

```bash
NAME=hello
DATA_DIR="${AGENT_BROWSER_DATA_DIR:-$PWD/.data}"
DEST="$DATA_DIR/environments/$NAME"
mkdir -p "$DEST/site"
cp -R examples/hello/site/. "$DEST/site/"
cp examples/hello/test.json "$DEST/test.json"
export AGENT_BROWSER_DATA_DIR="$DATA_DIR"
```

Then run the test skill. The page is opened from a `file://` URL; no server
is started:

```bash
.agents/skills/agent-browser-test/scripts/launch hello
.agents/skills/agent-browser-test/scripts/prompt \
  "Type Ada into the name field, tick the agree checkbox, then click Submit." \
  --timeout 90
.agents/skills/agent-browser-test/scripts/verify hello
```

`verify` exits 0 for success, 2 for partial and 1 for failure. The report
shows the log lines behind every check.
