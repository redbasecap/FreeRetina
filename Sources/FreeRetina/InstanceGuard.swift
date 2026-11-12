import CoreGraphics
import Foundation

/// Guarantees at most one FreeRetina engine per monitor, across all processes.
/// Primary: an flock held for the engine's lifetime (released by the kernel on any exit).
/// Secondary: an online FreeRetina virtual display carrying this monitor's identity.
enum InstanceGuard {
    private static func lockURL(for key: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeRetina/locks", isDirectory: true)
            .appendingPathComponent("\(key).lock")
    }

    /// Takes the monitor's lock for the rest of the process lifetime.
    static func acquire(for display: PhysicalDisplay) throws {
        if virtualDisplayExists(for: display) { throw alreadyRunning(display) }
        let url = lockURL(for: display.key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw FreeRetinaError("Sperrdatei nicht anlegbar: \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw alreadyRunning(display)
        }
        // fd intentionally stays open: the lock lives exactly as long as this process.
    }

    static func isRunning(for display: PhysicalDisplay) -> Bool {
        if virtualDisplayExists(for: display) { return true }
        let fd = open(lockURL(for: display.key).path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    private static func virtualDisplayExists(for display: PhysicalDisplay) -> Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let serial = VirtualDisplay.serialNumber(for: display)
        return ids.prefix(Int(count)).contains {
            CGDisplayVendorNumber($0) == VirtualDisplay.vendorID && CGDisplaySerialNumber($0) == serial
        }
    }

    private static func alreadyRunning(_ display: PhysicalDisplay) -> FreeRetinaError {
        FreeRetinaError("FreeRetina läuft bereits auf \(display.name). Bitte die andere Instanz zuerst beenden.")
    }
}
