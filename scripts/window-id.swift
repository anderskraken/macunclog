import CoreGraphics
import Foundation

// Prints "<id> <width>x<height> <title>" for every on-screen window owned by the named app.
let owner = CommandLine.arguments.dropFirst().first ?? "MacUnclog"
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where window[kCGWindowOwnerName as String] as? String == owner {
    let id = window[kCGWindowNumber as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let title = window[kCGWindowName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    print("\(id) \(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0)) layer=\(layer) \(title)")
}
