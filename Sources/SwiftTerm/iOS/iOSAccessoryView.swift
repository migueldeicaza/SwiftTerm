//
//  iOSAccessoryView.swift
//  
//  Implements an inputAccessoryView for the iOS terminal for common operations
//
//  Created by Miguel de Icaza on 5/9/20.
//
#if os(iOS)

import Foundation
import UIKit

/**
 * This class provides an input accessory for the terminal on iOS, you can access this via the `inputAccessoryView`
 * property in the `TerminalView` and casting the result to `TerminalAccessory`.
 *
 * This class surfaces some state that the terminal might want to poke at, you should at least support the following
 * properties;
 * `controlModifer` should be set if the control key is pressed
 */
public class TerminalAccessory: UIInputView {
    /// This points to an instanace of the `TerminalView` where events are sent
    public var terminalView: TerminalView! {
        didSet {
            terminal = terminalView.getTerminal()
        }
    }
    var terminal: Terminal!
    var controlButton: UIButton!
    /// This tracks whether the "control" button is turned on or not
    public var controlModifier: Bool = false {
        didSet {
            controlButton.isSelected = controlModifier
        }
    }
    
    var views: [UIView] = []
    
    public override init (frame: CGRect, inputViewStyle: UIInputView.Style)
    {
        super.init (frame: frame, inputViewStyle: inputViewStyle)
        setupUI()
        allowsSelfSizing = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc func esc (_ sender: AnyObject) { terminalView.send([0x1b]) }
    @objc func tab (_ sender: AnyObject) { terminalView.send([0x9]) }
    @objc func tilde (_ sender: AnyObject) { terminalView.send([UInt8 (ascii: "~")]) }
    @objc func pipe (_ sender: AnyObject) { terminalView.send([UInt8 (ascii: "|")]) }
    @objc func slash (_ sender: AnyObject) { terminalView.send([UInt8 (ascii: "/")]) }
    @objc func dash (_ sender: AnyObject) { terminalView.send([UInt8 (ascii: "-")]) }
    
    @objc
    func ctrl (_ sender: UIButton)
    {
        controlModifier.toggle()
    }

    @objc func up (_ sender: UIButton)
    {
        terminalView.sendKeyUp()
    }
    
    @objc func down (_ sender: UIButton)
    {
        terminalView.sendKeyDown ()
    }
    
    @objc func left (_ sender: UIButton)
    {
        terminalView.sendKeyLeft()
    }
    
    @objc func right (_ sender: UIButton)
    {
        terminalView.sendKeyRight()
    }

    /**
     * This method setups the internal data structures to setup the UI shown on the accessory view,
     * if you provide your own implementation, you are responsible for adding all the elements to the
     * this view, and flagging some of the public properties declared here.
     */
    public func setupUI ()
    {
        views.append(makeButton ("esc", #selector(esc)))
        controlButton = makeButton ("ctrl", #selector(ctrl))
        views.append(controlButton)
        views.append(makeButton ("tab", #selector(tab)))
        views.append(makeButton ("~", #selector(tilde)))
        views.append(makeButton ("|", #selector(pipe)))
        views.append(makeButton ("/", #selector(slash)))
        views.append(makeButton ("-", #selector(dash)))
        views.append(makeButtonImage ("chevron.left", #selector(left)))
        views.append(makeButtonImage ("chevron.up", #selector(up)))
        views.append(makeButtonImage ("chevron.down", #selector(downvi )))
        views.append(makeButtonImage ("chevron.right", #selector(right)))
        for view in views {
            view.sizeToFit()
            addSubview(view)
        }
        layoutSubviews ()
    }
    
    public override func layoutSubviews() {
        var x: CGFloat = 2
        var dh = views.reduce (0) { max ($0, $1.frame.size.height )}
        for view in views {
            let size = view.frame.size
            view.frame = CGRect(x: x, y: 4, width: size.width, height: dh)
            x += size.width + 6
        }
    }
    
    func makeButtonImage (_ iconName: String, _ action: Selector) -> UIButton
    {
        let b = makeButton ("", action)
        b.setImage(UIImage (systemName: iconName), for: .normal)
        return b
    }
    
    func makeButton (_ title: String, _ action: Selector) -> UIButton
    {
        let b = UIButton.init(type: .roundedRect)
        styleButton (b)
        b.addTarget(self, action: action, for: .touchDown)
        b.setTitle(title, for: .normal)
        b.backgroundColor = UIColor.white
        return b
    }
    
    // I am not committed to this style, this is just something quick to get going
    func styleButton (_ b: UIButton)
    {
        b.layer.cornerRadius = 4
        b.layer.shadowColor = UIColor.gray.cgColor
        b.layer.masksToBounds = true
    }
}
#endif
