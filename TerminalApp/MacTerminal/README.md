This is an example application that shows the AppKit SwiftTerm in action, the UI
is just there to showcase the NSView.

MacTerminal gives Command keys to programs that enable the enhanced keyboard
protocol. This includes Command-C and other MacTerminal menu shortcuts, so
those menu actions do not run while the program uses this protocol. In legacy
keyboard mode, the menu shortcuts still work. The setting is in
`ViewController.viewDidLoad`.
