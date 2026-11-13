// Renders menu bar template SVGs the way AppKit draws them (CoreSVG via NSImage),
// tinted black on a light bar and white on a dark bar, next to SF Symbols.
//
// swift render.swift <out-dir> <name>=<file.svg> [<name>=<file.svg> ...]
//
// Writes, per SVG: <name>-288.png (light | dark), and for the set:
// sizes.png (16/18/22 px at 1x and 2x) and menubar.png (status bar mock at 1x and 2x).
import AppKit

let lightBar = NSColor(white: 0.93, alpha: 1)
let darkBar = NSColor(white: 0.23, alpha: 1)

func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    draw(ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Template tinting: keep the image's alpha, replace its colour.
func tinted(_ image: NSImage, _ color: NSColor, _ pxW: Int, _ pxH: Int) -> NSImage {
    let rep = bitmap(pxW, pxH) { _ in
        image.draw(in: NSRect(x: 0, y: 0, width: pxW, height: pxH))
        color.set()
        NSRect(x: 0, y: 0, width: pxW, height: pxH).fill(using: .sourceAtop)
    }
    let out = NSImage(size: NSSize(width: pxW, height: pxH))
    out.addRepresentation(rep)
    return out
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote", path)
}

func symbol(_ name: String, pointSize: CGFloat, scale: CGFloat) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize * scale, weight: .regular)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
}

let args = CommandLine.arguments
let outDir = args[1]
let items: [(String, NSImage)] = args.dropFirst(2).map { arg in
    let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
    return (parts[0], NSImage(contentsOf: URL(fileURLWithPath: parts[1]))!)
}

// 1. Large previews, 288 px, light and dark side by side, with an 18-unit grid.
for (name, img) in items {
    let s = 288, pad = 24
    let rep = bitmap(2 * s + 3 * pad, s + 2 * pad) { cg in
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 2 * s + 3 * pad, height: s + 2 * pad).fill()
        for (i, (bg, fg)) in [(lightBar, NSColor.black), (darkBar, NSColor.white)].enumerated() {
            let x = pad + i * (s + pad)
            bg.setFill(); NSRect(x: x, y: pad, width: s, height: s).fill()
            (i == 0 ? NSColor(white: 0, alpha: 0.08) : NSColor(white: 1, alpha: 0.08)).setStroke()
            for k in 0...18 {
                let p = CGFloat(k) * CGFloat(s) / 18
                let v = NSBezierPath(); v.move(to: NSPoint(x: CGFloat(x) + p, y: CGFloat(pad))); v.line(to: NSPoint(x: CGFloat(x) + p, y: CGFloat(pad + s))); v.lineWidth = 1; v.stroke()
                let h = NSBezierPath(); h.move(to: NSPoint(x: CGFloat(x), y: CGFloat(pad) + p)); h.line(to: NSPoint(x: CGFloat(x + s), y: CGFloat(pad) + p)); h.lineWidth = 1; h.stroke()
            }
            tinted(img, fg, s, s).draw(in: NSRect(x: x, y: pad, width: s, height: s))
        }
    }
    save(rep, "\(outDir)/\(name)-288.png")
}

// 2. Size ladder: 16, 18, 22 px at 1x and 2x, pixel-exact, then magnified 4x (nearest neighbour)
//    so single pixels stay visible. One row per SVG per appearance.
do {
    let sizes = [16, 18, 22]
    let cell = 44 // 2x of 22 px
    let gap = 8
    let rowsPerItem = 2
    let w = gap + sizes.count * 2 * (cell + gap)
    let h = gap + items.count * rowsPerItem * (cell + gap)
    let small = bitmap(w, h) { _ in
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        for (ii, (_, img)) in items.enumerated() {
            for (ai, (bg, fg)) in [(lightBar, NSColor.black), (darkBar, NSColor.white)].enumerated() {
                let row = ii * rowsPerItem + ai
                let y = h - (gap + row * (cell + gap)) - cell
                bg.setFill(); NSRect(x: 0, y: y - gap / 2, width: w, height: cell + gap).fill()
                var x = gap
                for sz in sizes {
                    for scale in [1, 2] {
                        let px = sz * scale
                        let t = tinted(img, fg, px, px)
                        t.draw(in: NSRect(x: x + (cell - px) / 2, y: y + (cell - px) / 2, width: px, height: px))
                        x += cell + gap
                    }
                }
            }
        }
    }
    let mag = 4
    let big = bitmap(w * mag, h * mag) { cg in
        cg.interpolationQuality = .none
        cg.draw(small.cgImage!, in: CGRect(x: 0, y: 0, width: w * mag, height: h * mag))
    }
    save(big, "\(outDir)/sizes.png")
}

// 3. Menu bar mock: 24 pt bar, status items spaced like macOS, at 1x and 2x, light and dark,
//    one bar per SVG, magnified 3x (1x bar) / 1.5x (2x bar) for viewing.
do {
    let barH = 24
    let symbols: [(String, CGFloat)] = [("magnifyingglass", 13), ("wifi", 13), ("battery.75percent", 13), ("switch.2", 13)]
    func bar(_ img: NSImage, _ scale: Int, _ bg: NSColor, _ fg: NSColor) -> NSBitmapImageRep {
        let w = 270 * scale, h = barH * scale
        return bitmap(w, h) { _ in
            bg.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
            var x = CGFloat(10 * scale)
            let spacing = CGFloat(16 * scale)
            func place(_ im: NSImage, _ pxW: CGFloat, _ pxH: CGFloat) {
                let t = tinted(im, fg, Int(pxW.rounded()), Int(pxH.rounded()))
                let y = ((CGFloat(h) - pxH) / 2).rounded()
                t.draw(in: NSRect(x: x.rounded(), y: y, width: pxW.rounded(), height: pxH.rounded()))
                x += pxW + spacing
            }
            place(img, CGFloat(18 * scale), CGFloat(18 * scale))
            for (name, pt) in symbols {
                let s = symbol(name, pointSize: pt, scale: CGFloat(scale))
                place(s, s.size.width, s.size.height)
            }
            let clock = NSAttributedString(string: "Fri 13 Nov  09:41", attributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(13 * scale)), .foregroundColor: fg])
            let cs = clock.size()
            clock.draw(at: NSPoint(x: x, y: (CGFloat(h) - cs.height) / 2))
        }
    }
    var reps: [NSBitmapImageRep] = []
    for (_, img) in items {
        for (bg, fg) in [(lightBar, NSColor.black), (darkBar, NSColor.white)] {
            for scale in [1, 2] { reps.append(bar(img, scale, bg, fg)) }
        }
    }
    let viewW = 270 * 3
    let viewH = barH * 3
    let gap = 10
    let total = bitmap(viewW, reps.count * (viewH + gap)) { cg in
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: viewW, height: reps.count * (viewH + gap)).fill()
        cg.interpolationQuality = .none
        for (i, r) in reps.enumerated() {
            let y = (reps.count - 1 - i) * (viewH + gap)
            cg.draw(r.cgImage!, in: CGRect(x: 0, y: y, width: viewW, height: viewH))
        }
    }
    save(total, "\(outDir)/menubar.png")
}
