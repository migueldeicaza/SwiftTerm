/// Native mouse pointer shapes understood by OSC 22.
///
/// `hidden` is the CSS `none` extension. Applications must query support before
/// using it: hosts without a native pointer implementation advertise no shapes.
public enum MousePointerShape: String, CaseIterable, Sendable {
    case defaultShape = "default"
    case text
    case pointer
    case crosshair
    case hidden = "none"
}

extension Terminal {
    /// The application's pointer shape for the active screen, or nil when the
    /// host should use its usual pointer. Read while holding `terminalLock`.
    public var mousePointerShape: MousePointerShape? {
        buffer.mousePointerShapes.last
    }

    func oscMousePointerShape(_ data: ArraySlice<UInt8>) {
        guard let text = terminalStringUTF8(data) else { return }
        let first = text.first
        let hasOperation = first == "?" || first == ">" || first == "<" || first == "="
        let payload = hasOperation ? String(text.dropFirst()) : text
        let names = payload.split(separator: ",", omittingEmptySubsequences: false)
        let supported = tdel?.supportedMousePointerShapes(source: self) ?? []

        if first == "?" {
            let replies = names.map { name -> String in
                switch name {
                case "__current__": return mousePointerShape?.rawValue ?? "0"
                case "__default__": return supported.contains(.text) ? "text" : "0"
                case "__grabbed__": return supported.contains(.defaultShape) ? "default" : "0"
                default:
                    guard let shape = MousePointerShape(rawValue: String(name)) else { return "0" }
                    return supported.contains(shape) ? "1" : "0"
                }
            }
            sendResponse(cc.OSC, "22;" + replies.joined(separator: ","), cc.ST)
            return
        }

        let previous = mousePointerShape
        if first == "<" {
            _ = buffer.mousePointerShapes.popLast()
        } else if payload.isEmpty && first != ">" {
            buffer.mousePointerShapes.removeAll()
        } else if first == ">" {
            for name in names {
                guard let shape = MousePointerShape(rawValue: String(name)), supported.contains(shape) else { continue }
                if buffer.mousePointerShapes.count == 16 { buffer.mousePointerShapes.removeFirst() }
                buffer.mousePointerShapes.append(shape)
            }
        } else if names.count == 1, let shape = MousePointerShape(rawValue: payload), supported.contains(shape) {
            if buffer.mousePointerShapes.isEmpty {
                buffer.mousePointerShapes.append(shape)
            } else {
                buffer.mousePointerShapes[buffer.mousePointerShapes.count - 1] = shape
            }
        }
        if mousePointerShape != previous {
            tdel?.mousePointerShapeChanged(source: self)
        }
    }
}
