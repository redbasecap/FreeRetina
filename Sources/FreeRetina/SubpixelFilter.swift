import Metal

enum SubpixelOrder: String {
    case rgb, bgr
}

/// Downsamples a supersampled (HiDPI) frame onto a physical panel by addressing the
/// R, G and B stripes of every panel pixel individually.
///
/// Pass 1 (`vdown`): exact area filter vertically, in linear light.
/// Pass 2 (`hsub`):  per output pixel, area-sample luminance at 7 subpixel-sized slots
///                   (the pixel's own 3 stripes plus 2 on each side), run the FreeType
///                   5-tap LCD filter across them to bound colour fringing, and drive each
///                   stripe with its own filtered luminance. Chroma comes from the plain
///                   pixel-area average, so only luminance detail is moved to subpixel
///                   precision: out_c = C_c + strength * (Lf_c - L_pixel).
/// strength = 0 is an exact area (box) downsample, i.e. what plain HiDPI scaling does.
final class SubpixelFilter {
    let device: MTLDevice
    let queue: MTLCommandQueue
    var order: SubpixelOrder
    var strength: Float

    private let vdown: MTLComputePipelineState
    private let hsub: MTLComputePipelineState
    private var mid: MTLTexture?

    init(device: MTLDevice, order: SubpixelOrder, strength: Float) throws {
        self.device = device
        self.order = order
        self.strength = strength
        guard let queue = device.makeCommandQueue() else { throw FreeRetinaError("no Metal command queue") }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        vdown = try device.makeComputePipelineState(function: library.makeFunction(name: "vdown")!)
        hsub = try device.makeComputePipelineState(function: library.makeFunction(name: "hsub")!)
    }

    /// `src` and `dst` are bgra8Unorm holding sRGB-encoded values.
    func encode(into commandBuffer: MTLCommandBuffer, src: MTLTexture, dst: MTLTexture) {
        if mid?.width != src.width || mid?.height != dst.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: src.width, height: dst.height, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            mid = device.makeTexture(descriptor: desc)
        }
        guard let mid, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        var params = Params(
            scaleX: Float(src.width) / Float(dst.width),
            scaleY: Float(src.height) / Float(dst.height),
            order: order == .rgb ? 0 : 1,
            strength: strength)
        let tg = MTLSize(width: 16, height: 16, depth: 1)

        enc.setComputePipelineState(vdown)
        enc.setTexture(src, index: 0)
        enc.setTexture(mid, index: 1)
        enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: mid.width, height: mid.height, depth: 1), threadsPerThreadgroup: tg)

        enc.setComputePipelineState(hsub)
        enc.setTexture(mid, index: 0)
        enc.setTexture(dst, index: 1)
        enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    private struct Params {
        var scaleX: Float
        var scaleY: Float
        var order: Int32
        var strength: Float
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { float scaleX; float scaleY; int order; float strength; };

    inline float3 toLinear(float3 c) {
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }
    inline float3 toSRGB(float3 c) {
        c = saturate(c);
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
    }

    kernel void vdown(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<half, access::write> mid [[texture(1)]],
                      constant Params& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= mid.get_width() || gid.y >= mid.get_height()) return;
        float a = gid.y * p.scaleY, b = a + p.scaleY;
        int last = int(src.get_height()) - 1;
        float3 acc = 0;
        for (int i = int(floor(a)); i < int(ceil(b)); ++i) {
            float w = min(b, float(i + 1)) - max(a, float(i));
            acc += w * toLinear(src.read(uint2(gid.x, uint(clamp(i, 0, last)))).rgb);
        }
        mid.write(half4(half3(acc / p.scaleY), 1), gid);
    }

    // Exact area average of row y over [a, b) in source pixels.
    inline float3 hspan(texture2d<half, access::read> mid, uint y, float a, float b) {
        int last = int(mid.get_width()) - 1;
        float3 acc = 0;
        for (int i = int(floor(a)); i < int(ceil(b)); ++i) {
            float w = min(b, float(i + 1)) - max(a, float(i));
            acc += w * float3(mid.read(uint2(uint(clamp(i, 0, last)), y)).rgb);
        }
        return acc / (b - a);
    }

    kernel void hsub(texture2d<half, access::read> mid [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant Params& p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        const float3 Y = float3(0.2126, 0.7152, 0.0722);
        const float fir[5] = { 8.0 / 256.0, 77.0 / 256.0, 86.0 / 256.0, 77.0 / 256.0, 8.0 / 256.0 };
        float third = p.scaleX / 3.0;
        float x0 = gid.x * p.scaleX;

        // Slots -3..3; slots -1, 0, 1 are this pixel's three stripes (left to right).
        float L[7];
        float3 C = 0;
        for (int m = -3; m <= 3; ++m) {
            float a = x0 + float(m + 1) * third;
            float3 c = hspan(mid, gid.y, a, a + third);
            L[m + 3] = dot(c, Y);
            if (m >= -1 && m <= 1) C += c;
        }
        C /= 3.0;
        float Lp = (L[2] + L[3] + L[4]) / 3.0;

        float3 Lf;
        for (int ch = 0; ch < 3; ++ch) {
            int centre = (p.order == 0 ? ch - 1 : 1 - ch) + 3;  // stripe slot of channel ch
            float s = 0;
            for (int t = -2; t <= 2; ++t) s += fir[t + 2] * L[centre + t];
            Lf[ch] = s;
        }
        dst.write(float4(toSRGB(C + p.strength * (Lf - Lp)), 1), gid);
    }
    """
}

struct FreeRetinaError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
