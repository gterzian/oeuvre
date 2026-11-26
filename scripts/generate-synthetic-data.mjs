#!/usr/bin/env node
// Build synthetic teacher trajectories from a real, rated hello run.
//
// The trainer consumes trajectories/<run>/conversation.json together with
// rating.json and verify.json. A synthetic run reuses the real captures and
// substitutes the correct action sequence, so the model learns the basic
// grid clicks (focus, type, tick, submit) without needing a model rollout for
// every example.
//
// Usage:
//   node scripts/generate-synthetic-data.mjs \
//     --source .data/trajectories/<run> \
//     --data-dir .data \
//     --count 12

import { cp, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { pathToFileURL } from "node:url";

function parseArgs(argv) {
  const options = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) continue;
    const name = argument.slice(2);
    const next = argv[index + 1];
    if (next !== undefined && !next.startsWith("--")) {
      options.set(name, next);
      index += 1;
    } else {
      options.set(name, true);
    }
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));
const source = options.get("source");
const dataDir = options.get("data-dir");
const count = Number(options.get("count") ?? 12);
if (!source || !dataDir) {
  console.error(
    "Usage: node scripts/generate-synthetic-data.mjs --source <real-run> --data-dir <data-dir> [--count N]"
  );
  process.exit(2);
}

const sourceConversation = JSON.parse(
  await readFile(join(source, "conversation.json"), "utf8")
);
const sourceCaptures = join(source, "captures");
let captureFiles = [];
try {
  captureFiles = (await readdir(sourceCaptures))
    .filter((name) => name.endsWith(".png"))
    .sort();
} catch {
  console.error(`No captures in ${sourceCaptures}`);
  process.exit(2);
}
if (captureFiles.length < 4) {
  console.error(`Need at least four captures, found ${captureFiles.length}`);
  process.exit(2);
}

const tasks = [
  "Type Ada into the name field, tick the agree checkbox, then click Submit.",
  "Fill in the form with the name Ada, accept the greeting, and press Submit.",
  "Enter Ada in the name field, check the agreement, and submit the form.",
  "Put Ada in the name box, tick the agree box, then click Submit.",
  "Complete the greeting form for Ada and agree to the terms before submitting.",
  "Fill the name field with Ada, select the agreement checkbox, and submit.",
];
const notes = [
  "Click the name field first.",
  "The field is focused; type the name.",
  "Tick the agreement checkbox.",
  "Click Submit to finish the form.",
];

function id(prefix) {
  return `${prefix}_${Math.random().toString(16).slice(2)}${Date.now().toString(16)}`;
}

function message(fields) {
  return {
    id: id("msg"),
    imagePaths: [],
    timestamp: new Date().toISOString(),
    ...fields,
  };
}

function toolCall(step, name, argumentsObject, note) {
  return {
    argumentsJSON: JSON.stringify({ actions: argumentsObject, note }),
    id: id("call"),
    name,
  };
}

function toolResult(step, callID, text) {
  return message({
    role: "tool",
    content: text,
    step,
    toolCallID: callID,
    toolName: "act",
  });
}

const now = Date.now();
const trajectories = join(dataDir, "trajectories");
await mkdir(trajectories, { recursive: true });

for (let index = 0; index < count; index += 1) {
  const runID = `synthetic-${new Date(now + index * 1000)
    .toISOString()
    .replace(/[:.]/g, "-")}-${index}`;
  const runDir = join(trajectories, runID);
  const captures = join(runDir, "captures");
  await mkdir(captures, { recursive: true });
  for (const file of captureFiles) {
    await cp(join(sourceCaptures, file), join(captures, file));
  }

  const stepCaptures = captureFiles.slice(0, 5).map((file) => join(captures, file));
  const task = tasks[index % tasks.length];
  const actions = [
    [{ type: "click", cell: "G3" }],
    [{ type: "type", text: "Ada" }],
    [{ type: "click", cell: "C4" }],
    [{ type: "click", cell: "B5" }],
  ];
  const messages = [
    message({ role: "user", content: task, step: 0 }),
    message({
      role: "user",
      content:
        "Initial capture. Step 0, grid A-T by 1-12, 1280 by 720 points, viewport 1280 by 720 points",
      imagePaths: [stepCaptures[0]],
      step: 0,
    }),
  ];

  for (let step = 1; step <= 4; step += 1) {
    const call = toolCall(step, "act", actions[step - 1], notes[step - 1]);
    messages.push(
      message({ role: "assistant", content: "", step, toolCalls: [call] })
    );
    const result =
      step === 1
        ? "1 click G3: delivered"
        : step === 2
          ? "1 type Ada: delivered"
          : step === 3
            ? "1 click C4: delivered"
            : "1 click B5: delivered";
    messages.push(
      toolResult(
        step,
        call.id,
        `${result}\nStep ${step}, grid A-T by 1-12, 1280 by 720 points, viewport 1280 by 720 points\nA capture follows.`
      )
    );
    if (step < 4 && stepCaptures[step]) {
      messages.push(
        message({
          role: "user",
          content: `A capture follows. Step ${step}, grid A-T by 1-12, 1280 by 720 points, viewport 1280 by 720 points`,
          imagePaths: [stepCaptures[step]],
          step,
        })
      );
    }
  }
  messages.push(
    message({
      role: "assistant",
      content: "I typed Ada, ticked the agreement, and clicked Submit.",
      step: 4,
    })
  );

  const record = {
    version: 1,
    id: id("run"),
    task,
    siteLabel: "synthetic-hello",
    seed: null,
    adapterID: null,
    systemPrompt: sourceConversation.systemPrompt,
    status: "finished",
    messages,
    steps: [],
    finalReply: "I typed Ada, ticked the agreement, and clicked Submit.",
    lastURL:
      sourceConversation.lastURL ||
      pathToFileURL(join(dataDir, "environments/hello/site/index.html")).href,
    createdAt: new Date(now + index * 1000).toISOString(),
    updatedAt: new Date(now + index * 1000).toISOString(),
    stepCount: 4,
    turnCount: 5,
    grid: sourceConversation.grid,
    viewport: sourceConversation.viewport,
  };

  await writeFile(join(runDir, "conversation.json"), JSON.stringify(record, null, 2));
  await writeFile(
    join(runDir, "rating.json"),
    JSON.stringify(
      { score: 90, justification: "Synthetic teacher run for the basic hello form." },
      null,
      2
    )
  );
  await writeFile(
    join(runDir, "verify.json"),
    JSON.stringify(
      {
        verdict: "success",
        score: 1,
        pointerMissShare: 0,
        stepCount: 4,
        turnCount: 5,
      },
      null,
      2
    )
  );
}

console.log(
  `Wrote ${count} synthetic runs from ${basename(source)} to ${trajectories}`
);
