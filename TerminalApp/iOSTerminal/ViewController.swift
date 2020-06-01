//
//  ViewController.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/19/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import UIKit
import SwiftTerm
import simd

class ViewController: UIViewController {
    var tv: TerminalView!
    var transparent: Bool = true
    
    func makeFrame (keyboardDelta: CGFloat) -> CGRect
    {
        CGRect (x: view.safeAreaInsets.left,
                y: view.safeAreaInsets.top,
                width: view.frame.width - view.safeAreaInsets.left - view.safeAreaInsets.right,
                height: view.frame.height - view.safeAreaInsets.bottom - view.safeAreaInsets.top - keyboardDelta)
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
        let key = UIResponder.keyboardFrameBeginUserInfoKey
        guard let frameValue = notification.userInfo?[key] as? NSValue else {
            return
        }
        let frame = frameValue.cgRectValue
        keyboardDelta = frame.height
        tv.frame = makeFrame(keyboardDelta: frame.height)
    }
    
    @objc private func keyboardWillHide(_ notification: NSNotification) {
        //let key = UIResponder.keyboardFrameBeginUserInfoKey
        keyboardDelta = 0
        tv.frame = makeFrame(keyboardDelta: 0)
    }
    
    var metal: Bool = false
    var metalHost: MetalHost!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view, typically from a nib.
        setupKeyboardMonitor()
        tv = SshTerminalView(frame: makeFrame (keyboardDelta: 0))
        
        if transparent {
            if metal {
                let layer = CAMetalLayer ()
                layer.frame = tv.bounds
                
                layer.pixelFormat = .bgra8Unorm
                
                if let metalHost = MetalHost (target: layer) {
                    view.layer.addSublayer(layer)
                    self.metalHost = metalHost
                    metalHost.startRunning()
                }
            } else {
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
        }
        
        view.addSubview(tv)
        tv.becomeFirstResponder()
        tv.feed(text: "Welcome to SwiftTerm - connecting to my localhost\n\n")
    }
    
    override func viewWillLayoutSubviews() {
        tv.frame = makeFrame (keyboardDelta: keyboardDelta)
        if transparent {
            tv.backgroundColor = UIColor.clear
        }
    }
}

