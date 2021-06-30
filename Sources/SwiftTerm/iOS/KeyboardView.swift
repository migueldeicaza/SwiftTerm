//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 6/29/21.
//

import Foundation
import UIKit


@available(iOS 15.0, *)
class KeyboardView: UIInputView {
    weak var terminalView: TerminalView?
    
    public init (_ terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init (frame: CGRect (x: 0, y: 0, width: 0, height: 0), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        makeContent ()
    }
    
    func makeContent () {
        let stackView = createStackView(axis: .vertical)
        stackView.frame = bounds
        stackView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(stackView)
        
        for _ in 0 ..< 3 {
            let subStackView = createStackView(axis: .horizontal)
            stackView.addArrangedSubview(subStackView)
            
            func add (_ text: String, _ send: [UInt8]) {
                let b = makeButton (caption: text, send: send)
                subStackView.addArrangedSubview(b)
            }
            add ("F1", EscapeSequences.cmdF[0])
            add ("F2", EscapeSequences.cmdF[1])
            add ("F3", EscapeSequences.cmdF[2])
            add ("F4", EscapeSequences.cmdF[3])
            add ("F5", EscapeSequences.cmdF[4])
            add ("F6", EscapeSequences.cmdF[5])
            add ("F7", EscapeSequences.cmdF[6])
            add ("F8", EscapeSequences.cmdF[7])
            add ("F9", EscapeSequences.cmdF[8])
            add ("F0", EscapeSequences.cmdF[9])
        }
    }
    
    func createStackView(axis: NSLayoutConstraint.Axis) -> UIStackView {
        let stackView = UIStackView()
        stackView.axis = axis
        stackView.alignment = .fill
        stackView.distribution = .equalSpacing
        return stackView
    }
    
    
    func makeButton (caption: String, send: [UInt8]) -> UIButton {
        
        var cfg = UIButton.Configuration.plain()
        cfg.buttonSize = .medium
        cfg.buttonSize = .small
        cfg.title = caption
        cfg.cornerStyle = .medium
        cfg.background.backgroundColor = UIColor.systemBackground
        
        
        let button = UIButton (configuration: cfg, primaryAction: UIAction { x in
            self.terminalView?.send(send)
        })
        
        
        return button
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
