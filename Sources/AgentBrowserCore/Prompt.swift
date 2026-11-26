import Foundation
import MLXLMCommon

struct PromptContext: Sendable {
    var viewportWidth: Int
    var viewportHeight: Int
    var columns: Int
    var rows: Int
    var recentCaptures: Int
    var gridVisible: Bool
}

enum BrowserPrompt {
    static func system(_ context: PromptContext) -> String {
        let gridDescription = context.gridVisible
            ? """
            A grid lies over each capture. Columns have letters and rows have
            numbers along the edges, and every cell shows its name in a corner, for
            example F7. The viewport is \(context.viewportWidth) by \(context.viewportHeight) points
            and the grid has \(context.columns) columns and \(context.rows) rows.
            """
            : """
            The capture has no grid overlay. The viewport is \(context.viewportWidth) by
            \(context.viewportHeight) points, and the action grid still has \(context.columns)
            columns and \(context.rows) rows. Estimate the cell from where the target
            sits in the viewport.
            """
        return """
        You are the browser agent of an app that lets a person work in web pages.
        You operate a browser the way a person does: you look at the page as an
        image and act through the mouse and the keyboard.

        What you see
        - After every batch of actions you receive a capture: an image of the page,
          taken once the page has settled.
        - \(gridDescription)
        - You see the newest \(context.recentCaptures) captures as images. Older captures
          appear as a line of text. Your notes carry what you learned from them.

        How you act
        - Call the tool act with a batch of actions: click, move, drag, scroll,
          key, type and wait. A click is a pointer move followed by pressing and
          releasing the main button at the center of the named cell. Add "at" with
          fractions of the cell's width and height to aim at a smaller target.
          The actions field is an array of objects, for example
          [{"type":"click","cell":"B3"},{"type":"type","text":"Ada"}]. Do not
          send bare strings such as ["click","B3"].
        - A move places the pointer without pressing, which opens menus that open
          on hover. A scroll turns the wheel at the named cell, and the content
          under the pointer scrolls by dx and dy pixels (positive is down and to
          the right).
        - Typing goes to the element that has focus. Click a field first and then
          type. Press keys by name: Enter, Tab, Escape, Backspace, ArrowDown, or a
          single character, with modifiers Control, Alt, Shift and Meta.
        - Send every action that you can decide from the current capture in one
          batch. Filling in a form is one batch: click each field and type each
          value. Look at the capture that follows before you submit.
        - Start with act. The first capture is already in front of you, so your
          first call is a batch of actions, not a description of the page.
          Keep reasoning short: the task is a browser action, not an essay.
        - Call capture with a region of cells to see it at higher resolution with a
          finer grid whose labels are local to the region. Click on the refined
          capture by naming a cell of its finer grid. Ask for several frames to
          watch an animation or a short-lived message.
        - Use wait for slow pages. A wait with ms pauses for that long. A wait with
          until set to "change" and max_ms returns a capture as soon as the page
          visibly changes, or when max_ms has passed.

        How results arrive
        - The result of act lists each action with its outcome.
        - The tab reports "settled" once the page has finished loading and
          animating, or "still active" together with the capture after a deadline.

        Your notes
        - Every act call has a note. Write what you observed on the page, what you
          just did and what comes next. The notes are your memory of the task, and
          you read them again at every step.

        Instructions
        - The task text and the messages of the person are your instructions.
        - Do not describe the page or restate the task before acting.
        - When the task is complete, reply with a short report of what you did and
          what you found, and make no tool call. When you cannot continue, say what
          stopped you.
        """
    }

    static let tools: [ToolSpec] = [
        [
            "type": "function",
            "function": [
                "name": "act",
                "description":
                    "Apply one batch of browser actions. The result carries a capture taken after the page settles.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "note": [
                            "type": "string",
                            "description":
                                "What you observed, what you just did, and what comes next.",
                        ] as [String: any Sendable],
                        "actions": [
                            "type": "array",
                            "description": "The actions to apply in order.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "type": [
                                        "type": "string",
                                        "enum": ["click", "move", "drag", "scroll", "key", "type", "wait"],
                                    ] as [String: any Sendable],
                                    "cell": [
                                        "type": "string",
                                        "description": "The grid cell, for example F7.",
                                    ] as [String: any Sendable],
                                    "at": [
                                        "type": "array",
                                        "description":
                                            "Fractions of the cell's width and height, for example [0.33, 0.5].",
                                        "items": ["type": "number"] as [String: any Sendable],
                                    ] as [String: any Sendable],
                                    "button": [
                                        "type": "string",
                                        "enum": ["main", "secondary"],
                                    ] as [String: any Sendable],
                                    "from": ["type": "object"] as [String: any Sendable],
                                    "to": ["type": "object"] as [String: any Sendable],
                                    "dx": ["type": "number"] as [String: any Sendable],
                                    "dy": ["type": "number"] as [String: any Sendable],
                                    "key": [
                                        "type": "string",
                                        "description": "A key name such as Enter, Tab or ArrowDown, or one character.",
                                    ] as [String: any Sendable],
                                    "modifiers": [
                                        "type": "array",
                                        "items": ["type": "string"] as [String: any Sendable],
                                    ] as [String: any Sendable],
                                    "text": ["type": "string"] as [String: any Sendable],
                                    "ms": ["type": "integer"] as [String: any Sendable],
                                    "until": [
                                        "type": "string",
                                        "enum": ["change"],
                                    ] as [String: any Sendable],
                                    "max_ms": ["type": "integer"] as [String: any Sendable],
                                ] as [String: any Sendable],
                                "required": ["type"],
                            ] as [String: any Sendable],
                        ] as [String: any Sendable],
                    ] as [String: any Sendable],
                    "required": ["note", "actions"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ],
        [
            "type": "function",
            "function": [
                "name": "capture",
                "description":
                    "Request a capture, optionally of a region at higher resolution or several frames of an animation.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "region": [
                            "type": "string",
                            "description":
                                "A cell or rectangle of cells, for example H4 or A1:D6. The returned grid is local to the region.",
                        ] as [String: any Sendable],
                        "frames": [
                            "type": "integer",
                            "description": "How many frames to capture, from one to six.",
                        ] as [String: any Sendable],
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ],
    ]
}
