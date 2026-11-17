//
//  LocalProcessHostStubs.swift
//
//  Empty stubs for the four required LocalProcessTerminalViewDelegate
//  methods, so that each test host declares only the hooks that it tests.
//
//  This is a protocol, not a base class. A protocol-extension default is fixed
//  for the class that declares the conformance, so a test host that inherits
//  its conformance from a base class does not get its own optional hooks
//  called.
//
//  Use these stubs only in a host that implements no required method. A stub
//  hides a required method that has an incorrect signature. A host that
//  implements a required method conforms to the delegate protocol directly.
//
#if os(macOS)
import Foundation

@testable import SwiftTerm

@MainActor
protocol LocalProcessHostStubs: LocalProcessTerminalViewDelegate {}

extension LocalProcessHostStubs {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

/// A host that implements only the required methods. It gets each default.
@MainActor
final class MinimalLocalProcessHost: LocalProcessHostStubs {}
#endif
