import AppKit
import Metal
import QuartzCore

@_silgen_name("CGSCurrentCursorSeed") private func CGSCurrentCursorSeed() -> Int32
@_silgen_name("CGCursorIsVisible") private func CGCursorIsVisible() -> Int32

/// Puts filtered frames on the panel and draws the mouse pointer itself at its live position,
/// presenting as soon as anything changes but at most once per panel refresh.
///
/// Why: a pointer baked into captured frames trails the hand by the whole chain
/// (WindowServer composite → capture → filter → present). Captured frames therefore come
/// without the pointer; it is composited here, one refresh before scan-out.
final class PanelPresenter {
    struct Pointer: Equatable {
        /// Top-left of the pointer image in panel pixels.
        var origin: CGPoint
        var seed: Int32
    }

    var onFirstPresent: (() -> Void)?

    private let filter: SubpixelFilter
    private let layer: CAMetalLayer
    private let pointerPipeline: MTLRenderPipelineState
    private let frameInterval: CFTimeInterval

    // Shared between the capture queue and the main thread.
    private let lock = NSLock()
    private var panel: MTLTexture?
    private var panelSize = CGSize.zero
    private var lastSource: (texture: MTLTexture, keepAlive: AnyObject)?
    private var contentDirty = false

    // Main thread only.
    private var shownPointer: Pointer?
    private var pointerTexture: MTLTexture?
    private var pointerHotspot = CGPoint.zero
    private var pointerSeed: Int32 = .min
    private var pointerScale: CGFloat = 0
    private var presentedOnce = false
    private var lastPresent: CFTimeInterval = 0
    private var presentScheduled = false

    init(filter: SubpixelFilter, layer: CAMetalLayer, refreshRate: Double) throws {
        self.filter = filter
        self.layer = layer
        self.frameInterval = 1 / max(refreshRate, 24)
        let library = try filter.device.makeLibrary(source: Self.shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "pointerVertex")
        desc.fragmentFunction = library.makeFunction(name: "pointerFragment")
        let color = desc.colorAttachments[0]!
        color.pixelFormat = layer.pixelFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one  // pointer image is premultiplied
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pointerPipeline = try filter.device.makeRenderPipelineState(descriptor: desc)
    }

    /// Main thread, whenever the panel's pixel size may have changed.
    func setPanelSize(_ size: CGSize) {
        lock.withLock {
            guard size != panelSize else { return }
            panelSize = size
            panel = nil  // re-made and re-filtered from the last frame on the next tick
            contentDirty = lastSource != nil
        }
    }

    /// Capture queue: a new desktop frame.
    func submit(_ source: MTLTexture, keepAlive: AnyObject) {
        lock.withLock {
            lastSource = (source, keepAlive)
            filterIntoPanel()
            contentDirty = true
        }
    }

    /// Main thread: something may have changed (frame arrived, mouse moved). Presents now, or
    /// right after the current refresh interval if one was presented within it.
    func requestFrame(virtualBounds: CGRect) {
        guard !presentScheduled else { return }
        let wait = lastPresent + frameInterval * 0.9 - CACurrentMediaTime()
        guard wait > 0 else { return present(virtualBounds: virtualBounds) }
        presentScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.presentScheduled = false
            self?.present(virtualBounds: virtualBounds)
        }
    }

    private func present(virtualBounds: CGRect) {
        let pointer = currentPointer(virtualBounds: virtualBounds)
        let content: MTLTexture? = lock.withLock {
            if panel == nil, lastSource != nil { filterIntoPanel() }
            guard let panel, contentDirty || pointer != shownPointer else { return nil }
            contentDirty = false
            return panel
        }
        guard let content, let drawable = layer.nextDrawable(), let commandBuffer = filter.queue.makeCommandBuffer() else { return }
        shownPointer = pointer
        lastPresent = CACurrentMediaTime()

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: content, to: drawable.texture)
            blit.endEncoding()
        }
        if let pointer, let texture = pointerTexture {
            drawPointer(pointer, texture: texture, into: drawable.texture, commandBuffer: commandBuffer)
        }
        if !presentedOnce {
            presentedOnce = true
            drawable.addPresentedHandler { [weak self] _ in DispatchQueue.main.async { self?.onFirstPresent?() } }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Caller holds `lock`.
    private func filterIntoPanel() {
        guard let source = lastSource, panelSize.width > 0, panelSize.height > 0 else { return }
        if panel == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: layer.pixelFormat, width: Int(panelSize.width),
                                                                height: Int(panelSize.height), mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            panel = filter.device.makeTexture(descriptor: desc)
        }
        guard let panel, let commandBuffer = filter.queue.makeCommandBuffer() else { return }
        filter.encode(into: commandBuffer, src: source.texture, dst: panel)
        let keepAlive = source.keepAlive
        commandBuffer.addCompletedHandler { _ in _ = keepAlive }  // IOSurface stays valid until the GPU is done
        commandBuffer.commit()
    }

    // MARK: Pointer

    private func currentPointer(virtualBounds: CGRect) -> Pointer? {
        guard CGCursorIsVisible() != 0, virtualBounds.width > 0,
              let location = CGEvent(source: nil)?.location, virtualBounds.contains(location) else { return nil }
        let size = lock.withLock { panelSize }
        let scale = size.width / virtualBounds.width  // panel pixels per desktop point
        updatePointerImage(scale: scale)
        guard pointerTexture != nil else { return nil }
        let x = (location.x - virtualBounds.minX) * scale - pointerHotspot.x
        let y = (location.y - virtualBounds.minY) * scale - pointerHotspot.y
        return Pointer(origin: CGPoint(x: x.rounded(), y: y.rounded()), seed: pointerSeed)
    }

    /// Re-rasterises the system pointer only when it changes (seed) or the scale does.
    private func updatePointerImage(scale: CGFloat) {
        let seed = CGSCurrentCursorSeed()
        guard seed != pointerSeed || scale != pointerScale else { return }
        pointerSeed = seed
        pointerScale = scale
        guard let cursor = NSCursor.currentSystem else { pointerTexture = nil; return }
        let points = cursor.image.size
        let w = Int((points.width * scale).rounded(.up)), h = Int((points.height * scale).rounded(.up))
        guard w > 0, h > 0 else { pointerTexture = nil; return }

        let ctx = Samples.bgraContext(width: w, height: h)
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        cursor.image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = filter.device.makeTexture(descriptor: desc), let data = ctx.data else { pointerTexture = nil; return }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        pointerTexture = texture
        pointerHotspot = CGPoint(x: cursor.hotSpot.x * scale, y: cursor.hotSpot.y * scale)
    }

    private func drawPointer(_ pointer: Pointer, texture: MTLTexture, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let W = Float(target.width), H = Float(target.height)
        let x0 = Float(pointer.origin.x), y0 = Float(pointer.origin.y)
        let x1 = x0 + Float(texture.width), y1 = y0 + Float(texture.height)
        var rect = SIMD4<Float>(2 * x0 / W - 1, 1 - 2 * y0 / H, 2 * x1 / W - 1, 1 - 2 * y1 / H)
        encoder.setRenderPipelineState(pointerPipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };

    // rect = (left, top, right, bottom) in NDC; 4-vertex triangle strip.
    vertex VOut pointerVertex(uint vid [[vertex_id]], constant float4& rect [[buffer(0)]]) {
        float2 uv = float2(float(vid & 1), float(vid >> 1));
        VOut out;
        out.position = float4(mix(rect.x, rect.z, uv.x), mix(rect.y, rect.w, uv.y), 0, 1);
        out.uv = uv;
        return out;
    }

    fragment float4 pointerFragment(VOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
        return image.sample(nearest, in.uv);
    }
    """
}
