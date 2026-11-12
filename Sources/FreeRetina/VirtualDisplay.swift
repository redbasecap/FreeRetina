import AppKit
import CVirtualDisplay
import CoreGraphics
import Foundation

/// A real macOS display (System Settings, menu bar, Dock, Spaces) whose pixels never reach a
/// cable: FreeRetina captures it and draws it onto the physical panel. Lives as long as the
/// process; the system removes it on exit.
final class VirtualDisplay {
    static let vendorID: UInt32 = 0xF4EE

    let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }

    /// Called (on the descriptor queue, main) if the system tears the display down.
    var onTermination: (() -> Void)? {
        get { termination.handler }
        set { termination.handler = newValue }
    }
    private let termination: TerminationBox

    private final class TerminationBox {
        var handler: (() -> Void)?
    }

    init(for physical: PhysicalDisplay) throws {
        let looks = physical.looksLikeSizes
        guard let maxLooks = looks.first, let preferred = physical.defaultLooksLike else {
            throw FreeRetinaError("Keine passende Auflösung für \(physical.name)")
        }
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = .main
        desc.name = "FreeRetina \(physical.name)"
        desc.maxPixelsWide = UInt32(maxLooks.width * 2)
        desc.maxPixelsHigh = UInt32(maxLooks.height * 2)
        desc.sizeInMillimeters = physical.sizeMillimeters
        desc.vendorID = Self.vendorID
        desc.productID = CGDisplayModelNumber(physical.id) & 0xFFFF
        // Stable identity, so macOS remembers the chosen resolution for this monitor.
        desc.serialNum = Self.serialNumber(for: physical)
        // sRGB primaries: frames are captured and processed as sRGB.
        desc.redPrimary = CGPoint(x: 0.640, y: 0.330)
        desc.greenPrimary = CGPoint(x: 0.300, y: 0.600)
        desc.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        desc.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        let termination = TerminationBox()
        desc.terminationHandler = { _, _ in termination.handler?() }
        self.termination = termination
        guard let display = CGVirtualDisplay(descriptor: desc) else { throw FreeRetinaError("CGVirtualDisplay creation failed") }
        self.display = display

        // Modes are "looks like" sizes. With hiDPI = 1 macOS adds a settable 2x variant of each
        // (backing pixels <= maxPixels) and starts in the first one; later choices made in
        // System Settings are remembered per display.
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        let ordered = [preferred] + looks.filter { $0 != preferred }
        settings.modes = ordered.map {
            CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height), refreshRate: physical.refreshRate)
        }
        guard display.apply(settings) else { throw FreeRetinaError("CGVirtualDisplay rejected its modes") }
    }

    /// FNV-1a of the monitor key: stable, and lets other processes recognise the display.
    static func serialNumber(for physical: PhysicalDisplay) -> UInt32 {
        physical.key.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    /// Waits until the WindowServer has brought the display up with a mode. The display
    /// notifications arrive as AppKit events, so they must be pumped through NSApp.
    func waitOnline(timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while CGDisplayCopyDisplayMode(id) == nil {
            guard Date() < deadline else { throw FreeRetinaError("virtual display did not come online") }
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    func hiDPIMode(looksLike size: CGSize) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []).first {
            $0.width == Int(size.width) && $0.height == Int(size.height) && $0.pixelWidth == $0.width * 2
        }
    }
}
