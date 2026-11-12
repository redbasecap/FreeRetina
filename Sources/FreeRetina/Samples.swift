import AppKit
import CoreText
import Metal

/// Test text and offline rendering through the same filter the live pipeline uses.
enum Samples {
    /// Sample size in points (desktop units).
    static let pointSize = CGSize(width: 480, height: 132)

    /// Renders the sample text at `scale` pixels per point, like macOS does on a display
    /// with that backing scale (grayscale antialiasing, no font smoothing).
    static func renderText(size: CGSize, scale: Double) -> CGImage {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        let ctx = bgraContext(width: w, height: h)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldAntialias(true)
        ctx.scaleBy(x: scale, y: scale)

        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 26))

        let black = NSColor.black, white = NSColor.white
        let lines: [(String, NSFont, NSColor, CGFloat)] = [
            ("Hamburgefonstiv – Zwölf Boxkämpfer jagen Viktor quer über den Sylter Deich", .systemFont(ofSize: 11), black, 16),
            ("Hamburgefonstiv – The quick brown fox jumps over the lazy dog 0123", .systemFont(ofSize: 13), black, 35),
            ("let sharp = pixels.map { $0.subpixel(.rgb) } // illi1| O0", .monospacedSystemFont(ofSize: 12, weight: .regular), black, 54),
            ("Links und Farben: https://www.example.com/hilfe", .systemFont(ofSize: 13), .systemBlue, 74),
            ("Überschrift Semibold 16 pt", .systemFont(ofSize: 16, weight: .semibold), black, 96),
            ("Heller Text auf dunklem Grund – Menüleisten, Terminals", .systemFont(ofSize: 12), white, 122),
        ]
        for (text, font, color, top) in lines {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
            ctx.textPosition = CGPoint(x: 6, y: size.height - top)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()!
    }

    /// What the panel will show for one configuration, in the panel's own pixels: the
    /// sample is rendered at 2x for the given "looks like" size and passed through the filter.
    static func panelPreview(for display: PhysicalDisplay, looks: CGSize, order: SubpixelOrder, strength: Float,
                             filter: SubpixelFilter) throws -> CGImage {
        let hi = renderText(size: pointSize, scale: 2)
        let pixelsPerPoint = display.nativeSize.width / looks.width
        let out = CGSize(width: (pointSize.width * pixelsPerPoint).rounded(), height: (pointSize.height * pixelsPerPoint).rounded())
        filter.order = order
        filter.strength = strength
        return try downsample(hi, to: out, filter: filter)
    }

    static func downsample(_ image: CGImage, to size: CGSize, filter: SubpixelFilter) throws -> CGImage {
        let device = filter.device
        let src = makeTexture(device, image.width, image.height, usage: [.shaderRead])
        let ctx = bgraContext(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        src.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                    withBytes: ctx.data!, bytesPerRow: ctx.bytesPerRow)

        let dw = Int(size.width), dh = Int(size.height)
        let dst = makeTexture(device, dw, dh, usage: [.shaderWrite])
        let cb = filter.queue.makeCommandBuffer()!
        filter.encode(into: cb, src: src, dst: dst)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }

        let out = bgraContext(width: dw, height: dh)
        dst.getBytes(out.data!, bytesPerRow: out.bytesPerRow, from: MTLRegionMake2D(0, 0, dw, dh), mipmapLevel: 0)
        return out.makeImage()!
    }

    static func bgraContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    static func makeTexture(_ device: MTLDevice, _ w: Int, _ h: Int, usage: MTLTextureUsage) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = usage
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)!
    }
}
