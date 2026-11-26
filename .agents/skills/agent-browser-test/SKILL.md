---
name: agent-browser-test
description: Test the agent browser end to end. Write a small single-page web
  app that records what happens in it, open it from a file URL, give the
  browser agent a task on it, and rate the outcome from the recorded log. Use
  when a change to the agent browser needs a run against a real page.
---

# agent-browser-test

A test launches a local web app, prompts the browser agent, verifies the result
and rates the run. The rating rests on the log the web app writes, so write the
web app first and decide what it logs before the run.

The app is opened from a `file://` URL. No HTTP server is needed: `launch`
copies `trace.js` next to the page, and `prompt` reads
`window.__agentBrowserLog` over CDP after the task and saves it as
`app-log.jsonl` in the run directory.

## Write the web app
1. Put the site in `<data dir>/environments/<name>/site/`. The data dir is
   `.data/` in this repository (git-ignored), or `AGENT_BROWSER_DATA_DIR` when
   set. Give every interactive element a stable id.
2. Add `<script src="trace.js"></script>` to every page. `launch` copies the
   skill's `trace.js` next to the page. It records pointer, key, scroll,
   focus, input and submit events with timestamps and target ids.
3. Call `trace(name, data)` in the app's own code at every step of the task's
   logic: each handler, form submission, selection, view change and
   purchase. Name an entry after what happened in the app's terms
   (`item_added`, `task_completed`) and put the values in `data`.
4. Keep the app to one page so the log stays in the page for the whole task.
   The browser agent meets the app the way a person does.

## Write the checks
5. Write environments/<name>/test.json, next to the site, before the run.
   Each check names the log entries it looks for and carries a weight.
   Checks that express the task's goal are required. Further checks cover
   values, side effects to avoid and the number of steps.
6. Check the page against the grid with `scripts/cells`. It reports, for every
   grid cell centre, the element a click there reaches, and `--expect
   <cell>=<fragment>` fails when the element does not match. A control a cell
   centre reaches is a control the agent can aim at; a cell that reaches
   `body` or the wrong element is a layout bug in the app, not a model
   failure. Pass `--columns`, `--rows`, `--width` and `--height` when the grid
   differs from the default 20 by 12 over 1280 by 720 points.

## Run and rate
7. `scripts/launch <name>`
8. `scripts/prompt "<task>" --timeout <seconds>`. Phrase the task as a person
   would. Size the timeout to the task. A task that runs past it ends and
   counts as failed.
9. `scripts/verify <name>`
10. Rate the run: `scripts/rate <score> "<justification>"`. Give a score from
   0 to 100. Completion of the task, judged from the app log, earns most of
   the points. Directedness earns the rest. A score of 50 or higher is a
   success. A run that fails without causing harm, including a timeout,
   scores 1 to 49. The score 0 is for a consequential action the task did not
   ask for.
11. Read the report. Failed checks point to log lines. Change the web app,
    the checks or the agent browser, and run again from launch.
