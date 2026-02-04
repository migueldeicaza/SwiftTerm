//
//  MacFindBarView.swift
//  SwiftTerm
//

#if os(macOS)
import AppKit

final class TerminalFindBarView: NSVisualEffectView, NSSearchFieldDelegate {
    var onSearchChanged: ((String) -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    var onOptionsChanged: ((SearchOptions) -> Void)?

    private let searchField = NSSearchField()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()
    private let caseSensitiveButton = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
    private let regexButton = NSButton(checkboxWithTitle: ".*", target: nil, action: nil)
    private let wholeWordButton = NSButton(checkboxWithTitle: "Word", target: nil, action: nil)

    var searchText: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    var options: SearchOptions {
        SearchOptions(
            caseSensitive: caseSensitiveButton.state == .on,
            regex: regexButton.state == .on,
            wholeWord: wholeWordButton.state == .on
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func focus() {
        window?.makeFirstResponder(searchField)
    }

    private func setup() {
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        searchField.placeholderString = "Find"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureButton(previousButton, symbol: "chevron.up", tooltip: "Previous")
        previousButton.target = self
        previousButton.action = #selector(previousTapped)

        configureButton(nextButton, symbol: "chevron.down", tooltip: "Next")
        nextButton.target = self
        nextButton.action = #selector(nextTapped)

        configureButton(closeButton, symbol: "xmark", tooltip: "Close")
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        configureOptionButton(caseSensitiveButton, tooltip: "Case Sensitive")
        configureOptionButton(regexButton, tooltip: "Regex")
        configureOptionButton(wholeWordButton, tooltip: "Whole Word")

        let stack = NSStackView(views: [
            searchField,
            previousButton,
            nextButton,
            caseSensitiveButton,
            regexButton,
            wholeWordButton,
            closeButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
    }

    private func configureButton(_ button: NSButton, symbol: String, tooltip: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.toolTip = tooltip
    }

    private func configureOptionButton(_ button: NSButton, tooltip: String) {
        button.setButtonType(.switch)
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.toolTip = tooltip
        button.target = self
        button.action = #selector(optionChanged)
    }

    @objc private func searchFieldAction() {
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
            onFindPrevious?()
        } else {
            onFindNext?()
        }
    }

    @objc private func previousTapped() {
        onFindPrevious?()
    }

    @objc private func nextTapped() {
        onFindNext?()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func optionChanged() {
        onOptionsChanged?(options)
    }

    func controlTextDidChange(_ obj: Notification) {
        onSearchChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            searchFieldAction()
            return true
        }
        return false
    }
}
#endif
