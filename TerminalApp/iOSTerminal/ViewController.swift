//
//  ViewController.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/19/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import UIKit
import SwiftUI
import SwiftTerm

class ViewController: UIViewController {
    private var hostingController: UIHostingController<SSHLoginView>?
#if DEBUG
    private var didOpenPointerTestAtLaunch = false
#endif

    override func viewDidLoad() {
        super.viewDidLoad()

        let rootView = SSHLoginView()
        let hosting = UIHostingController(rootView: rootView)
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hosting.didMove(toParent: self)
        hostingController = hosting
#if DEBUG
        let pointerButton = UIButton(type: .system)
        pointerButton.setTitle("Pointer Test", for: .normal)
        pointerButton.accessibilityIdentifier = "pointerTestButton"
        pointerButton.addTarget(self, action: #selector(showPointerTest), for: .touchUpInside)
        pointerButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pointerButton)
        NSLayoutConstraint.activate([
            pointerButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            pointerButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)
        ])
#endif
    }

#if DEBUG
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didOpenPointerTestAtLaunch,
           ProcessInfo.processInfo.arguments.contains("--pointer-input-test"), presentedViewController == nil {
            didOpenPointerTestAtLaunch = true
            showPointerTest()
        }
    }

    @objc private func showPointerTest() {
        let controller = PointerTestViewController()
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: false)
    }
#endif
}

#if DEBUG
/// Observes real pointer input without an SSH connection.
private final class PointerTestViewController: UIViewController, TerminalViewDelegate {
    private let terminalView = SwiftTerm.TerminalView(frame: .zero)
    private let modeControl = UISegmentedControl(items: ["Off", "1000", "1002", "1003"])
    private let reportingSwitch = UISwitch()
    private let reportLabel = UILabel()
    private let countLabel = UILabel()
    private let scrollLabel = UILabel()
    private var motionCount = 0
    private var wheelCount = 0
    private var reportCount = 0
    private var pendingReport = ""
    private var didPopulate = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Pointer Input Test"
        title.font = .preferredFont(forTextStyle: .headline)
        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.addTarget(self, action: #selector(closeTest), for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [title, close])
        header.distribution = .equalSpacing
        modeControl.selectedSegmentIndex = 3
        modeControl.accessibilityLabel = "Mouse tracking mode"
        modeControl.accessibilityIdentifier = "pointerMode"
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        let gateLabel = UILabel()
        gateLabel.text = "Allow mouse reporting"
        reportingSwitch.isOn = true
        reportingSwitch.accessibilityLabel = "Allow mouse reporting"
        reportingSwitch.accessibilityIdentifier = "pointerReportingGate"
        reportingSwitch.addTarget(self, action: #selector(gateChanged), for: .valueChanged)
        let gate = UIStackView(arrangedSubviews: [gateLabel, reportingSwitch])
        gate.distribution = .equalSpacing
        reportLabel.text = "Last report: none"
        reportLabel.numberOfLines = 2
        reportLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        reportLabel.accessibilityIdentifier = "pointerLastReport"
        countLabel.accessibilityIdentifier = "pointerCounters"
        scrollLabel.accessibilityIdentifier = "pointerScrollPosition"
        scrollLabel.text = "Local scroll: bottom"
        updateCounts()
        let controls = UIStackView(arrangedSubviews: [header, modeControl, gate, reportLabel, countLabel, scrollLabel])
        controls.axis = .vertical
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        terminalView.terminalDelegate = self
        terminalView.accessibilityLabel = "Pointer test terminal"
        terminalView.accessibilityIdentifier = "pointerTerminal"
        terminalView.contentInsetAdjustmentBehavior = .never
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            terminalView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            terminalView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !didPopulate, terminalView.bounds.height > 0 else { return }
        didPopulate = true
        terminalView.feed(text: (1...80).map { "Line \($0): move the pointer or scroll the wheel.\r\n" }.joined())
        terminalView.scrollTo(row: Int.max)
        modeChanged()
    }

    @objc private func closeTest() { dismiss(animated: true) }

    @objc private func modeChanged() {
        terminalView.feed(text: "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006h")
        if modeControl.selectedSegmentIndex > 0 {
            let modes = [0, 1000, 1002, 1003]
            terminalView.feed(text: "\u{1b}[?\(modes[modeControl.selectedSegmentIndex])h")
        }
    }

    @objc private func gateChanged() {
        terminalView.allowMouseReporting = reportingSwitch.isOn
    }

    private func updateCounts() {
        countLabel.text = "Reports: \(reportCount)  Motion: \(motionCount)  Wheel: \(wheelCount)"
    }

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        pendingReport += String(decoding: data, as: UTF8.self)
        while let start = pendingReport.range(of: "\u{1b}[<") {
            let body = pendingReport[start.upperBound...]
            guard let end = body.firstIndex(where: { $0 == "M" || $0 == "m" }) else { break }
            let fields = body[..<end].split(separator: ";").compactMap { Int($0) }
            let raw = String(pendingReport[start.lowerBound...end])
            pendingReport.removeSubrange(...end)
            guard fields.count == 3 else { continue }
            reportCount += 1
            if fields[0] & 64 != 0 { wheelCount += 1 }
            else if fields[0] & 32 != 0 { motionCount += 1 }
            reportLabel.text = "Last: \(raw.replacingOccurrences(of: "\u{1b}", with: "ESC"))\nCb=\(fields[0]) column=\(fields[1]) row=\(fields[2])"
            updateCounts()
        }
        if pendingReport.utf8.count > 4096 { pendingReport = "" }
    }

    func scrolled(source: SwiftTerm.TerminalView, position: Double) {
        scrollLabel.text = String(format: "Local scroll: %.3f", position)
    }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}
#endif
