import CoreGraphics
import Foundation

struct LayerSurface: @unchecked Sendable {
    enum Kind {
        case sharedTexture(UInt32)
        case cpu(Data, Int)
    }
    var kind: Kind
    var width: Int
    var height: Int
}

struct LayerSnapshot: @unchecked Sendable {
    var id: String
    var parent: String?
    var transform: CGAffineTransform
    var clipBounds: CGRect
    var cornerRadius: CGFloat
    var zIndex: Int
    var paintOrder: UInt32
    var width: Int
    var height: Int
    var image: CGImage?
}

/// Holds the latest topology and surface of every layer. A layer that did not
/// change arrives as topology only, so the store keeps its last image until a
/// new one arrives.
final class LayerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var layers: [String: LayerSnapshot] = [:]
    private var generation = 0
    private var requestNextFrameCount = 0
    private var lastCompositionKind = 0
    private var viewport = CGSize(width: 1280, height: 720)

    func setViewport(_ size: CGSize) {
        lock.lock()
        viewport = size
        lock.unlock()
    }

    var viewportSize: CGSize {
        lock.lock()
        defer { lock.unlock() }
        return viewport
    }

    func noteRequestNextFrame() {
        lock.lock()
        requestNextFrameCount += 1
        lock.unlock()
    }

    var changeMark: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestNextFrameCount
    }

    var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    var latestCompositionKind: Int {
        lock.lock()
        defer { lock.unlock() }
        return lastCompositionKind
    }

    func apply(_ incoming: [LayerSnapshot], compositionKind: Int) {
        lock.lock()
        var next: [String: LayerSnapshot] = [:]
        for layer in incoming {
            var stored = layer
            if stored.image == nil, let previous = layers[stored.id] {
                stored.image = previous.image
            }
            next[stored.id] = stored
        }
        layers = next
        lastCompositionKind = compositionKind
        generation += 1
        lock.unlock()
    }

    func snapshot() -> [LayerSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return layers.values.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            return lhs.paintOrder < rhs.paintOrder
        }
    }

    func clear() {
        lock.lock()
        layers.removeAll()
        generation += 1
        lock.unlock()
    }
}
