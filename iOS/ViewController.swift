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
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        tv = TerminalView(frame: view.frame)
        view.addSubview(tv)
    }


}

