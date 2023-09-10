//
//  iOSKeyboardView.swift: implements the alternate keyboard that
//  surfaces a few additional keys that the users might want to send
//
//  Created by Miguel de Icaza on 7/15/21.
//
#if os(iOS) || os(visionOS)
import Foundation
import UIKit

class KeyboardView: UIView {
    weak var terminalView: TerminalView?
    let small = ["1234567890",
                 "[]{}<>&ihp",
                 "+-*=%`\\deP"]

    public init (frame: CGRect, terminalView: TerminalView?) {
        self.terminalView = terminalView
        super.init (frame: frame)
        buildUI ()
    }
    
    func clickAndSend (_ data: [UInt8])
    {
        #if os(iOS)
        UIDevice.current.playInputClick()
        #endif
        terminalView?.send (data)
    }

    @objc func f1 (_ sender: AnyObject) { clickAndSend (EscapeSequences.cmdF[0]) }
    @objc func f2 (_ sender: AnyObject) { clickAndSend (EscapeSequences.cmdF[1]) }
    @objc func f3 (_ sender: AnyObject) { clickAndSend (EscapeSequences.cmdF[2]) }
    @objc func f4 (_ sender: AnyObject) { clickAndSend (EscapeSequences.cmdF[3]) }
    @objc func f5 (_ sender: AnyObject) { clickAndSend (EscapeSequences.cmdF[4]) }
    @objc func f6 (_ sender: AnyObject) { clickAndSend (EscapeSequences.cmdF[5]) }
    @objc func f7 (_ sender: AnyObject) { clickAndSend (EscapeSequences.cmdF[6]) }
    @objc func f8 (_ sender: AnyObject) { clickAndSend (EscapeSequences.cmdF[7]) }
    @objc func f9 (_ sender: AnyObject) { clickAndSend (EscapeSequences.cmdF[8]) }
    @objc func f10 (_ sender: AnyObject) { clickAndSend (EscapeSequences.cmdF[9]) }
    @objc func openbracket (_sender: AnyObject) { clickAndSend ([UInt8 (ascii: "[")]) }
    @objc func closebracket (_sender: AnyObject) { clickAndSend ([UInt8 (ascii: "]")]) }
    @objc func openbrace (_sender: AnyObject) { clickAndSend ([UInt8 (ascii: "{")]) }
    @objc func closebrace (_sender: AnyObject) { clickAndSend ([UInt8 (ascii: "}")]) }
    @objc func lessthan (_sender: AnyObject) { clickAndSend ([UInt8 (ascii: "<")]) }
    @objc func biggerthan (_sender: AnyObject) { clickAndSend ([UInt8 (ascii: ">")]) }
    @objc func amp (_sender: AnyObject) { clickAndSend ([UInt8 (ascii: "&")]) }
    @objc func insert (_sender: AnyObject) { clickAndSend (EscapeSequences.cmdInsert) }
    @objc func home (_sender: AnyObject) { clickAndSend ((terminalView?.terminal.applicationCursor ?? false) ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal) }
    @objc func end (_sender: AnyObject) { clickAndSend ((terminalView?.terminal.applicationCursor ?? false) ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal) }
    @objc func pageUp (_sender: AnyObject) { clickAndSend (EscapeSequences.cmdPageUp) }
    @objc func pageDown (_sender: AnyObject) { clickAndSend (EscapeSequences.cmdPageDown) }
    @objc func plus (_ sender: AnyObject) { clickAndSend([UInt8 (ascii: "+")]) }
    @objc func minus (_ sender: AnyObject) { clickAndSend([UInt8 (ascii: "-")]) }
    @objc func star (_ sender: AnyObject) { clickAndSend([UInt8 (ascii: "*")]) }
    @objc func equal (_ sender: AnyObject) { clickAndSend([UInt8 (ascii: "=")]) }
    @objc func percent (_ sender: AnyObject) { clickAndSend([UInt8 (ascii: "%")]) }
    @objc func backtick (_ sender: AnyObject) { clickAndSend([UInt8 (ascii: "`")]) }
    @objc func backslash (_ sender: AnyObject) { clickAndSend([UInt8 (ascii: "\\")]) }
    @objc func deleteKey (_ sender: AnyObject) { clickAndSend(EscapeSequences.cmdDelKey) }

    var views: [UIView] = []
    
    func buildUI () {
        guard let terminalView else {
            return
        }
        
        for x in views {
            x.removeFromSuperview()
        }
        let source = small
        let bottomPad = 20.0
        let slotWidth = frame.width/10
        let slotHeight = (frame.height-bottomPad)/Double (source.count)
        let xpadding = min(slotWidth * 0.1, 4.0)
        let ypadding = min(slotHeight * 0.1, 4.0)
        var x = 0.0
        var y = ypadding
        
        func makeButton (_ txt: String, _ sel: Selector, img: String? = nil, isNormal: Bool = true) {
            let rect = CGRect(x: x, y: y, width: slotWidth-(xpadding*2), height: slotHeight-(ypadding*2))
            x += slotWidth
            let b = UIButton.init(type: .roundedRect)
            TerminalAccessory.styleButton(b)
            b.addTarget(self, action: sel, for: .touchDown)
            b.frame = rect
            if let icon = img {
                if let img = UIImage (systemName: icon, withConfiguration: UIImage.SymbolConfiguration (pointSize: 14.0)) {
                    b.setImage(img.withTintColor(terminalView.buttonColor, renderingMode: .alwaysOriginal), for: .normal)
                }
            } else {
                b.setTitle(txt, for: .normal)
                b.titleLabel?.adjustsFontSizeToFitWidth = true
                b.titleLabel?.numberOfLines = 1
            }
            b.setTitleColor(terminalView.buttonColor, for: .normal)
            b.backgroundColor = isNormal ? terminalView.buttonBackgroundColor : terminalView.buttonDarkBackgroundColor
            views.append(b)
            addSubview(b)
        }
        
        for row in source {
            x = xpadding
            for key in row {
                switch key {
                case "1": makeButton ("F1", #selector(f1))
                case "2": makeButton ("F2", #selector(f2))
                case "3": makeButton ("F3", #selector(f3))
                case "4": makeButton ("F4", #selector(f4))
                case "5": makeButton ("F5", #selector(f5))
                case "6": makeButton ("F6", #selector(f6))
                case "7": makeButton ("F7", #selector(f7))
                case "8": makeButton ("F8", #selector(f8))
                case "9": makeButton ("F9", #selector(f9))
                case "0": makeButton ("F10", #selector(f10))
                case "[": makeButton ("[", #selector (openbracket))
                case "]": makeButton ("]", #selector (closebracket))
                case "{": makeButton ("{", #selector (openbrace))
                case "}": makeButton ("}", #selector (closebrace))
                case "<": makeButton ("<", #selector (lessthan))
                case ">": makeButton (">", #selector (biggerthan))
                case "&": makeButton ("&", #selector (amp))
                case "i": makeButton ("ins", #selector (insert), isNormal: false)
                case "h": makeButton ("home", #selector (home), isNormal: false)
                case "p": makeButton ("pgup", #selector (pageDown), isNormal: false)
                case "+": makeButton ("+", #selector(plus))
                case "-": makeButton ("-", #selector(minus))
                case "*": makeButton ("*", #selector(star))
                case "=": makeButton ("=", #selector(equal))
                case "%": makeButton ("%", #selector(percent))
                case "`": makeButton ("`", #selector(backtick))
                case "\\": makeButton ("\\", #selector(backslash))
                case "d": makeButton ("d", #selector(deleteKey), img: "delete.forward", isNormal: false)
                case "e": makeButton ("end", #selector(end), isNormal: false)
                case "P": makeButton ("pgdn", #selector(pageDown), isNormal: false)
                default:
                    break
                }
            }
            y += slotHeight
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var bounds: CGRect {
        didSet {
            buildUI ()
        }
    }
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)

        terminalView?.setupKeyboardButtonColors()
        buildUI()
    }
}
#endif
