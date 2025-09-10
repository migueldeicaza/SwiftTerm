# SwiftTerm Windows Port Implementation

This document describes the implementation of Issue #136 - Windows Port for SwiftTerm.

## Overview

The Windows port provides the foundation for running SwiftTerm on Windows platforms. This implementation creates the necessary infrastructure for building Windows terminal applications using various UI frameworks.

## Implementation Status

### ✅ Completed Components

1. **Core Library Windows Support**
   - Fixed dependency issues that prevented compilation on non-Apple platforms
   - Added SystemPackage dependency for cross-platform file operations
   - Resolved System module import conflicts
   - Core SwiftTerm library now builds successfully on Linux (and should work on Windows)

2. **Windows-Specific Foundation Classes**
   - `WindowsTerminalView`: Core terminal view for Windows UI integration
   - `WindowsProcess`: Windows-specific process management (placeholder implementation)
   - `WindowsTerminalApplication`: Application framework for Windows terminal apps
   - `WindowsTerminalApp`: Example console application demonstrating usage

3. **Build Infrastructure**
   - Updated Package.swift with Windows-specific configuration
   - Conditional compilation for Windows-specific code
   - Windows-specific executable target (WindowsTerminalApp)

### 🚧 In Progress / Future Work

1. **Windows Process Management**
   - Current implementation is a placeholder
   - Needs integration with Windows CreateProcess API
   - Should support both traditional pipes and Windows ConPTY (Windows 10 1809+)
   - May benefit from winpty integration for older Windows versions

2. **UI Framework Integration**
   - Foundation classes are ready for integration with:
     - Win32 API (traditional Windows applications)
     - UWP (Universal Windows Platform)
     - WinUI 3 (modern Windows applications)
     - Potentially WPF if Swift supports it

3. **Windows-Specific Features**
   - Console API integration
   - Windows clipboard support
   - Windows-specific keyboard handling
   - Windows theming and appearance

## Architecture

### Core Components

```
SwiftTerm (Core Library)
├── Platform-agnostic terminal engine
├── Escape sequence processing
├── Buffer management
└── Character rendering logic

Windows Extensions
├── WindowsTerminalView (UI integration)
├── WindowsProcess (process management)
├── WindowsTerminalApplication (app framework)
└── WindowsTerminalApp (example application)
```

### Integration Points

1. **UI Frameworks**: The `WindowsTerminalView` provides a clean interface for various Windows UI frameworks to implement rendering and input handling.

2. **Process Management**: The `WindowsProcess` class handles launching and communicating with Windows processes (cmd.exe, PowerShell, etc.).

3. **Application Framework**: The `WindowsTerminalApplication` ties everything together and provides a complete terminal application foundation.

## Usage Example

```swift
#if os(Windows)
import SwiftTerm

// Create terminal configuration
var config = WindowsTerminalConfiguration()
config.terminalOptions.cols = 120
config.terminalOptions.rows = 30
config.defaultShell = "powershell.exe"

// Create and start application
let app = WindowsTerminalApplication(configuration: config)
app.start()

// Handle user input
app.handleKeyboardInput("ls\r\n")

// Get terminal content for rendering
let buffer = app.getTerminalContent()
#endif
```

## Next Steps for Full Windows Integration

### 1. Process Management Implementation

```swift
// Implement actual Windows process creation
func startProcess() {
    // Use CreateProcess, CreateProcessWithLogonW, or similar
    // Set up pipes or ConPTY for I/O
    // Handle process monitoring and termination
}
```

### 2. UI Framework Integration

Choose and implement one or more UI frameworks:

**Option A: Win32 API**
- Direct Windows API calls
- Maximum control and compatibility
- More complex implementation

**Option B: UWP/WinUI**
- Modern Windows development
- Easier deployment through Windows Store
- Limited to Windows 10+

**Option C: Cross-platform Framework**
- Could potentially use SwiftUI if/when available on Windows
- Or integrate with existing cross-platform solutions

### 3. Windows-Specific Features

- **Clipboard**: Integrate with Windows clipboard API
- **Fonts**: Support Windows font rendering
- **Themes**: Support Windows system themes
- **Input**: Handle Windows-specific keyboard and mouse input

### 4. Testing and Distribution

- Set up Windows CI/CD
- Create Windows installer/package
- Test on various Windows versions
- Performance optimization for Windows

## Files Added/Modified

### New Files
- `Sources/SwiftTerm/Windows/WindowsTerminalView.swift`
- `Sources/SwiftTerm/Windows/WindowsProcess.swift`
- `Sources/SwiftTerm/Windows/WindowsTerminalApplication.swift`
- `Sources/WindowsTerminalApp/main.swift`

### Modified Files
- `Package.swift`: Added Windows support and dependencies
- `Sources/SwiftTerm/LocalProcess.swift`: Fixed System module imports and subprocess compatibility

## Building

The Windows components are conditionally compiled and will only be included on Windows builds:

```bash
# On Windows (when Swift for Windows is available)
swift build

# This will create:
# - SwiftTerm library
# - WindowsTerminalApp executable
# - SwiftTermFuzz executable
```

## Dependencies

- **SystemPackage**: Cross-platform file system operations
- **Foundation**: Basic Swift functionality
- **Dispatch**: Concurrency and async operations

No Windows-specific external dependencies are currently required, though winpty or ConPTY integration may be added in the future.

## Contribution Guidelines

When contributing to the Windows port:

1. Use `#if os(Windows)` for Windows-specific code
2. Keep the core terminal engine platform-agnostic
3. Follow the existing code style and patterns
4. Add documentation for public APIs
5. Consider backward compatibility with older Windows versions
6. Test on multiple Windows versions when possible

## License

This Windows port maintains the same license as the parent SwiftTerm project.