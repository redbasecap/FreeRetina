import AppKit
import SwiftUI

/// Temporarily runs a monitor at its native 1x mode so test images land 1:1 on panel pixels.
/// App-only: undone by `end()`, and by macOS if the app dies.
final class NativeModePreview {
    let display: PhysicalDisplay
    private var changed = false

    init(display: PhysicalDisplay) throws {
        self.display = display
        guard let current = CGDisplayCopyDisplayMode(display.id) else { throw FreeRetinaError("Monitor nicht erreichbar") }
        if current.pixelWidth == display.nativeMode.pixelWidth, current.pixelWidth == current.width { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { throw FreeRetinaError("Display-Konfiguration nicht möglich") }
        CGConfigureDisplayWithDisplayMode(config, display.id, display.nativeMode, nil)
        let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard result == .success else { throw FreeRetinaError("Native Auflösung nicht setzbar (\(result.rawValue))") }
        changed = true
    }

    func end() {
        guard changed else { return }
        changed = false
        CGRestorePermanentDisplayConfiguration()
    }

    deinit { end() }
}

struct Variant: Identifiable {
    let id = UUID()
    let letter: String
    let image: CGImage
    let order: SubpixelOrder
    let strength: Float
    let looks: CGSize
    let caption: String?
}

final class WizardModel: ObservableObject {
    enum Step: Int {
        case welcome, permission, order, strength, size, summary
    }

    @Published var step: Step = .welcome
    @Published var displays: [PhysicalDisplay] = []
    @Published var selectedKey: String = ""
    @Published var variants: [Variant] = []
    @Published var error: String?
    @Published var busy = false

    private(set) var order: SubpixelOrder = .rgb
    private(set) var strength: Float = 1
    private(set) var looks: CGSize = .zero
    private var preview: NativeModePreview?
    private let filter: SubpixelFilter?

    /// Points per panel pixel on the test monitor (1 once it runs at native 1x).
    @Published var pointsPerPixel: CGFloat = 1

    var enginesIdle: () -> Bool = { true }
    var placeWindow: (PhysicalDisplay?) -> Void = { _ in }
    var onFinish: (PhysicalDisplay, DisplayConfig) -> Void = { _, _ in }
    var onClose: () -> Void = {}

    init() {
        filter = MTLCreateSystemDefaultDevice().flatMap { try? SubpixelFilter(device: $0, order: .rgb, strength: 1) }
        refreshDisplays()
    }

    var selected: PhysicalDisplay? { displays.first { $0.key == selectedKey } }
    var problems: [Preflight.Problem] { selected.map(Preflight.check) ?? [] }
    var canStart: Bool { selected != nil && !problems.contains { $0.blocking } && filter != nil }

    func refreshDisplays() {
        displays = PhysicalDisplay.externals()
        if selected == nil { selectedKey = displays.first?.key ?? "" }
    }

    // MARK: Flow

    func startTest() {
        guard let display = selected, canStart else { return }
        guard CGPreflightScreenCaptureAccess() else { return step = .permission }
        guard enginesIdle() else {
            // FreeRetina is still releasing this monitor; try again shortly.
            busy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startTest() }
            return
        }
        busy = false
        guard !InstanceGuard.isRunning(for: display) else {
            error = "FreeRetina läuft bereits auf \(display.name) (in einem anderen Fenster oder Terminal). Bitte dort zuerst beenden."
            return
        }
        do {
            preview = try NativeModePreview(display: display)
        } catch {
            self.error = "\(error)"
            return
        }
        looks = display.defaultLooksLike ?? display.nativeSize
        placeWindow(display)
        // The mode switch takes a moment to reach NSScreen; measure after it settled.
        busy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.busy = false
            self.placeWindow(display)
            self.pointsPerPixel = 1 / (self.screen(of: display)?.backingScaleFactor ?? 1)
            self.showOrderStep()
        }
    }

    func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    func choose(_ variant: Variant) {
        switch step {
        case .order:
            order = variant.order
            strength = variant.strength
            if variant.strength == 0 { showSizeStep() } else { showStrengthStep() }
        case .strength:
            strength = variant.strength
            showSizeStep()
        case .size:
            looks = variant.looks
            step = .summary
        default:
            break
        }
    }

    /// "Ich sehe keinen Unterschied": take the option that cannot hurt.
    func noDifference() {
        switch step {
        case .order:
            // Without a visible stripe effect, plain 2x scaling has no colour risk.
            order = .rgb
            strength = 0
            showSizeStep()
        case .strength:
            strength = 0.8
            showSizeStep()
        default:
            break
        }
    }

    func back() {
        switch step {
        case .strength: showOrderStep()
        case .size: strength == 0 ? showOrderStep() : showStrengthStep()
        case .summary: showSizeStep()
        default: cancel()
        }
    }

    func activate() {
        guard let display = selected else { return }
        endPreview()
        let config = DisplayConfig(order: order, strength: strength, looksWidth: Int(looks.width), looksHeight: Int(looks.height),
                                   enabled: false, confirmed: false)
        onFinish(display, config)
    }

    func cancel() {
        endPreview()
        onClose()
    }

    func endPreview() {
        preview?.end()
        preview = nil
        placeWindow(nil)
    }

    // MARK: Steps

    private func showOrderStep() {
        makeVariants(shuffled: true, [
            (.rgb, 1, looks, nil),
            (.bgr, 1, looks, nil),
            (.rgb, 0, looks, nil),
        ])
        step = .order
    }

    private func showStrengthStep() {
        makeVariants(shuffled: true, [
            (order, 0.5, looks, nil),
            (order, 0.8, looks, nil),
            (order, 1.0, looks, nil),
        ])
        step = .strength
    }

    private func showSizeStep() {
        guard let display = selected else { return }
        let sizes = display.looksLikeSizes
        let preferred = display.defaultLooksLike ?? sizes[0]
        let larger = sizes.last { $0.width < preferred.width && $0.width >= preferred.width * 0.8 } ?? sizes.last ?? preferred
        let options: [(CGSize, String)] = [
            (sizes[0], "Wie bisher: größte Arbeitsfläche, kleinste Schrift"),
            (preferred, "Etwas größer (empfohlen)"),
            (larger, "Deutlich größer, weniger Platz"),
        ]
        var seen = Set<CGFloat>()
        makeVariants(shuffled: false, options.compactMap { size, text in
            guard seen.insert(size.width).inserted else { return nil }
            return (order, strength, size, "\(text) – wirkt wie \(Int(size.width)) × \(Int(size.height))")
        })
        step = .size
    }

    private func makeVariants(shuffled: Bool, _ specs: [(SubpixelOrder, Float, CGSize, String?)]) {
        guard let display = selected, let filter else { return }
        let ordered = shuffled ? specs.shuffled() : specs
        let letters = ["A", "B", "C"]
        do {
            variants = try ordered.enumerated().map { index, spec in
                let image = try Samples.panelPreview(for: display, looks: spec.2, order: spec.0, strength: spec.1, filter: filter)
                return Variant(letter: letters[index], image: image, order: spec.0, strength: spec.1, looks: spec.2, caption: spec.3)
            }
        } catch {
            self.error = "Vorschau fehlgeschlagen: \(error)"
        }
    }

    func screen(of display: PhysicalDisplay) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }
    }

    var summaryLines: [String] {
        [
            strength == 0 ? "Subpixel-Schärfung: aus (nur doppelte Auflösung)"
                : "Subpixel-Reihenfolge: \(order.rawValue.uppercased()), Stärke \(Int((strength * 100).rounded())) %",
            "Wirkt wie: \(Int(looks.width)) × \(Int(looks.height))",
        ]
    }
}

// MARK: - Views

struct WizardView: View {
    @ObservedObject var model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.step {
            case .welcome: welcome
            case .permission: permission
            case .order:
                compare(title: "Welcher Text wirkt am schärfsten?",
                        detail: "Aus normalem Sitzabstand, ohne Lupe. Achte auf Buchstabenkanten und darauf, was ruhiger wirkt.",
                        stepLabel: "Test 1 von 3")
            case .strength:
                compare(title: "Welche Variante gefällt dir am besten?",
                        detail: "Mehr Schärfe bringt feine Farbsäume an Kanten. Wähle, was für deine Augen am angenehmsten ist.",
                        stepLabel: "Test 2 von 3")
            case .size:
                compare(title: "Wie groß soll alles sein?",
                        detail: "Die Beispiele zeigen die echte Größe. Kleinere Arbeitsfläche heißt größere, noch schärfere Schrift.",
                        stepLabel: "Test 3 von 3", allowNoDifference: false)
            case .summary: summary
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 780, alignment: .leading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FreeRetina einrichten").font(.largeTitle.bold())
            Text("""
            FreeRetina macht Text auf normalen Monitoren schärfer: macOS zeichnet alles in doppelter Auflösung, \
            und FreeRetina verteilt das Bild auf die roten, grünen und blauen Leuchtstreifen jedes einzelnen Pixels.
            """)
            Text("""
            Im Test siehst du dreimal drei Varianten, direkt in den echten Pixeln deines Monitors. \
            Wähle jeweils, was dir am besten gefällt. Daraus stellt sich FreeRetina selbst ein.
            """)
            if model.displays.isEmpty {
                Label("Kein externer Monitor gefunden.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Erneut suchen") { model.refreshDisplays() }
            } else {
                Picker("Monitor", selection: $model.selectedKey) {
                    ForEach(model.displays, id: \.key) { display in
                        Text("\(display.name) – \(display.nativeMode.pixelWidth) × \(display.nativeMode.pixelHeight)").tag(display.key)
                    }
                }
                .frame(maxWidth: 460)
                ForEach(Array(model.problems.enumerated()), id: \.offset) { _, problem in
                    Label(problem.message, systemImage: problem.blocking ? "xmark.octagon" : "exclamationmark.triangle")
                        .foregroundStyle(problem.blocking ? .red : .orange)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Während des Tests läuft der Monitor kurz in seiner echten Auflösung.", systemImage: "info.circle")
                    Label("Nach dem Aktivieren musst du innerhalb von 15 Sekunden bestätigen, sonst wird alles zurückgesetzt.", systemImage: "timer")
                    Label("Notaus jederzeit: \(EmergencyHotkey.description)", systemImage: "power")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            HStack {
                Button("Abbrechen") { model.cancel() }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Test starten") { model.startTest() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart || model.busy)
            }
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Eine Erlaubnis fehlt").font(.largeTitle.bold())
            Text("""
            FreeRetina muss das Bild, das macOS zeichnet, lesen können, um es für deinen Monitor aufzubereiten. \
            Dafür braucht es die Erlaubnis „Bildschirm- & Systemaudioaufnahme“. Es wird nichts gespeichert oder gesendet.
            """)
            Text("1. „Erlauben…“ klicken und FreeRetina in den Systemeinstellungen einschalten.\n2. Danach „Neu starten“ klicken.")
            HStack {
                Button("Abbrechen") { model.cancel() }
                Spacer()
                Button("Erlauben…") { model.requestPermission() }
                Button("Neu starten") { model.relaunch() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func compare(title: String, detail: String, stepLabel: String, allowNoDifference: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stepLabel).font(.headline).foregroundStyle(.secondary)
            Text(title).font(.title.bold())
            Text(detail).foregroundStyle(.secondary)
            ForEach(model.variants) { variant in
                Button { model.choose(variant) } label: {
                    HStack(alignment: .center, spacing: 16) {
                        Text(variant.letter).font(.system(size: 28, weight: .bold)).frame(width: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            PixelImage(image: variant.image, pointsPerPixel: model.pointsPerPixel)
                            if let caption = variant.caption { Text(caption).font(.callout) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(VariantButtonStyle())
            }
            HStack {
                Button("Zurück") { model.back() }
                Spacer()
                if allowNoDifference {
                    Button("Ich sehe keinen Unterschied") { model.noDifference() }
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fertig eingestellt").font(.largeTitle.bold())
            ForEach(model.summaryLines, id: \.self) { Label($0, systemImage: "checkmark.circle") }
            Text("""
            Nach dem Aktivieren erscheint „FreeRetina \(model.selected?.name ?? "")“ in Systemeinstellungen › Displays. \
            Dort kannst du die Auflösung jederzeit ändern. Bestätige innerhalb von 15 Sekunden, dass alles richtig aussieht, \
            sonst stellt FreeRetina automatisch zurück.
            """)
            HStack {
                Button("Zurück") { model.back() }
                Spacer()
                Button("Aktivieren") { model.activate() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct VariantButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(configuration.isPressed ? 0.25 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.5)))
    }
}

/// Shows a CGImage with one image pixel per device pixel, snapped to the pixel grid.
struct PixelImage: NSViewRepresentable {
    let image: CGImage
    let pointsPerPixel: CGFloat

    func makeNSView(context: Context) -> PixelImageView { PixelImageView() }

    func updateNSView(_ view: PixelImageView, context: Context) {
        view.image = image
        view.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PixelImageView, context: Context) -> CGSize? {
        CGSize(width: CGFloat(image.width) * pointsPerPixel, height: CGFloat(image.height) * pointsPerPixel)
    }
}

final class PixelImageView: NSView {
    var image: CGImage?
    private let imageLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        imageLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        guard let image, let window else { return }
        let scale = window.backingScaleFactor
        // SwiftUI may place us at half points; snap the image to whole device pixels.
        let inWindow = convert(bounds, to: nil)
        let snapped = window.backingAlignedRect(NSRect(origin: inWindow.origin, size: .zero), options: .alignAllEdgesNearest)
        let origin = convert(snapped.origin, from: nil)
        imageLayer.contentsScale = scale
        imageLayer.contents = image
        imageLayer.frame = CGRect(x: origin.x, y: origin.y, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

final class WizardWindowController: NSWindowController, NSWindowDelegate {
    let model: WizardModel
    private var target: PhysicalDisplay?

    init(model: WizardModel) {
        self.model = model
        let hosting = NSHostingController(rootView: WizardView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "FreeRetina"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        model.placeWindow = { [weak self] display in self?.place(on: display) }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func place(on display: PhysicalDisplay?) {
        target = display
        guard let window, let display, let screen = model.screen(of: display) else { return }
        let size = window.frame.size
        let visible = screen.visibleFrame
        let origin = CGPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded())
        window.setFrameOrigin(origin)
    }

    @objc private func screensChanged() {
        place(on: target)
    }

    func windowWillClose(_ notification: Notification) {
        model.endPreview()
        model.onClose()
    }
}
