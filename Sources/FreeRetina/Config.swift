import CoreGraphics
import Foundation

/// What the setup assistant decided for one monitor.
struct DisplayConfig: Codable, Equatable {
    var order: SubpixelOrder
    var strength: Float
    var looksWidth: Int
    var looksHeight: Int
    /// Start automatically whenever the app runs and the monitor is connected.
    var enabled: Bool
    /// The user saw it working and kept it (confirm-or-revert passed).
    var confirmed: Bool

    var looks: CGSize { CGSize(width: looksWidth, height: looksHeight) }
}

extension SubpixelOrder: Codable {}

/// ~/Library/Application Support/FreeRetina/config.json, keyed by PhysicalDisplay.key.
final class ConfigStore {
    private(set) var displays: [String: DisplayConfig] = [:]
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeRetina", isDirectory: true)
        url = dir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: DisplayConfig].self, from: data) {
            displays = decoded
        }
    }

    subscript(key: String) -> DisplayConfig? {
        get { displays[key] }
        set {
            displays[key] = newValue
            save()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(displays).write(to: url, options: .atomic)
        } catch {
            NSLog("FreeRetina: saving config failed: \(error)")
        }
    }
}
