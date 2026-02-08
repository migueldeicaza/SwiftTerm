//
//  TerminalProgressBarView.swift
//  SwiftTerm
//
//  Created by Codex on 2/1/26.
//

#if os(macOS)
import AppKit
typealias ProgressBarBaseView = NSView
typealias ProgressBarColor = NSColor
#elseif os(iOS) || os(visionOS) || os(tvOS)
import UIKit
typealias ProgressBarBaseView = UIView
typealias ProgressBarColor = UIColor
#endif
import QuartzCore

final class TerminalProgressBarView: ProgressBarBaseView {
    private let trackLayer = CALayer()
    private let barLayer = CALayer()
    private let indeterminateAnimationKey = "terminalProgressIndeterminate"

    private let barWidthRatio: CGFloat = 0.25
    private let indeterminateDuration: CFTimeInterval = 1.2
    private let determinateDuration: CFTimeInterval = 0.2

    private var state: Terminal.ProgressReportState = .remove
    private var progress: UInt8?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
#if os(macOS)
        wantsLayer = true
        layer?.masksToBounds = true
        trackLayer.isHidden = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(barLayer)
#else
        layer.masksToBounds = true
        trackLayer.isHidden = true
        layer.addSublayer(trackLayer)
        layer.addSublayer(barLayer)
#endif
        #if os(iOS) || os(visionOS) || os(tvOS)
        isUserInteractionEnabled = false
        #endif
    }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func layout() {
        super.layout()
        updateForCurrentState(animated: false)
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        updateForCurrentState(animated: false)
    }
    #endif

    func apply(state: Terminal.ProgressReportState, progress: UInt8?) {
        self.state = state
        self.progress = progress
        isHidden = (state == .remove)
        if isHidden {
            stopIndeterminateAnimation()
            return
        }

        let color = color(for: state)
        barLayer.backgroundColor = color.cgColor
        trackLayer.backgroundColor = color.withAlphaComponent(0.3).cgColor
        updateForCurrentState(animated: true)
    }

    private func updateForCurrentState(animated: Bool) {
        guard !isHidden else { return }
        trackLayer.frame = bounds
        if let progress {
            updateDeterminate(progress: progress, animated: animated)
        } else {
            updateIndeterminate()
        }
    }

    private func updateDeterminate(progress: UInt8, animated: Bool) {
        trackLayer.isHidden = true
        stopIndeterminateAnimation()

        let width = bounds.width * CGFloat(progress) / 100
        let targetFrame = CGRect(x: 0, y: 0, width: width, height: bounds.height)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(determinateDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        barLayer.frame = targetFrame
        CATransaction.commit()
    }

    private func updateIndeterminate() {
        trackLayer.isHidden = false

        let width = bounds.width * barWidthRatio
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()

        guard width > 0, bounds.width > width else {
            stopIndeterminateAnimation()
            return
        }

        stopIndeterminateAnimation()
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = width / 2
        animation.toValue = bounds.width - width / 2
        animation.duration = indeterminateDuration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        barLayer.add(animation, forKey: indeterminateAnimationKey)
    }

    private func stopIndeterminateAnimation() {
        barLayer.removeAnimation(forKey: indeterminateAnimationKey)
    }

    private func color(for state: Terminal.ProgressReportState) -> ProgressBarColor {
        switch state {
        case .error:
            return .systemRed
        case .pause:
            return .systemOrange
        default:
            #if os(macOS)
            return .controlAccentColor
            #else
            return tintColor ?? .systemBlue
            #endif
        }
    }
}
