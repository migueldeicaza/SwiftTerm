This is an example application that shows the AppKit SwiftTerm in action, the UI
is just there to showcase the NSView.

MacTerminal gives Command keys to programs that enable the enhanced keyboard
protocol. If text is selected, Command-C uses menu Copy. Without a selection,
Command-C goes to the program. Other MacTerminal menu shortcuts go to the
program while it uses this protocol. In legacy keyboard mode, the menu
shortcuts still work. The setting is in `ViewController.viewDidLoad`.
