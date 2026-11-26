import CoreGraphics
import Foundation

struct CellTarget: Sendable, Equatable {
    var cell: String
    var at: CGPoint?
}

enum WaitSpec: Sendable, Equatable {
    case milliseconds(Int)
    case change(maxMilliseconds: Int)
}

enum AgentAction: Sendable, Equatable {
    case click(CellTarget, button: String)
    case move(CellTarget)
    case drag(from: CellTarget, to: CellTarget)
    case scroll(CellTarget, dx: Double, dy: Double)
    case key(String, modifiers: [String])
    case type(String)
    case wait(WaitSpec)
}

enum ActionParser {
    static func parse(arguments: [String: Any]) -> [AgentAction] {
        guard let raw = arguments["actions"] else { return [] }
        if let objects = raw as? [[String: Any]] {
            return objects.compactMap { parseOne($0) }
        }
        if let object = raw as? [String: Any] {
            return [parseOne(object)].compactMap { $0 }
        }
        // Small models sometimes flatten the schema to a string sequence:
        // ["click", "B3", "type", "Ada"]. Accept it rather than discarding
        // an otherwise unambiguous batch.
        if let values = raw as? [Any] {
            return parseCompact(values)
        }
        if let text = raw as? String {
            let parts = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            return parseCompact(parts.map(String.init))
        }
        return []
    }

    private static func parseCompact(_ values: [Any]) -> [AgentAction] {
        var actions: [AgentAction] = []
        var index = 0
        while index < values.count {
            guard let rawType = values[index] as? String else {
                index += 1
                continue
            }
            let type = rawType.lowercased()
            switch type {
            case "click", "move", "scroll":
                guard index + 1 < values.count,
                      let cell = cellName(values[index + 1])
                else { index += 1; continue }
                let target = CellTarget(cell: cell, at: nil)
                switch type {
                case "click": actions.append(.click(target, button: "main"))
                case "move": actions.append(.move(target))
                default: actions.append(.scroll(target, dx: 0, dy: 0))
                }
                index += 2
            case "type":
                guard index + 1 < values.count,
                      let text = values[index + 1] as? String
                else { index += 1; continue }
                actions.append(.type(text))
                index += 2
            case "key":
                guard index + 1 < values.count,
                      let key = values[index + 1] as? String
                else { index += 1; continue }
                actions.append(.key(key, modifiers: []))
                index += 2
            case "wait":
                let rawMilliseconds = index + 1 < values.count ? values[index + 1] : nil
                let milliseconds = Int(number(rawMilliseconds) ?? 250)
                actions.append(.wait(.milliseconds(max(0, min(milliseconds, 30_000)))))
                index += 2
            case "drag":
                guard index + 2 < values.count,
                      let from = cellName(values[index + 1]),
                      let to = cellName(values[index + 2])
                else { index += 1; continue }
                actions.append(.drag(
                    from: CellTarget(cell: from, at: nil),
                    to: CellTarget(cell: to, at: nil)
                ))
                index += 3
            default:
                index += 1
            }
        }
        return actions
    }

    /// A short label for the debug history, tolerant of both the object and
    /// the compact action shapes.
    static func summary(arguments: [String: Any]) -> String {
        let raw = arguments["actions"]
        if let objects = raw as? [[String: Any]] {
            return objects.map { $0["type"] as? String ?? "?" }.joined(separator: ", ")
        }
        if let values = raw as? [Any] {
            let known: Set<String> = ["click", "move", "drag", "scroll", "key", "type", "wait"]
            return values.compactMap { ($0 as? String)?.lowercased() }
                .filter { known.contains($0) }
                .joined(separator: ", ")
        }
        return "?"
    }

    /// The action name. Small models sometimes put it under `key` (as in
    /// `{"key":"type","text":"Ada"}`) or omit it and leave only the fields
    /// that identify the action. Infer the action from those fields.
    private static func inferredType(_ object: [String: Any]) -> String {
        if let type = object["type"] as? String {
            let known: Set<String> = ["click", "move", "drag", "scroll", "key", "type", "wait"]
            if known.contains(type.lowercased()) { return type.lowercased() }
        }
        if object["text"] != nil { return "type" }
        if object["from"] != nil, object["to"] != nil { return "drag" }
        if object["dx"] != nil || object["dy"] != nil { return "scroll" }
        if object["cell"] != nil { return "click" }
        if object["key"] != nil {
            // `key` is the action name when it names a known action; otherwise
            // it is the key to press.
            let key = (object["key"] as? String ?? "").lowercased()
            let known: Set<String> = ["click", "move", "drag", "scroll", "key", "type", "wait"]
            return known.contains(key) ? key : "key"
        }
        if object["until"] != nil || object["ms"] != nil || object["max_ms"] != nil {
            return "wait"
        }
        return ""
    }

    private static func cellName(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let object = value as? [String: Any] { return object["cell"] as? String }
        return nil
    }

    static func parseOne(_ object: [String: Any]) -> AgentAction? {
        let type = inferredType(object)
        switch type {
        case "click":
            guard let target = target(object) else { return nil }
            return .click(target, button: (object["button"] as? String ?? "main").lowercased())
        case "move":
            guard let target = target(object) else { return nil }
            return .move(target)
        case "drag":
            guard let from = object["from"] as? [String: Any],
                  let to = object["to"] as? [String: Any],
                  let fromTarget = target(from),
                  let toTarget = target(to)
            else { return nil }
            return .drag(from: fromTarget, to: toTarget)
        case "scroll":
            guard let target = target(object) else { return nil }
            return .scroll(
                target,
                dx: number(object["dx"]) ?? 0,
                dy: number(object["dy"]) ?? 0
            )
        case "key":
            guard let key = object["key"] as? String else { return nil }
            let modifiers = (object["modifiers"] as? [String]) ?? []
            return .key(key, modifiers: modifiers)
        case "type":
            guard let text = object["text"] as? String else { return nil }
            return .type(text)
        case "wait":
            if let until = object["until"] as? String, until.lowercased() == "change" {
                let maxMs = Int(number(object["max_ms"]) ?? 5_000)
                return .wait(.change(maxMilliseconds: max(100, min(maxMs, 30_000))))
            }
            let ms = Int(number(object["ms"]) ?? number(object["duration_ms"]) ?? 250)
            return .wait(.milliseconds(max(0, min(ms, 30_000))))
        default:
            return nil
        }
    }

    private static func target(_ object: [String: Any]) -> CellTarget? {
        guard let cell = object["cell"] as? String else { return nil }
        return CellTarget(cell: cell, at: point(object["at"]))
    }

    private static func point(_ value: Any?) -> CGPoint? {
        if let array = value as? [NSNumber], array.count >= 2 {
            return CGPoint(x: array[0].doubleValue, y: array[1].doubleValue)
        }
        if let object = value as? [String: Any] {
            let x = number(object["x"]) ?? 0.5
            let y = number(object["y"]) ?? 0.5
            return CGPoint(x: x, y: y)
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

enum ActionPlayer {
    /// Applies one batch and returns the result line for each action. Rendering
    /// opportunities stay suppressed while the batch runs: the caller grants
    /// one after the last action, so the input events accumulate as one
    /// batched UI update.
    static func apply(
        _ actions: [AgentAction],
        grid: GridDescriptor,
        engine: EngineBridge
    ) -> [String] {
        var lines: [String] = []
        for (index, action) in actions.enumerated() {
            let number = index + 1
            let outcome: String
            switch action {
            case .click(let target, let button):
                guard let point = grid.point(label: target.cell, at: target.at) else {
                    lines.append("\(number) click \(target.cell): rejected, the cell lies outside the grid")
                    continue
                }
                outcome = click(point: point, button: button, engine: engine)
                lines.append("\(number) click \(target.cell): \(outcome)")
            case .move(let target):
                guard let point = grid.point(label: target.cell, at: target.at) else {
                    lines.append("\(number) move \(target.cell): rejected, the cell lies outside the grid")
                    continue
                }
                outcome = pointer(phase: "move", point: point, buttons: 0, engine: engine)
                lines.append("\(number) move \(target.cell): \(outcome)")
            case .drag(let from, let to):
                guard let start = grid.point(label: from.cell, at: from.at),
                      let end = grid.point(label: to.cell, at: to.at)
                else {
                    lines.append("\(number) drag \(from.cell) to \(to.cell): rejected, a cell lies outside the grid")
                    continue
                }
                outcome = drag(from: start, to: end, engine: engine)
                lines.append("\(number) drag \(from.cell) to \(to.cell): \(outcome)")
            case .scroll(let target, let dx, let dy):
                guard let point = grid.point(label: target.cell, at: target.at) else {
                    lines.append("\(number) scroll \(target.cell): rejected, the cell lies outside the grid")
                    continue
                }
                outcome = scroll(point: point, dx: dx, dy: dy, engine: engine)
                lines.append("\(number) scroll \(target.cell): \(outcome)")
            case .key(let key, let modifiers):
                outcome = press(key: key, modifiers: modifiers, engine: engine)
                lines.append("\(number) key \(key): \(outcome)")
            case .type(let text):
                outcome = type(text: text, engine: engine)
                lines.append("\(number) type \(preview(text)): \(outcome)")
            case .wait(.milliseconds(let milliseconds)):
                Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
                lines.append("\(number) wait \(milliseconds) ms: delivered")
            case .wait(.change(let maxMilliseconds)):
                lines.append("\(number) wait until change, max \(maxMilliseconds) ms: handled by the harness")
            }
        }
        return lines
    }

    private static func preview(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: "\n", with: "\\n")
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }

    private static func click(point: CGPoint, button: String, engine: EngineBridge) -> String {
        let buttons = button == "secondary" ? 2 : 1
        var ok = pointer(phase: "move", point: point, buttons: 0, engine: engine) == "delivered"
        ok = pointer(phase: "down", point: point, buttons: buttons, button: button, engine: engine) == "delivered" && ok
        ok = pointer(phase: "up", point: point, buttons: 0, button: button, engine: engine) == "delivered" && ok
        return ok ? "delivered" : "rejected, the engine refused the event"
    }

    private static func drag(from: CGPoint, to: CGPoint, engine: EngineBridge) -> String {
        var ok = pointer(phase: "move", point: from, buttons: 0, engine: engine) == "delivered"
        ok = pointer(phase: "down", point: from, buttons: 1, engine: engine) == "delivered" && ok
        let steps = 8
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            ok = pointer(phase: "move", point: point, buttons: 1, engine: engine) == "delivered" && ok
        }
        ok = pointer(phase: "up", point: to, buttons: 0, engine: engine) == "delivered" && ok
        return ok ? "delivered" : "rejected, the engine refused an event"
    }

    private static func scroll(point: CGPoint, dx: Double, dy: Double, engine: EngineBridge) -> String {
        _ = pointer(phase: "move", point: point, buttons: 0, engine: engine)
        let event: [String: Any] = [
            "type": "wheel",
            "x": point.x,
            "y": point.y,
            "dx": dx,
            "dy": dy,
            "modifiers": 0,
        ]
        return engine.send(JSON.string(event)) ? "delivered" : "rejected, the engine refused the event"
    }

    private static func pointer(
        phase: String,
        point: CGPoint,
        buttons: Int,
        button: String = "main",
        engine: EngineBridge
    ) -> String {
        let event: [String: Any] = [
            "type": "pointer",
            "phase": phase,
            "x": point.x,
            "y": point.y,
            "buttons": buttons,
            "button": button,
            "modifiers": 0,
        ]
        return engine.send(JSON.string(event)) ? "delivered" : "rejected, the engine refused the event"
    }

    private static func press(key: String, modifiers: [String], engine: EngineBridge) -> String {
        let bits = modifierBits(modifiers)
        let code = keyCode(for: key)
        let shifted = modifiers.contains { $0.lowercased() == "shift" }
        let text = key.count == 1 && shifted ? key.uppercased() : key
        let down: [String: Any] = [
            "type": "key",
            "phase": "down",
            "key": key,
            "code": code,
            "text": key.count == 1 ? text : NSNull(),
            "modifiers": bits,
        ]
        let up: [String: Any] = [
            "type": "key",
            "phase": "up",
            "key": key,
            "code": code,
            "text": NSNull(),
            "modifiers": bits,
        ]
        let ok = engine.send(JSON.string(down)) && engine.send(JSON.string(up))
        return ok ? "delivered" : "rejected, the engine refused the event"
    }

    private static func type(text: String, engine: EngineBridge) -> String {
        for character in text {
            if character == "\n" {
                if press(key: "Enter", modifiers: [], engine: engine) != "delivered" {
                    return "rejected, the engine refused a key event"
                }
            } else if character.isASCII {
                if press(key: String(character), modifiers: [], engine: engine) != "delivered" {
                    return "rejected, the engine refused a key event"
                }
            } else {
                let event: [String: Any] = [
                    "type": "ime",
                    "text": String(character),
                ]
                if !engine.send(JSON.string(event)) {
                    return "rejected, the engine refused an IME event"
                }
            }
        }
        return "delivered"
    }

    private static func modifierBits(_ modifiers: [String]) -> Int {
        var bits = 0
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "alt", "option": bits |= 0x01
            case "control", "ctrl": bits |= 0x08
            case "meta", "command", "cmd": bits |= 0x40
            case "shift": bits |= 0x200
            default: break
            }
        }
        return bits
    }

    static func keyCode(for key: String) -> String {
        if key.count == 1, let scalar = key.uppercased().unicodeScalars.first {
            switch scalar.value {
            case 65...90: return "Key\(key.uppercased())"
            case 48...57: return "Digit\(key)"
            case 32: return "Space"
            case 46: return "Period"
            case 44: return "Comma"
            case 47: return "Slash"
            case 59: return "Semicolon"
            case 39: return "Quote"
            case 91: return "BracketLeft"
            case 93: return "BracketRight"
            case 92: return "Backslash"
            case 45: return "Minus"
            case 61: return "Equal"
            case 96: return "Backquote"
            default: return "Unidentified"
            }
        }
        switch key {
        case "Enter", "Return": return "Enter"
        case "Tab": return "Tab"
        case "Escape", "Esc": return "Escape"
        case "Backspace": return "Backspace"
        case "Delete": return "Delete"
        case "ArrowUp": return "ArrowUp"
        case "ArrowDown": return "ArrowDown"
        case "ArrowLeft": return "ArrowLeft"
        case "ArrowRight": return "ArrowRight"
        case "Home": return "Home"
        case "End": return "End"
        case "PageUp": return "PageUp"
        case "PageDown": return "PageDown"
        case "Space": return "Space"
        default: return "Unidentified"
        }
    }
}
