//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 7/13/21.
//
#if os(iOS) || os(visionOS)

import Foundation
import UIKit

/// This control offers two entries at the same time and responds to either
/// tapping, or pan+release which should trigger the secondary value that
/// is shown.
///
/// Set the values "primaryText" and "secondaryText" to the strings to be
/// displayed, and the `callback` method to invoke it when one of those
/// actions take place
class DoubleButton: UIControl {
    /// The main text to show
    public var primaryText: String = "M" {
        didSet {
            primaryView.text = primaryText
        }
    }
    /// The secondary text to show
    public var secondaryText: String = "O" {
        didSet {
            secondaryView.text = secondaryText
        }
    }

    /// The callback to invoke based on either a tap, or a pan+release, and will
    /// receive both the instance of this button as the first parameter, as well as a
    /// boolean indicating if this was the tap or the pan+release in the `wasPrimary`
    /// parameter.
    public var callback: (_ sender: DoubleButton, _ wasPrimary: Bool) -> () = { x, y in }
    
    var primaryView, secondaryView: UILabel
    
    var smallFrame, bigFrame: CGRect
    
    var activatePoint: CGFloat
    
    // width 28, height 40
    override init (frame: CGRect) {
        // 28 x 40
        let smallWidth = frame.width*0.43
        let bigWidth = frame.width*0.71
        // 12, 22
        let smallHeight = frame.height * 0.3
        let bigHeight = frame.height * 0.55
        smallFrame = CGRect (x: (frame.width-smallWidth)/2, y: frame.height*0.075, width: smallWidth, height: smallHeight)
        bigFrame = CGRect (x: (frame.width-bigWidth)/2, y: frame.height*0.4, width: bigWidth, height: bigHeight)
        activatePoint = frame.height / 4
        
        primaryView = UILabel (frame: bigFrame)
        primaryView.backgroundColor = UIColor.yellow
        //primaryView.textColor = UIColor.black
        primaryView.text = primaryText
        primaryView.textAlignment = .center
        primaryView.adjustsFontSizeToFitWidth = true
        
        secondaryView = UILabel (frame: smallFrame)
        secondaryView.backgroundColor = UIColor.red
        secondaryView.adjustsFontSizeToFitWidth = true
        secondaryView.text = secondaryText
        secondaryView.textAlignment = .center
        
        super.init (frame: frame)
        
        let pan = UIPanGestureRecognizer (target: self, action: #selector(pan))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer (target: self, action: #selector(tap))
        addGestureRecognizer(tap)
        
        addSubview(primaryView)
        addSubview(secondaryView)

        setColors ()
        layer.cornerRadius = 4
        
        layer.shadowColor = UIColor.secondaryLabel.cgColor
        layer.shadowOffset = CGSize (width: 0, height: 0)
        layer.shadowRadius = 0
        layer.shadowOpacity = 1
    }
    
    func setColors () {
        let backgroundColor: UIColor
        let buttonShadowColor: UIColor
        
        func getColor (_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
            return UIColor (red: r/255.0, green: g/255.0, blue: b/255.0, alpha: 1.0)
        }
        if traitCollection.userInterfaceStyle == .dark {
            backgroundColor = UIColor (red: 150/255.0, green: 150/255.0, blue: 150/255.0, alpha: 1)
            buttonShadowColor = UIColor (red: 26/255.0, green: 26/255.0, blue: 26/255.0, alpha: 1)
        } else {
            backgroundColor = UIColor (red: 1, green: 1, blue: 1, alpha: 1)
            buttonShadowColor = UIColor (red: 139/255.0, green: 141/255.0, blue: 144/255.0, alpha: 1)
        }
        layer.backgroundColor = backgroundColor.cgColor
        layer.shadowColor = buttonShadowColor.cgColor
        secondaryView.textColor = UIColor.systemGray
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)

        setColors ()
    }
    
    func resetLocation ()
    {
        UIView.animate(withDuration: 0.3) {
            self.primaryView.frame = self.bigFrame
            self.secondaryView.frame = self.smallFrame
            self.secondaryView.textColor = UIColor.systemGray
            self.primaryView.alpha = 1
            self.layer.masksToBounds = false
        }
    }

    @objc
    func tap(_ tapGesture: UITapGestureRecognizer) {
        callback (self, true)
    }
    
    @objc
    func pan(_ panGesture: UIPanGestureRecognizer) {
        switch panGesture.state {
        case .began:
            layer.masksToBounds = true
            break
        case .cancelled:
            resetLocation()
            break
        case .ended:
            let translation = panGesture.translation(in: panGesture.view)
            callback (self, translation.y < activatePoint)
            resetLocation()
            break
        case .failed:
            resetLocation()
            break
        case .possible:
            break
        case .changed:
            let translation = panGesture.translation(in: panGesture.view)
            
            let maxDeltaY = frame.height-(smallFrame.maxX)-(frame.height*0.125)
            let deltaY = max (0, min (maxDeltaY, translation.y))
            let secondaryW = smallFrame.width + deltaY*0.4
            let newSecondary = CGRect (
                origin: CGPoint (x: (frame.width-secondaryW)/2, y: smallFrame.minY + deltaY),
                size: CGSize (width: secondaryW, height: smallFrame.height + deltaY * 0.5))
            secondaryView.frame = newSecondary
            
            let primaryW = bigFrame.width - deltaY * 0.6
            let newPrimary = CGRect (
                origin: CGPoint (x: (frame.width-primaryW)/2, y: bigFrame.minY + deltaY * 1.3),
                size: CGSize (width: primaryW, height: bigFrame.height - (deltaY * 0.3)))
            
            primaryView.frame = newPrimary
            primaryView.alpha = 1-(deltaY/maxDeltaY)
            if deltaY > activatePoint {
                primaryView.alpha = 0
                secondaryView.textColor = UIColor.label
            }
            break
        @unknown default:
            resetLocation()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
