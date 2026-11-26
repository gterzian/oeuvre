# Sources

- `CEngine/` is the C header and module map for the Rust binding.
- `AgentBrowserModel/` is the only MLX target: model loading, chat generation,
  LoRA loading and the training step.
- `AgentBrowserCore/` is the harness: the engine bridge, the layer store and
  capture service, actions, the loop, the conversation file, the CDP `Agent`
  domain, the trainer, and the AppKit window.
- `AgentBrowser/` is the executable entry point.

The main window is a debugging view of the agent's frames: the task panel, the
composed capture, and the conversation debug panel. The capture service is the
only place that grants rendering opportunities while a task runs.
