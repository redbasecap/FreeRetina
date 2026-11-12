import AppKit
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import ScreenCaptureKit

struct EngineOptions {
    var physical: PhysicalDisplay
    var looks: CGSize?
    var order: SubpixelOrder
    var strength: Float
    var seconds: Double?
    /// Started by the FreeRetina app: report over stdout, die with the parent.
    var supervised: Bool
}

/// Pipeline:
///   macOS renders the desktop into the FreeRetina virtual display at 2x (HiDPI)
///   → ScreenCaptureKit delivers each changed frame as an IOSurface (zero copy), without pointer
///   → SubpixelFilter maps it onto the panel's native grid stripe by stripe
///   → PanelPresenter shows it in a shielding-level window on the physical display (native 1x),
///     compositing the pointer at its live position whenever the mouse moves.
///
/// Safety: every display change is made with kCGConfigureForAppOnly and the virtual display
/// belongs to this process, so macOS restores the user's setup whenever the process ends:
/// normal stop, error, crash, kill. Everything below therefore reduces to "exit on doubt":
/// a main-thread watchdog, parent-death watch, startup timeout, unplug/mirror detection.
///
/// Supervised protocol (stdout, one line each): `@ready W H`, `@mode W H`, `@heartbeat`, `@error MESSAGE`.
final class LiveSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let options: EngineOptions
    private var physical: PhysicalDisplay { options.physical }
    private let virtual: VirtualDisplay
    private let filter: SubpixelFilter
    private let textureCache: CVMetalTextureCache
    private let captureQueue = DispatchQueue(label: "freeretina.capture", qos: .userInteractive)
    private let watchdog = MainThreadWatchdog()
    private var window: NSWindow!
    private var metalLayer: CAMetalLayer!
    private var presenter: PanelPresenter!
    private var mouseMonitor: Any?
    private var stream: SCStream?
    private var streamConfig = SCStreamConfiguration()
    private var timers: [Timer] = []
    private var sources: [DispatchSourceProtocol] = []
    private var isReady = false
    private var captureRestarts: [Date] = []
    private var rearrangeAttempts = 0

    private static var current: LiveSession?

    static let startupTimeout: TimeInterval = 15
    static let watchdogLimit: TimeInterval = 8

    static func start(_ options: EngineOptions) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do {
            if let reason = Preflight.blockingReason(options.physical) { throw FreeRetinaError(reason) }
            try InstanceGuard.acquire(for: options.physical)
            guard CGPreflightScreenCaptureAccess() else {
                CGRequestScreenCaptureAccess()
                throw FreeRetinaError("Bildschirmaufnahme ist nicht erlaubt. Bitte in Systemeinstellungen › Datenschutz & Sicherheit › Bildschirm- & Systemaudioaufnahme erlauben.")
            }
            let session = try LiveSession(options: options)
            current = session
            try session.activate()
        } catch {
            report(error: "\(error)", supervised: options.supervised)
            exit(1)
        }
        app.run()
        exit(0)
    }

    private init(options: EngineOptions) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw FreeRetinaError("Kein Metal-Gerät") }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw FreeRetinaError("CVMetalTextureCache creation failed") }
        self.options = options
        self.textureCache = cache
        self.filter = try SubpixelFilter(device: device, order: options.order, strength: options.strength)
        self.virtual = try VirtualDisplay(for: options.physical)
        super.init()
    }

    private func activate() throws {
        installSafetyNets()
        try virtual.waitOnline()
        if let looks = options.looks {
            guard let mode = virtual.hiDPIMode(looksLike: looks) else {
                let offered = physical.looksLikeSizes.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: ", ")
                throw FreeRetinaError("Auflösung \(Int(looks.width))x\(Int(looks.height)) nicht verfügbar; möglich: \(offered)")
            }
            // Mode changes inside an app-only configuration are not applied to virtual
            // displays; this becomes the FreeRetina display's remembered choice instead.
            let result = CGDisplaySetDisplayMode(virtual.id, mode, nil)
            guard result == .success else { throw FreeRetinaError("Auflösung setzen fehlgeschlagen: \(result.rawValue)") }
        }
        guard let virtualMode = CGDisplayCopyDisplayMode(virtual.id) else { throw FreeRetinaError("FreeRetina-Display hat keinen Modus") }
        try arrangeDisplays(virtualMode: virtualMode)
        CGDisplayRegisterReconfigurationCallback(Self.reconfigured, Unmanaged.passUnretained(self).toOpaque())
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        try makeWindow()
        startCursorGuard()
        Task { await self.startCapture() }
        if !options.supervised {
            print("""
            FreeRetina active on \(physical.name): looks like \(virtualMode.width)x\(virtualMode.height), \
            rendered \(virtualMode.pixelWidth)x\(virtualMode.pixelHeight), \
            panel \(Int(physical.nativeSize.width))x\(Int(physical.nativeSize.height)), \(filter.order.rawValue.uppercased()) stripes.
            Change resolution in System Settings > Displays > "FreeRetina \(physical.name)". Ctrl-C to stop.
            """)
        }
    }

    /// FreeRetina display takes the physical display's place (and main-display role if it had
    /// it); the physical display goes to native 1x and is parked to the right.
    private func arrangeDisplays(virtualMode: CGDisplayMode) throws {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { throw FreeRetinaError("CGBeginDisplayConfiguration failed") }
        let origin = CGDisplayBounds(physical.id).origin
        let virtualOrigin = CGDisplayBounds(virtual.id).width > 0 && rearrangeAttempts > 0 ? CGDisplayBounds(virtual.id).origin : origin
        CGConfigureDisplayWithDisplayMode(config, physical.id, physical.nativeMode, nil)
        CGConfigureDisplayOrigin(config, virtual.id, Int32(virtualOrigin.x), Int32(virtualOrigin.y))
        CGConfigureDisplayOrigin(config, physical.id, Int32(virtualOrigin.x) + Int32(virtualMode.width), Int32(virtualOrigin.y))
        let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard result == .success else { throw FreeRetinaError("Display-Konfiguration fehlgeschlagen: \(result.rawValue)") }
    }

    // MARK: Output window

    private func makeWindow() throws {
        window = NSWindow(contentRect: physicalScreen()?.frame ?? .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.sharingType = .none

        metalLayer = CAMetalLayer()
        metalLayer.device = filter.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        presenter = try PanelPresenter(filter: filter, layer: metalLayer, refreshRate: physical.refreshRate)
        presenter.onFirstPresent = { [weak self] in self?.markReady() }
        let view = NSView()
        view.wantsLayer = true
        view.layer = metalLayer
        window.contentView = view
        layoutWindow()
        window.orderFrontRegardless()
    }

    /// The pointer is redrawn as soon as the mouse moves (at most once per refresh), not on a
    /// display-link schedule: macOS targets display-link frames ~3 refreshes ahead, while an
    /// immediate present reaches the panel about one composite later. Global mouse monitors
    /// need no Accessibility permission. The slow timer catches pointer shape/visibility changes.
    private func startPointerTracking() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in self?.requestFrame() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.requestFrame() })
    }

    private func requestFrame() {
        presenter.requestFrame(virtualBounds: CGDisplayBounds(virtual.id))
    }

    private func physicalScreen() -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == physical.id
        }
    }

    private func layoutWindow() {
        guard let screen = physicalScreen() else { return }
        window.setFrame(screen.frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = screen.backingScaleFactor
        metalLayer.frame = window.contentView!.bounds
        metalLayer.drawableSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                         height: screen.frame.height * screen.backingScaleFactor)
        CATransaction.commit()
        presenter.setPanelSize(metalLayer.drawableSize)
        startPointerTracking()
    }

    @objc private func screensChanged() {
        layoutWindow()
        // Someone switched the hidden panel away from native 1x (e.g. in System Settings):
        // put it back, but never fight indefinitely.
        guard let mode = CGDisplayCopyDisplayMode(physical.id),
              mode.pixelWidth != physical.nativeMode.pixelWidth || mode.pixelWidth != mode.width,
              let virtualMode = CGDisplayCopyDisplayMode(virtual.id) else { return }
        rearrangeAttempts += 1
        guard rearrangeAttempts <= 3 else { return fail("Monitor-Modus wurde wiederholt verändert") }
        do { try arrangeDisplays(virtualMode: virtualMode) } catch { fail("\(error)") }
    }

    // MARK: Capture

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == virtual.id }) else {
                throw FreeRetinaError("FreeRetina-Display für ScreenCaptureKit nicht sichtbar")
            }
            let config = SCStreamConfiguration()
            applyBackingSize(to: config)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(physical.refreshRate.rounded()))
            config.queueDepth = 4
            config.showsCursor = false  // drawn by PanelPresenter at the live position
            config.scalesToFit = false
            streamConfig = config

            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
            await MainActor.run { self.stream = stream }
        } catch {
            await MainActor.run { self.captureFailed("\(error)") }
        }
    }

    /// Capture can drop out (sleep, WindowServer hiccup). Retry a few times, then give up
    /// and let the system restore the normal setup.
    private func captureFailed(_ message: String) {
        stream = nil
        let now = Date()
        captureRestarts = captureRestarts.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard captureRestarts.count <= 3 else { return fail("Bildaufnahme fällt wiederholt aus: \(message)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Task { await self.startCapture() } }
    }

    @objc private func didWake() {
        if stream == nil { Task { await self.startCapture() } }
    }

    private func applyBackingSize(to config: SCStreamConfiguration) {
        guard let mode = CGDisplayCopyDisplayMode(virtual.id) else { return }
        config.width = mode.pixelWidth
        config.height = mode.pixelHeight
    }

    /// The user picked another FreeRetina resolution in System Settings: follow it.
    private func virtualModeChanged() {
        guard let mode = CGDisplayCopyDisplayMode(virtual.id),
              mode.pixelWidth != streamConfig.width || mode.pixelHeight != streamConfig.height else { return }
        applyBackingSize(to: streamConfig)
        stream?.updateConfiguration(streamConfig) { error in
            if let error { DispatchQueue.main.async { self.captureFailed("\(error)") } }
        }
        emit("@mode \(mode.width) \(mode.height)", human: "FreeRetina resolution: looks like \(mode.width)x\(mode.height), rendered \(mode.pixelWidth)x\(mode.pixelHeight)")
    }

    private static let reconfigured: CGDisplayReconfigurationCallBack = { display, flags, user in
        guard let user, !flags.contains(.beginConfigurationFlag) else { return }
        let session = Unmanaged<LiveSession>.fromOpaque(user).takeUnretainedValue()
        DispatchQueue.main.async {
            if display == session.physical.id {
                if flags.contains(.removeFlag) || CGDisplayIsOnline(display) == 0 { session.fail("Monitor wurde getrennt") }
                else if flags.contains(.mirrorFlag) { session.fail("Monitor wird gespiegelt") }
            } else if display == session.virtual.id {
                if flags.contains(.removeFlag) { session.fail("FreeRetina-Display wurde entfernt") }
                else { session.virtualModeChanged() }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard let cvTexture, let src = CVMetalTextureGetTexture(cvTexture) else { return }
        presenter.submit(src, keepAlive: cvTexture)
        DispatchQueue.main.async { self.requestFrame() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.captureFailed("\(error)") }
    }

    private func markReady() {
        guard !isReady, let mode = CGDisplayCopyDisplayMode(virtual.id) else { return }
        isReady = true
        emit("@ready \(mode.width) \(mode.height)", human: "First frame on \(physical.name).")
    }

    // MARK: Cursor

    /// The physical display is still part of the arrangement; keep the pointer off it by
    /// pinning it to the nearest point of the FreeRetina display. Polling needs no
    /// Accessibility permission, unlike an event tap.
    private func startCursorGuard() {
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 240.0, repeats: true) { [weak self] _ in
            guard let self, let location = CGEvent(source: nil)?.location else { return }
            let parked = CGDisplayBounds(self.physical.id)
            guard parked.contains(location) else { return }
            let target = CGDisplayBounds(self.virtual.id)
            let clamped = CGPoint(x: min(max(location.x, target.minX), target.maxX - 1),
                                  y: min(max(location.y, target.minY), target.maxY - 1))
            CGWarpMouseCursorPosition(clamped)
            CGAssociateMouseAndMouseCursorPosition(1)  // cancels the post-warp event suppression
        })
    }

    // MARK: Safety nets

    private func installSafetyNets() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            sources.append(source)
        }

        // A hung main thread would freeze the panel image: exit hard instead.
        watchdog.start(limit: Self.watchdogLimit)
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.watchdog.tick()
            if self.options.supervised { self.emit("@heartbeat", human: nil) }
        })

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupTimeout) { [weak self] in
            guard let self, !self.isReady else { return }
            self.fail("Kein Bild innerhalb von \(Int(Self.startupTimeout)) s")
        }

        if let seconds = options.seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stop() }
        }

        if options.supervised {
            let parent = getppid()
            if parent == 1 { exit(0) }  // parent already gone
            let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            sources.append(source)
        }
        virtual.onTermination = { [weak self] in
            DispatchQueue.main.async { self?.fail("FreeRetina-Display wurde vom System beendet") }
        }
    }

    // MARK: Lifecycle

    private func emit(_ line: String, human: String?) {
        if options.supervised { print(line) } else if let human { print(human) }
    }

    private static func report(error: String, supervised: Bool) {
        if supervised { print("@error \(error.replacingOccurrences(of: "\n", with: " "))") }
        FileHandle.standardError.write(Data("freeretina: \(error)\n".utf8))
    }

    private var stopping = false

    private func fail(_ message: String) {
        guard !stopping else { return }
        Self.report(error: message, supervised: options.supervised)
        stop(code: 1)
    }

    func stop(code: Int32 = 0) {
        if stopping {
            if code != 0 { exit(code) }  // an error during a graceful stop: leave now
            return
        }
        stopping = true
        timers.forEach { $0.invalidate() }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        window?.orderOut(nil)
        let finish = {
            if !self.options.supervised { print("FreeRetina stopped; display setup restored.") }
            exit(code)  // app-only display configuration and the virtual display are released by the system
        }
        guard let stream else { return finish() }
        // Never let a stuck capture shutdown keep the panel covered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
        stream.stopCapture { _ in DispatchQueue.main.async(execute: finish) }
    }
}

/// Runs on its own thread; if the main thread stops ticking, the process exits so macOS
/// restores the display setup.
private final class MainThreadWatchdog {
    private let lock = NSLock()
    private var last = Date()

    func tick() { lock.withLock { last = Date() } }

    func start(limit: TimeInterval) {
        tick()
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                let age = lock.withLock { Date().timeIntervalSince(last) }
                if age > limit {
                    let message = "@error Watchdog: Hauptthread hängt seit \(Int(age)) s\n"
                    FileHandle.standardOutput.write(Data(message.utf8))
                    _exit(70)
                }
            }
        }
    }
}
