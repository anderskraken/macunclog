import CoreGraphics
import Foundation

// Prints "<id> <width>x<height> layer=<n> <title>" for every on-screen window owned by an
// app, given by name ("MacUnclog") or by process ID ("4242").
let target = CommandLine.arguments.dropFirst().first ?? "MacUnclog"
let pid = Int32(target)
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    if let pid {
        guard window[kCGWindowOwnerPID as String] as? Int32 == pid else { continue }
    } else {
        guard window[kCGWindowOwnerName as String] as? String == target else { continue }
    }
    let id = window[kCGWindowNumber as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let title = window[kCGWindowName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    print("\(id) \(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0)) layer=\(layer) \(title)")
}
