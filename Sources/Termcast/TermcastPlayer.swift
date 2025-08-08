import Foundation

class TermcastPlayer {
    private let decoder = JSONDecoder()
    
    func playback(from filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        guard !lines.isEmpty else {
            throw TermcastError.invalidFile("Empty cast file")
        }
        
        // Parse header
        let headerData = lines[0].data(using: .utf8)!
        let header = try decoder.decode(AsciicastHeader.self, from: headerData)
        
        // Set terminal size if possible
        setTerminalSize(width: header.width, height: header.height)
        
        // Parse and replay events
        var lastTime: TimeInterval = 0
        
        for line in lines.dropFirst() {
            let eventData = line.data(using: .utf8)!
            let event = try decoder.decode(AsciicastEvent.self, from: eventData)
            
            // Calculate delay since last event
            let delay = event.time - lastTime
            if delay > 0 {
                usleep(UInt32(delay * 1_000_000)) // Convert to microseconds
            }
            
            // Handle different event types
            switch event.eventType {
            case .output:
                print(event.eventData, terminator: "")
                fflush(stdout)
            case .resize:
                handleResize(event.eventData)
            case .input, .marker:
                // For playback, we typically don't replay input or markers
                // But we could add options to show them if needed
                break
            }
            
            lastTime = event.time
        }
        
        print() // Final newline
    }
    
    private func setTerminalSize(width: Int, height: Int) {
        // Try to set the terminal size using ANSI escape codes
        // This may not work in all terminals, but it's worth trying
        print("\u{001B}[8;\(height);\(width)t", terminator: "")
        fflush(stdout)
    }
    
    private func handleResize(_ data: String) {
        // Parse resize data in format "WIDTHxHEIGHT"
        let components = data.components(separatedBy: "x")
        guard components.count == 2,
              let width = Int(components[0]),
              let height = Int(components[1]) else {
            return
        }
        
        setTerminalSize(width: width, height: height)
    }
}

enum TermcastError: Error, LocalizedError {
    case invalidFile(String)
    case fileNotFound(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidFile(let message):
            return "Invalid cast file: \(message)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        }
    }
}