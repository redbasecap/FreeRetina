import AppKit

/// Runs the pipeline for one monitor in a child process (`freeretina run --supervised`).
/// A hung or crashed child is killed/reaped and macOS restores the display setup, so the
/// menu bar app itself never holds display state.
final class EngineSupervisor {
    enum State: Equatable {
        case stopped
        case starting
        case running(looks: CGSize)
        case failed(String)
    }

    let display: PhysicalDisplay
    private(set) var config: DisplayConfig
    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?() } }
    }

    var onStateChange: (() -> Void)?
    var onModeChange: ((CGSize) -> Void)?
    /// Repeated failures: the app should disable auto-start and tell the user.
    var onGiveUp: ((String) -> Void)?

    static let heartbeatLimit: TimeInterval = 10
    static let startupLimit: TimeInterval = LiveSession.startupTimeout + 10

    private var process: Process?
    private var lastHeartbeat = Date()
    private var startedAt = Date()
    private var watchTimer: Timer?
    private var failures: [Date] = []
    private var lastError: String?
    private var stopRequested = false
    private var reachedRunning = false
    private var lineBuffer = Data()

    init(display: PhysicalDisplay, config: DisplayConfig) {
        self.display = display
        self.config = config
    }

    var isActive: Bool {
        switch state {
        case .starting, .running: true
        default: false
        }
    }

    func start(with config: DisplayConfig) {
        self.config = config
        guard process == nil else { return restart() }
        guard let executable = Bundle.main.executableURL else { return state = .failed("Programmdatei nicht gefunden") }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "run", "--supervised",
            "--display", String(display.id),
            "--order", config.order.rawValue,
            "--strength", String(config.strength),
            "--looks", "\(config.looksWidth)x\(config.looksHeight)",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.terminated(finished) }
        }

        stopRequested = false
        reachedRunning = false
        lastError = nil
        lineBuffer = Data()
        do {
            try process.run()
        } catch {
            state = .failed("Start fehlgeschlagen: \(error.localizedDescription)")
            return
        }
        self.process = process
        startedAt = Date()
        lastHeartbeat = Date()
        state = .starting
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.watch() }
    }

    func stop() {
        stopRequested = true
        guard let process else { return state = .stopped }
        terminate(process)
    }

    private func restart() {
        let config = self.config
        stopRequested = true
        guard let process else { return start(with: config) }
        pendingRestart = config
        terminate(process)
    }

    private var pendingRestart: DisplayConfig?

    /// SIGTERM lets the child stop capture cleanly; SIGKILL follows if it does not exit.
    private func terminate(_ process: Process, hard: Bool = false) {
        guard process.isRunning else { return }
        if hard {
            kill(process.processIdentifier, SIGKILL)
            return
        }
        process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func watch() {
        guard let process else { return }
        let now = Date()
        if state == .starting, now.timeIntervalSince(startedAt) > Self.startupLimit {
            lastError = "Start dauerte zu lange"
            terminate(process, hard: true)
        } else if now.timeIntervalSince(lastHeartbeat) > Self.heartbeatLimit {
            lastError = "Keine Rückmeldung mehr (Heartbeat)"
            terminate(process, hard: true)
        }
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: lineBuffer[lineBuffer.startIndex..<newline], as: UTF8.self)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }
        let rest = parts.count > 1 ? parts[1] : ""
        switch command {
        case "@heartbeat":
            lastHeartbeat = Date()
        case "@ready", "@mode":
            lastHeartbeat = Date()
            let numbers = rest.split(separator: " ").compactMap { Int($0) }
            guard numbers.count == 2 else { return }
            let looks = CGSize(width: numbers[0], height: numbers[1])
            reachedRunning = true
            state = .running(looks: looks)
            if command == "@mode" {
                config.looksWidth = numbers[0]
                config.looksHeight = numbers[1]
                onModeChange?(looks)
            }
        case "@error":
            lastError = rest
        default:
            break
        }
    }

    private func terminated(_ finished: Process) {
        guard finished === process else { return }
        process = nil
        watchTimer?.invalidate()
        watchTimer = nil

        if let config = pendingRestart {
            pendingRestart = nil
            return start(with: config)
        }
        if stopRequested || (finished.terminationStatus == 0 && finished.terminationReason == .exit) {
            state = .stopped
            return
        }

        let message = lastError ?? "Unerwartet beendet (Status \(finished.terminationStatus))"
        state = .failed(message)
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < 120 } + [now]
        // Only retry something that already worked (sleep, GPU reset, hiccup); a setup that
        // never came up would fail the same way again.
        if reachedRunning && failures.count < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.process == nil, case .failed = self.state else { return }
                self.start(with: self.config)
            }
        } else {
            onGiveUp?(message)
        }
    }
}
