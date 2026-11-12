import AppKit
import ServiceManagement

/// Menu bar app: owns configuration, the setup assistant and one supervised engine per
/// configured monitor. Holds no display state itself; engines do, in their own processes.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ConfigStore()
    private var supervisors: [String: EngineSupervisor] = [:]
    private var statusItem: NSStatusItem!
    private var hotkey: EmergencyHotkey?
    private var wizard: WizardWindowController?
    private let confirm = ConfirmPanel()
    /// Monitor key awaiting confirm-or-revert.
    private var pendingConfirm: String?
    private var reconcileScheduled = false

    static func run() -> Never {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        guard Preflight.isAppleSilicon else {
            alert("FreeRetina benötigt einen Mac mit Apple-Chip (M1 oder neuer).")
            NSApp.terminate(nil)
            return
        }
        hotkey = EmergencyHotkey { [weak self] in self?.emergencyStop() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if !store.displays.isEmpty && !CGPreflightScreenCaptureAccess() {
            // Shows the system prompt; after granting, macOS offers to reopen the app.
            CGRequestScreenCaptureAccess()
        }
        reconcile()
        if store.displays.isEmpty { openWizard() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        supervisors.values.forEach { $0.stop() }
    }

    // MARK: Engines

    @objc private func screensChanged() {
        // Engines reconfigure displays themselves; coalesce the resulting burst.
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.reconcileScheduled = false
            self.reconcile()
        }
    }

    /// Start engines for connected, enabled monitors; drop engines whose monitor is gone.
    private func reconcile() {
        // Without permission an engine could only fail; never turn configurations off for that.
        guard wizard == nil, CGPreflightScreenCaptureAccess() else { return updateIcon() }
        let connected = Dictionary(PhysicalDisplay.externals().map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, supervisor) in supervisors where connected[key]?.id != supervisor.display.id {
            supervisor.stop()
            supervisors[key] = nil
        }
        for (key, display) in connected {
            guard let config = store[key], config.enabled, config.confirmed, key != pendingConfirm,
                  Preflight.blockingReason(display) == nil else { continue }
            let supervisor = supervisor(for: display, config: config)
            if case .stopped = supervisor.state { supervisor.start(with: config) }
        }
        updateIcon()
    }

    private func supervisor(for display: PhysicalDisplay, config: DisplayConfig) -> EngineSupervisor {
        if let existing = supervisors[display.key], existing.display.id == display.id { return existing }
        let supervisor = EngineSupervisor(display: display, config: config)
        let key = display.key
        supervisor.onStateChange = { [weak self] in self?.engineStateChanged(key) }
        supervisor.onModeChange = { [weak self] looks in
            guard var config = self?.store[key] else { return }
            config.looksWidth = Int(looks.width)
            config.looksHeight = Int(looks.height)
            self?.store[key] = config
        }
        supervisor.onGiveUp = { [weak self] message in
            guard let self else { return }
            if var config = self.store[key] {
                config.enabled = false
                self.store[key] = config
            }
            if self.pendingConfirm == key { self.pendingConfirm = nil }
            self.alert("FreeRetina wurde für \(display.name) ausgeschaltet.\n\n\(message)")
        }
        supervisors[key] = supervisor
        return supervisor
    }

    private func engineStateChanged(_ key: String) {
        updateIcon()
        guard key == pendingConfirm, let supervisor = supervisors[key] else { return }
        switch supervisor.state {
        case .running:
            confirm.show(on: freeRetinaScreen(), displayName: supervisor.display.name) { [weak self] keep in
                self?.confirmed(key: key, keep: keep)
            }
        case .failed(let message):
            pendingConfirm = nil
            alert("FreeRetina konnte auf \(supervisor.display.name) nicht starten.\n\n\(message)")
        default:
            break
        }
    }

    /// Starts an engine that must be confirmed within ConfirmPanel.seconds or is reverted.
    private func startWithConfirmation(_ display: PhysicalDisplay, config: DisplayConfig) {
        var config = config
        config.enabled = false  // only a confirmed setup may auto-start
        store[display.key] = config
        pendingConfirm = display.key
        supervisor(for: display, config: config).start(with: config)
    }

    private func confirmed(key: String, keep: Bool) {
        pendingConfirm = nil
        guard var config = store[key] else { return }
        if keep {
            config.enabled = true
            config.confirmed = true
        } else {
            supervisors[key]?.stop()
            config.enabled = false
        }
        store[key] = config
        updateIcon()
    }

    private func emergencyStop() {
        if pendingConfirm != nil { confirm.finish(keep: false) }
        for (key, supervisor) in supervisors {
            supervisor.stop()
            if var config = store[key] {
                config.enabled = false
                store[key] = config
            }
        }
        updateIcon()
    }

    private func freeRetinaScreen() -> NSScreen? {
        NSScreen.screens.first {
            guard let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayVendorNumber(id) == VirtualDisplay.vendorID
        } ?? NSScreen.main
    }

    // MARK: Wizard

    @objc private func openWizard() {
        if let wizard { return wizard.show() }
        // The assistant needs the monitors in their normal state.
        if pendingConfirm != nil { confirm.finish(keep: false) }
        supervisors.values.forEach { $0.stop() }

        let model = WizardModel()
        model.enginesIdle = { [weak self] in
            self?.supervisors.values.allSatisfy { !$0.isActive } ?? true
        }
        model.onFinish = { [weak self] display, config in
            self?.closeWizard()
            self?.startWithConfirmation(display, config: config)
        }
        model.onClose = { [weak self] in self?.closeWizard() }
        let controller = WizardWindowController(model: model)
        wizard = controller
        controller.show()
    }

    private func closeWizard() {
        guard let wizard else { return }
        self.wizard = nil
        wizard.window?.delegate = nil
        wizard.close()
        // Monitors that were running before the assistant come back (unless being set up now).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.reconcile() }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "FreeRetina", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(item("⚠︎ Bildschirmaufnahme-Erlaubnis fehlt – erteilen…", #selector(openScreenCapturePrivacy)))
        }
        let displays = PhysicalDisplay.externals()
        if displays.isEmpty {
            let none = NSMenuItem(title: "Kein externer Monitor", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for display in displays {
            let item = NSMenuItem(title: "\(display.name) – \(statusText(display))", action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = display.key
            item.state = supervisors[display.key]?.isActive == true ? .on : .off
            item.isEnabled = store[display.key] != nil && Preflight.blockingReason(display) == nil && wizard == nil
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(item("Einrichten…", #selector(openWizard)))
        menu.addItem(item("Alles sofort ausschalten  \(EmergencyHotkey.description)", #selector(emergencyStopFromMenu)))
        let login = item("Beim Anmelden starten", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("FreeRetina beenden", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func statusText(_ display: PhysicalDisplay) -> String {
        if let reason = Preflight.blockingReason(display) { return "nicht möglich: \(reason)" }
        guard store[display.key] != nil else { return "nicht eingerichtet" }
        switch supervisors[display.key]?.state ?? .stopped {
        case .stopped: return "aus"
        case .starting: return "startet…"
        case .running(let looks): return "aktiv, wirkt wie \(Int(looks.width)) × \(Int(looks.height))"
        case .failed(let message): return "Fehler: \(message)"
        }
    }

    @objc private func openScreenCapturePrivacy() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard CGPreflightScreenCaptureAccess() else { return openScreenCapturePrivacy() }
        guard let key = sender.representedObject as? String,
              let display = PhysicalDisplay.externals().first(where: { $0.key == key }),
              var config = store[key] else { return }
        if let supervisor = supervisors[key], supervisor.isActive {
            if pendingConfirm == key { confirm.finish(keep: false) }
            supervisor.stop()
            config.enabled = false
            store[key] = config
        } else if config.confirmed {
            config.enabled = true
            store[key] = config
            supervisor(for: display, config: config).start(with: config)
        } else {
            startWithConfirmation(display, config: config)
        }
        updateIcon()
    }

    @objc private func emergencyStopFromMenu() { emergencyStop() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Anmeldeobjekt konnte nicht geändert werden: \(error.localizedDescription)\n\nTipp: FreeRetina zuerst in den Ordner „Programme“ legen.")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateIcon() {
        let active = supervisors.values.contains { $0.isActive }
        let failed = supervisors.values.contains { if case .failed = $0.state { true } else { false } }
        let symbol = failed ? "exclamationmark.triangle" : active ? "sparkles.tv" : "tv"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FreeRetina")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "FreeRetina"
        alert.informativeText = text
        alert.runModal()
    }
}
