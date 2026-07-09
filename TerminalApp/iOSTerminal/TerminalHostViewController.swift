//
//  TerminalHostViewController.swift
//  iOSTerminal
//
//  Created by Codex on 1/15/25.
//

import UIKit

final class TerminalHostViewController: UIViewController {
    private let terminalView = SshTerminalView(frame: .zero)
    private var connectionInfo: SSHConnectionInfo?
#if DEBUG
    private let debugFloodButton = UIButton(type: .system)
    private let debugFloodQueue = DispatchQueue(label: "swiftterm-ios-debug-flood", qos: .userInitiated)
    private let debugFloodLock = NSLock()
    private var debugFloodRunning = false
    private var debugFloodBytes = 0
    private var debugFloodStartedAt = Date()
    private var debugFloodTimer: Timer?
#endif

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        view.isOpaque = true
        terminalView.isOpaque = true
        terminalView.backgroundColor = .black
        terminalView.nativeBackgroundColor = .black
        terminalView.contentInsetAdjustmentBehavior = .never
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor).isActive = true
        terminalView.leftAnchor.constraint(equalTo: view.leftAnchor).isActive = true
        terminalView.rightAnchor.constraint(equalTo: view.rightAnchor).isActive = true

        if #available(iOS 15.0, *) {
            view.keyboardLayoutGuide.topAnchor.constraint(equalTo: terminalView.bottomAnchor).isActive = true
        } else {
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        }

        if let info = connectionInfo {
            terminalView.configure(connectionInfo: info)
        }

#if DEBUG
        setupDebugFloodHarness()
#endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        terminalView.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        _ = terminalView.resignFirstResponder()
    }

    func updateConnectionInfo(_ info: SSHConnectionInfo) {
        if connectionInfo == info {
            return
        }
        connectionInfo = info
        if isViewLoaded {
            terminalView.configure(connectionInfo: info)
        }
    }

    deinit {
#if DEBUG
        stopDebugFlood()
#endif
    }
}

#if DEBUG
private extension TerminalHostViewController {
    func setupDebugFloodHarness() {
        debugFloodButton.setTitle("Flood", for: .normal)
        debugFloodButton.setTitleColor(.white, for: .normal)
        debugFloodButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        debugFloodButton.layer.cornerRadius = 14
        debugFloodButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        debugFloodButton.translatesAutoresizingMaskIntoConstraints = false
        debugFloodButton.addTarget(self, action: #selector(toggleDebugFlood), for: .touchUpInside)
        view.addSubview(debugFloodButton)

        NSLayoutConstraint.activate([
            debugFloodButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            debugFloodButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        ])
    }

    @objc func toggleDebugFlood() {
        debugFloodLock.lock()
        let shouldStart = !debugFloodRunning
        debugFloodLock.unlock()

        if shouldStart {
            startDebugFlood()
        } else {
            stopDebugFlood()
        }
    }

    func startDebugFlood() {
        debugFloodLock.lock()
        guard !debugFloodRunning else {
            debugFloodLock.unlock()
            return
        }
        debugFloodRunning = true
        debugFloodBytes = 0
        debugFloodStartedAt = Date()
        debugFloodLock.unlock()

        debugFloodButton.setTitle("Stop Flood", for: .normal)
        debugFloodTimer?.invalidate()
        debugFloodTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.sampleDebugFloodState()
        }

        debugFloodQueue.async { [weak self] in
            self?.runDebugFlood()
        }
    }

    func stopDebugFlood() {
        debugFloodLock.lock()
        let wasRunning = debugFloodRunning
        debugFloodRunning = false
        debugFloodLock.unlock()

        guard wasRunning else { return }
        debugFloodTimer?.invalidate()
        debugFloodTimer = nil
        debugFloodButton.setTitle("Flood", for: .normal)
        sampleDebugFloodState()
    }

    func runDebugFlood() {
        var burstIndex = 0
        while isDebugFloodRunning {
            let burst = makeDebugFloodBurst(index: burstIndex)
            terminalView.feed(byteArray: burst[...])
            debugFloodLock.lock()
            debugFloodBytes += burst.count
            debugFloodLock.unlock()
            burstIndex += 1
        }
    }

    var isDebugFloodRunning: Bool {
        debugFloodLock.lock()
        defer { debugFloodLock.unlock() }
        return debugFloodRunning
    }

    func sampleDebugFloodState() {
        _ = terminalView.getSelection()
        let scroll = terminalView.scrollPosition

        debugFloodLock.lock()
        let bytes = debugFloodBytes
        let elapsed = max(0.001, Date().timeIntervalSince(debugFloodStartedAt))
        debugFloodLock.unlock()

        let mib = Double(bytes) / 1_048_576.0
        let mibPerSecond = mib / elapsed
        print(String(format: "[SwiftTerm Debug Flood] %.2f MiB, %.2f MiB/s, scroll=%.3f", mib, mibPerSecond, scroll))
    }

    func makeDebugFloodBurst(index: Int) -> [UInt8] {
        var text = ""
        text.reserveCapacity(64 * 1024)
        var line = 0
        while text.utf8.count < 64 * 1024 {
            let color = 31 + ((index + line) % 6)
            text += "\u{1b}[\(color)mdebug flood \(index)-\(line) "
            text += "abcdefghijklmnopqrstuvwxyz 0123456789 "
            text += "\u{1b}[0m"
            if line % 8 == 0 {
                text += "\u{1b}[44mstatus block\u{1b}[0m "
            }
            text += "\r\n"
            line += 1
        }
        return Array(text.utf8.prefix(64 * 1024))
    }
}
#endif
