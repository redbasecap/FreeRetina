import AppKit
import CoreGraphics

struct PhysicalDisplay {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    /// 1x mode whose pixel grid is the panel's physical grid.
    let nativeMode: CGDisplayMode
    /// The panel reported its native mode explicitly (otherwise: largest 1x mode).
    let nativeModeReported: Bool
    let sizeMillimeters: CGSize

    var nativeSize: CGSize { CGSize(width: nativeMode.pixelWidth, height: nativeMode.pixelHeight) }
    var refreshRate: Double { nativeMode.refreshRate > 0 ? nativeMode.refreshRate : 60 }
    var rotation: Double { CGDisplayRotation(id) }
    var isMirrored: Bool { CGDisplayIsInMirrorSet(id) != 0 }

    /// Stable across reboots and ports (display IDs are not); identical monitors without
    /// serial numbers share a configuration, which is what one wants for twins anyway.
    var key: String { "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))" }

    var ppi: Double? {
        sizeMillimeters.width > 0 ? Double(nativeMode.pixelWidth) / (sizeMillimeters.width / 25.4) : nil
    }

    /// Largest render target we ask macOS for. M-series GPUs drive 8K, and the capture plus
    /// filter stay cheap at that size; beyond it the gain on a dense panel is negligible.
    static let maxBackingDimension = 8192

    /// "Looks like" sizes offered on the FreeRetina display; each is rendered at 2x and
    /// subpixel-downsampled onto the native grid. Largest first.
    var looksLikeSizes: [CGSize] {
        let w = Double(nativeMode.pixelWidth), h = Double(nativeMode.pixelHeight)
        let fractions = [1.0, 0.9375, 0.875, 0.8, 0.75, 2.0 / 3.0, 0.5]
        var seen = Set<Int>()
        return fractions.compactMap { f in
            let lw = Int((w * f / 2).rounded()) * 2
            let lh = Int((Double(lw) * h / w / 2).rounded()) * 2
            guard lw * 2 <= Self.maxBackingDimension, lh * 2 <= Self.maxBackingDimension, lw >= 640 else { return nil }
            return seen.insert(lw).inserted ? CGSize(width: lw, height: lh) : nil
        }
    }

    /// The "reduce a little" default: 87.5% of native when available.
    var defaultLooksLike: CGSize? {
        let sizes = looksLikeSizes
        return sizes.isEmpty ? nil : sizes[min(2, sizes.count - 1)]
    }

    var summary: String {
        let looks = looksLikeSizes.map { s -> String in
            let mark = s == defaultLooksLike ? " (default)" : ""
            return "\(Int(s.width))x\(Int(s.height))\(mark)"
        }
        let problems = Preflight.check(self).map { "    \($0.blocking ? "✗" : "!") \($0.message)" }
        return ([
            "\(id)  \(name)\(isBuiltin ? "  [built-in]" : "")",
            "    panel \(nativeMode.pixelWidth)x\(nativeMode.pixelHeight) @ \(Int(refreshRate)) Hz, \(ppi.map { "\(Int($0.rounded())) ppi" } ?? "size unknown")",
            "    FreeRetina looks-like: \(looks.joined(separator: ", "))",
        ] + problems).joined(separator: "\n")
    }

    static func all() -> [PhysicalDisplay] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (n.uint32Value, screen.localizedName)
        }, uniquingKeysWith: { a, _ in a })

        return ids.prefix(Int(count)).compactMap { id in
            // Skip our own (and any other FreeRetina) virtual displays.
            guard CGDisplayVendorNumber(id) != VirtualDisplay.vendorID, let (mode, reported) = nativeMode(of: id) else { return nil }
            return PhysicalDisplay(id: id, name: names[id] ?? "Display \(id)", isBuiltin: CGDisplayIsBuiltin(id) != 0,
                                   nativeMode: mode, nativeModeReported: reported, sizeMillimeters: CGDisplayScreenSize(id))
        }
    }

    static func externals() -> [PhysicalDisplay] { all().filter { !$0.isBuiltin } }

    private static let nativeFlag: UInt32 = 0x0200_0000  // kDisplayModeNativeFlag

    static func nativeMode(of id: CGDirectDisplayID) -> (CGDisplayMode, Bool)? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? [])
            .filter { $0.isUsableForDesktopGUI() && $0.pixelWidth == $0.width }
        let native = modes.filter { $0.ioFlags & nativeFlag != 0 }
        let best = (native.isEmpty ? modes : native).max {
            ($0.pixelWidth * $0.pixelHeight, $0.refreshRate) < ($1.pixelWidth * $1.pixelHeight, $1.refreshRate)
        }
        return best.map { ($0, !native.isEmpty) }
    }
}

/// Conditions under which FreeRetina refuses to touch a display, or warns.
enum Preflight {
    struct Problem {
        let message: String
        let blocking: Bool
    }

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static func check(_ d: PhysicalDisplay) -> [Problem] {
        var problems: [Problem] = []
        if !isAppleSilicon { problems.append(.init(message: "FreeRetina benötigt einen Mac mit Apple-Chip (M1 oder neuer).", blocking: true)) }
        if d.isBuiltin { problems.append(.init(message: "Eingebaute Displays sind bereits Retina.", blocking: true)) }
        if d.rotation != 0 { problems.append(.init(message: "Gedrehte Monitore werden noch nicht unterstützt (Subpixel liegen dann quer).", blocking: true)) }
        if d.isMirrored { problems.append(.init(message: "Der Monitor wird gerade gespiegelt. Bitte Spiegeln ausschalten.", blocking: true)) }
        if d.looksLikeSizes.isEmpty { problems.append(.init(message: "Keine passende Auflösung für diesen Monitor.", blocking: true)) }
        if let ppi = d.ppi, ppi >= 180 {
            problems.append(.init(message: "Dieser Monitor ist bereits sehr scharf (\(Int(ppi)) ppi). FreeRetina bringt hier wenig.", blocking: false))
        }
        if !d.nativeModeReported {
            problems.append(.init(message: "Der Monitor meldet seine native Auflösung nicht. Verwende \(d.nativeMode.pixelWidth)×\(d.nativeMode.pixelHeight).", blocking: false))
        }
        return problems
    }

    static func blockingReason(_ d: PhysicalDisplay) -> String? {
        check(d).first { $0.blocking }?.message
    }
}
