//
//  ViewController.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/19/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import UIKit
import SwiftTerm

class ViewController: UIViewController {
    var tv: TerminalView!
    var transparent: Bool = false
    
    func makeFrame (keyboardDelta: CGFloat, _ fn: String = #function, _ ln: Int = #line) -> CGRect
    {
        
        let r = CGRect (x: view.safeAreaInsets.left,
                y: view.safeAreaInsets.top,
                width: view.frame.width - view.safeAreaInsets.left - view.safeAreaInsets.right,
                height: view.frame.height - view.safeAreaInsets.top - keyboardDelta)
        
        // view.safeAreaInsets.bottom -
        return r
    }
    
    func setupKeyboardMonitor ()
    {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIWindow.keyboardWillShowNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIWindow.keyboardWillHideNotification,
            object: nil)
    }
    
    var keyboardDelta: CGFloat = 0
    @objc private func keyboardWillShow(_ notification: NSNotification) {
        guard let keyboardValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        
        let keyboardScreenEndFrame = keyboardValue.cgRectValue
        let keyboardViewEndFrame = view.convert(keyboardScreenEndFrame, from: view.window)
        keyboardDelta = keyboardViewEndFrame.height
        tv.frame = makeFrame(keyboardDelta: keyboardViewEndFrame.height)
    }
    
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        tv.frame = CGRect (origin: tv.frame.origin, size: size)
    }
    
    @objc private func keyboardWillHide(_ notification: NSNotification) {
        //let key = UIResponder.keyboardFrameBeginUserInfoKey
        keyboardDelta = 0
        tv.frame = makeFrame(keyboardDelta: 0)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view, typically from a nib.
        setupKeyboardMonitor()
        tv = SshTerminalView(frame: makeFrame (keyboardDelta: 0))
        
        if transparent {
            let x = UIImage (contentsOfFile: "/tmp/Lucia.png")!.cgImage
            //let x = UIImage (systemName: "star")!.cgImage
            let layer = CALayer()
            tv.isOpaque = false
            tv.backgroundColor = UIColor.clear
            tv.nativeBackgroundColor = UIColor.clear
            layer.contents = x
            layer.frame = tv.bounds
            view.layer.addSublayer(layer)
        }
        
        view.addSubview(tv)
        tv.becomeFirstResponder()
        self.tv.feed(text: "Welcome to SwiftTerm - connecting to my localhost\n\n")
    }
    
    override func viewWillLayoutSubviews() {
        tv.frame = makeFrame (keyboardDelta: keyboardDelta)
        if transparent {
            tv.backgroundColor = UIColor.clear
        }
    }
}

