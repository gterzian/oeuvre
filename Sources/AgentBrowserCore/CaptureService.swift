import CoreGraphics
import Foundation

struct Capture: @unchecked Sendable {
    var image: CGImage
    var png: Data
    var grid: GridDescriptor
    var viewport: CGSize
    var step: Int
    var caption: String
}

enum SettleOutcome: Sendable {
    case settled
    case stillActive
}

/// Opt-in composition tracing. Set `AGENT_BROWSER_TRACE_LAYERS=1` to see each
/// composition's layer count in the app log.
private let traceComposition = ProcessInfo.processInfo.environment["AGENT_BROWSER_TRACE_LAYERS"] != nil

/// Whether captions carry the grid overlay. `AGENT_BROWSER_GRID=0` turns it
/// off so a run can compare the page alone against the gridded capture.
private let drawGrid = ProcessInfo.processInfo.environment["AGENT_BROWSER_GRID"] != "0"

/// Composes captures from the layer store, draws the grid, and owns the
/// capture points: after a batch, on a `capture` call and at the end of a
/// `wait`. It is the only place that grants rendering opportunities while a
/// task runs.
final class CaptureService: @unchecked Sendable {
    let store: LayerStore
    weak var engine: EngineBridge?
    private let lock = NSLock()
    private var lastBase: CGImage?
    private var lastBaseGeneration = -1
    private var baseGrid: GridDescriptor
    private var activeGrid: GridDescriptor
    private var lastCaptureMark = 0
    private var navigationMark = 0
    private var recent: [Capture] = []

    init(store: LayerStore, engine: EngineBridge, grid: GridDescriptor) {
        self.store = store
        self.engine = engine
        self.baseGrid = grid
        self.activeGrid = grid
        self.lastCaptureMark = store.changeMark
    }

    var grid: GridDescriptor {
        lock.withLock { activeGrid }
    }

    var recentCaptures: [Capture] {
        lock.withLock { recent }
    }

    func noteNavigation() {
        lock.withLock { navigationMark += 1 }
    }

    func updateViewport(_ size: CGSize, grid: GridDescriptor) {
        store.setViewport(size)
        lock.withLock {
            baseGrid = grid
            activeGrid = grid
        }
    }

    // MARK: - Capture points

    /// After a batch of actions. The caller has already applied the batch; one
    /// opportunity starts the render, and the settling loop follows queued
    /// updates and animations to their quiet point.
    func captureAfterActions(step: Int, timeout: TimeInterval = 10) async -> Capture {
        let outcome = await settle(timeout: timeout)
        return await makeCapture(step: step, region: nil, note: outcome)
    }

    /// A `capture` call. Reuses the last composition when no change is marked.
    func captureNow(step: Int, region: CGRect?, frames: Int, frameInterval: TimeInterval = 0.12) async -> [Capture] {
        let count = max(1, min(frames, 6))
        if count > 1 {
            var captures: [Capture] = []
            for index in 0..<count {
                _ = await settle(timeout: 2)
                captures.append(await makeCapture(step: step, region: region, note: .settled))
                if index < count - 1 {
                    try? await Task.sleep(for: .seconds(frameInterval))
                }
            }
            return captures
        }
        if store.changeMark > lastCaptureMark {
            _ = await settle(timeout: 5)
        }
        return [await makeCapture(step: step, region: region, note: .settled)]
    }

    func wait(milliseconds: Int) async -> Capture {
        if milliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
        let outcome = await settle(timeout: 10)
        return await makeCapture(step: 0, region: nil, note: outcome)
    }

    /// `wait` with `until: change`: no opportunity is granted while waiting.
    /// A `request_next_frame` callback settles the tab; a visible difference
    /// from the last capture ends the wait.
    func waitUntilChange(maxMilliseconds: Int, step: Int) async -> (Capture, Bool) {
        let baseline = ImageSupport.hash(currentBaseImage())
        let deadline = Date().addingTimeInterval(Double(maxMilliseconds) / 1000)
        var seenMark = store.changeMark
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            guard store.changeMark > seenMark else { continue }
            seenMark = store.changeMark
            _ = await settle(timeout: 3)
            let image = currentBaseImage()
            if ImageSupport.hash(image) != baseline {
                return (await makeCapture(step: step, region: nil, note: .settled), true)
            }
        }
        return (await makeCapture(step: step, region: nil, note: .stillActive), false)
    }

    // MARK: - Settling

    func settle(timeout: TimeInterval = 10) async -> SettleOutcome {
        guard let engine else { return .stillActive }
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var lastGeneration = store.currentGeneration
        var grantedMark = store.changeMark
        var sawComposition = store.currentGeneration > 0
        var quietStart = Date()
        var lastActivity = Date()
        var lastNavigationMark = navigationMark
        engine.frameNeeded()
        while Date() < deadline {
            let generation = store.currentGeneration
            if generation != lastGeneration {
                lastGeneration = generation
                sawComposition = true
                quietStart = Date()
                lastActivity = Date()
            }
            let mark = store.changeMark
            if mark > grantedMark {
                grantedMark = mark
                engine.frameNeeded()
                quietStart = Date()
                lastActivity = Date()
            }
            let navigation = navigationMark
            if navigation != lastNavigationMark {
                lastNavigationMark = navigation
                quietStart = Date()
                lastActivity = Date()
            }
            let elapsed = Date().timeIntervalSince(start)
            if sawComposition, elapsed > 0.2, Date().timeIntervalSince(quietStart) > 0.16 {
                return .settled
            }
            if !sawComposition, Date().timeIntervalSince(lastActivity) > 1.0 {
                return .stillActive
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return .stillActive
    }

    // MARK: - Composition

    func currentBaseImage() -> CGImage {
        lock.lock()
        let generation = store.currentGeneration
        if lastBaseGeneration == generation, let lastBase {
            lock.unlock()
            return lastBase
        }
        lock.unlock()
        let layers = store.snapshot()
        let viewport = store.viewportSize
        if traceComposition {
            let withImages = layers.filter { $0.image != nil }.count
            AgentLog.write(
                "compose generation=\(generation) layers=\(layers.count) with-images=\(withImages) viewport=\(Int(viewport.width))x\(Int(viewport.height))"
            )
        }
        let image = Compositor.compose(layers: layers, viewport: viewport)
            ?? emptyImage(size: viewport)
        lock.lock()
        lastBase = image
        lastBaseGeneration = generation
        lock.unlock()
        return image
    }

    func screenshotPNG() -> Data? {
        guard let image = currentBaseImage() as CGImage? else { return nil }
        return ImageSupport.pngData(image)
    }

    private func makeCapture(step: Int, region: CGRect?, note: SettleOutcome) async -> Capture {
        let viewport = store.viewportSize
        let base = currentBaseImage()
        let descriptor: GridDescriptor
        let image: CGImage
        if let region {
            let grid = lock.withLock { activeGrid }
            let refined = grid.refined(region: region)
            descriptor = refined
            image = cropAndScale(base, region: refined.origin, scale: 2, grid: refined, viewport: viewport)
        } else {
            descriptor = lock.withLock { baseGrid }
            image = drawGrid ? overlay(base, grid: descriptor, viewport: viewport) : base
        }
        let png = ImageSupport.pngData(image) ?? Data()
        let status = note == .stillActive ? " — still active after the deadline" : ""
        let caption = "Step \(step), \(descriptor.caption), viewport \(Int(viewport.width)) by \(Int(viewport.height)) points\(status)"
        let capture = Capture(
            image: image,
            png: png,
            grid: descriptor,
            viewport: viewport,
            step: step,
            caption: caption
        )
        lock.withLock {
            activeGrid = descriptor
            lastCaptureMark = store.changeMark
            recent.append(capture)
            if recent.count > 8 { recent.removeFirst(recent.count - 8) }
        }
        return capture
    }

    private func overlay(_ image: CGImage, grid: GridDescriptor, viewport: CGSize) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: Int(viewport.width.rounded()),
            height: Int(viewport.height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: Int(viewport.width.rounded()) * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return image }
        context.draw(image, in: CGRect(origin: .zero, size: viewport))
        GridOverlay.draw(on: context, image: image, grid: grid, viewport: viewport)
        return context.makeImage() ?? image
    }

    private func cropAndScale(
        _ image: CGImage,
        region: CGRect,
        scale: CGFloat,
        grid: GridDescriptor,
        viewport: CGSize
    ) -> CGImage {
        let clipped = region.intersection(CGRect(origin: .zero, size: viewport))
        let width = max(1, Int((clipped.width * scale).rounded()))
        let height = max(1, Int((clipped.height * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return image }
        // The composed image uses a bottom-left CoreGraphics origin. Crop in
        // top-left points and convert the y edge for the CG draw.
        let source = clipped
        if let cropped = image.cropping(to: source) {
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if drawGrid {
            let local = GridDescriptor(
                origin: CGRect(x: 0, y: 0, width: width, height: height),
                columns: grid.columns,
                rows: grid.rows
            )
            GridOverlay.draw(
                on: context,
                image: context.makeImage() ?? image,
                grid: local,
                viewport: CGSize(width: width, height: height)
            )
        }
        return context.makeImage() ?? image
    }

    private func emptyImage(size: CGSize) -> CGImage {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
