import AppKit
import SwiftUI

/// "Keep these display settings?" – like macOS' own resolution dialog. The panel is drawn on
/// the FreeRetina display, i.e. through the new pipeline: if the picture is broken the user
/// cannot click "Behalten", and the countdown reverts everything.
final class ConfirmPanel: ObservableObject {
    static let seconds = 15

    @Published var remaining = ConfirmPanel.seconds
    private var panel: NSPanel?
    private var timer: Timer?
    private var completion: ((Bool) -> Void)?

    func show(on screen: NSScreen?, displayName: String, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        remaining = Self.seconds
        let view = ConfirmView(model: self, displayName: displayName)
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow]
        panel.title = "FreeRetina"
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        if let screen {
            let size = panel.frame.size
            panel.setFrameOrigin(CGPoint(x: (screen.visibleFrame.midX - size.width / 2).rounded(),
                                         y: (screen.visibleFrame.midY - size.height / 2).rounded()))
        } else {
            panel.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.remaining -= 1
            if self.remaining <= 0 { self.finish(keep: false) }
        }
    }

    func finish(keep: Bool) {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        let completion = self.completion
        self.completion = nil
        completion?(keep)
    }
}

private struct ConfirmView: View {
    @ObservedObject var model: ConfirmPanel
    let displayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sieht alles richtig aus?").font(.title2.bold())
            Text("FreeRetina ist jetzt auf \(displayName) aktiv. Wenn du nicht bestätigst, wird in \(model.remaining) Sekunden automatisch zurückgestellt.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Zurückstellen") { model.finish(keep: false) }
                Spacer()
                Button("Behalten") { model.finish(keep: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
