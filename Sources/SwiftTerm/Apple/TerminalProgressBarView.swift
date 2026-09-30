//
//  TerminalProgressBarView.swift
//  SwiftTerm
//
//  Created by Codex on 2/1/26.
//

#if !SWIFTTERM_EMBEDDED
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

    /// Thickness of the bar, in points. Ghostty uses 2; one more point reads
    /// better against terminal content without stealing a row.
    static let preferredHeight: CGFloat = 3

    private let barWidthRatio: CGFloat = 0.25
    private let indeterminateDuration: CFTimeInterval = 1.2
    private let determinateDuration: CFTimeInterval = 0.2

    private var state: Terminal.ProgressReportState = .remove
    private var progress: UInt8?
    /// Bounds the running indeterminate animation was built for.
    private var animatedBounds: CGRect = .zero

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
        // Anchored at its leading edge so growth is a width change alone, which
        // is the one property the determinate animation has to interpolate.
        barLayer.anchorPoint = .zero
        barLayer.position = .zero
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

    /// Ghostty's rule: an explicit percentage wins, a paused report with no
    /// percentage reads as complete, everything else is indeterminate.
    private var effectiveProgress: UInt8? {
        if let progress { return progress }
        return state == .pause ? 100 : nil
    }

    private func updateForCurrentState(animated: Bool) {
        guard !isHidden else { return }
        trackLayer.frame = bounds
        if let effectiveProgress {
            updateDeterminate(progress: effectiveProgress, animated: animated)
        } else {
            updateIndeterminate()
        }
    }

    private func updateDeterminate(progress: UInt8, animated: Bool) {
        trackLayer.isHidden = true
        stopIndeterminateAnimation()

        let width = bounds.width * CGFloat(progress) / 100
        let previousWidth = barLayer.bounds.width

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.position = .zero
        barLayer.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()

        guard animated, previousWidth != width else { return }

        // Reports arrive far faster than one ease lasts (a 1%-per-100ms loop is
        // typical), and an ease-in-out restarted on every one of them keeps
        // dropping back to zero velocity — monotonic, but visibly pulsing.
        // An additive animation instead animates the *delta* to zero, so the
        // ones still in flight sum with it and the motion stays continuous.
        // This is what SwiftUI does for Ghostty when it retargets mid-animation.
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = previousWidth - width
        animation.toValue = 0
        animation.isAdditive = true
        animation.duration = determinateDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        barLayer.add(animation, forKey: nil)
    }

    private func updateIndeterminate() {
        trackLayer.isHidden = false

        let width = bounds.width * barWidthRatio
        guard width > 0, bounds.width > width else {
            stopIndeterminateAnimation()
            return
        }

        // Applications repeat the indeterminate report continuously; restarting
        // the slide on every one of them makes it stutter in place instead of
        // sweeping, so it keeps running until the geometry or the state changes.
        if barLayer.animation(forKey: indeterminateAnimationKey) != nil,
           animatedBounds == bounds {
            return
        }

        stopIndeterminateAnimation()
        // Additive width animations from the determinate state may still be in
        // flight; they have no key of their own to remove.
        barLayer.removeAllAnimations()
        animatedBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.position = .zero
        barLayer.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = 0
        animation.toValue = bounds.width - width
        animation.duration = indeterminateDuration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        barLayer.add(animation, forKey: indeterminateAnimationKey)
    }

    private func stopIndeterminateAnimation() {
        animatedBounds = .zero
        barLayer.position = .zero
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

#endif // !SWIFTTERM_EMBEDDED
