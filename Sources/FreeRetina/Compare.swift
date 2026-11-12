import AppKit
import CoreText
import Metal

/// Renders the same text three ways and writes PNGs:
///   1-native.png     macOS 1x rendering (grayscale AA, no subpixel AA since Mojave)
///   2-hidpi.png      rendered at `scale`x, area-downsampled (what HiDPI scaling does)
///   3-freeretina.png rendered at `scale`x, subpixel-downsampled
///   panel-zoom.png   crop of all three magnified with each pixel drawn as its R|G|B stripes
enum Compare {
    static func run(outDir: URL, scale: Double, order: SubpixelOrder, strength: Float) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw FreeRetinaError("no Metal device") }
        let filter = try SubpixelFilter(device: device, order: order, strength: strength)
        let size = Samples.pointSize
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let native = Samples.renderText(size: size, scale: 1)
        let hi = Samples.renderText(size: size, scale: scale)
        filter.strength = 0
        let hidpi = try Samples.downsample(hi, to: size, filter: filter)
        filter.strength = strength
        let free = try Samples.downsample(hi, to: size, filter: filter)

        try writePNG(native, outDir.appendingPathComponent("1-native.png"))
        try writePNG(hidpi, outDir.appendingPathComponent("2-hidpi.png"))
        try writePNG(free, outDir.appendingPathComponent("3-freeretina.png"))
        let zoom = panelZoom([native, hidpi, free], crop: CGRect(x: 4, y: 4, width: 96, height: 22), magnify: 9, order: order)
        try writePNG(zoom, outDir.appendingPathComponent("panel-zoom.png"))
        print("wrote \(outDir.path)/{1-native,2-hidpi,3-freeretina,panel-zoom}.png")
    }

    /// Simulated panel: every pixel becomes three vertical stripes lit by its R, G, B values.
    static func panelZoom(_ images: [CGImage], crop: CGRect, magnify: Int, order: SubpixelOrder) -> CGImage {
        let cw = Int(crop.width), ch = Int(crop.height), gap = 6
        let w = cw * magnify, h = (ch * magnify + gap) * images.count
        let out = Samples.bgraContext(width: w, height: h)
        let o = out.data!.assumingMemoryBound(to: UInt8.self)
        memset(o, 0, out.bytesPerRow * h)
        let stripe = magnify / 3
        for (n, image) in images.enumerated() {
            let src = Samples.bgraContext(width: image.width, height: image.height)
            src.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let s = src.data!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<ch {
                for x in 0..<cw {
                    let p = (Int(crop.minY) + y) * src.bytesPerRow + (Int(crop.minX) + x) * 4
                    let bgr = [s[p], s[p + 1], s[p + 2]]  // memory order B, G, R
                    let leftToRight: [Int] = order == .rgb ? [2, 1, 0] : [0, 1, 2]  // channel index into bgr
                    for (slot, ci) in leftToRight.enumerated() {
                        for yy in 0..<(magnify - 1) {
                            for xx in 0..<stripe {
                                let oy = n * (ch * magnify + gap) + y * magnify + yy
                                let ox = x * magnify + slot * stripe + xx
                                let q = oy * out.bytesPerRow + ox * 4
                                o[q + ci] = bgr[ci]
                                o[q + 3] = 255
                            }
                        }
                    }
                }
            }
        }
        return out.makeImage()!
    }

    static func writePNG(_ image: CGImage, _ url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw FreeRetinaError("PNG encode failed") }
        try data.write(to: url)
    }
}
