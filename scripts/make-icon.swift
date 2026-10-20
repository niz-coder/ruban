// Draws Ruban's app icon: a strip of windows running past the edges of a rounded square.
// usage: swift make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle body with a deep blue-to-violet gradient.
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
NSShadow().with { $0.shadowColor = NSColor.black.withAlphaComponent(0.35); $0.shadowBlurRadius = 28; $0.shadowOffset = NSSize(width: 0, height: -12) }.set()
NSColor.black.setFill()
bodyPath.fill()
ctx.restoreGState()
bodyPath.addClip()
NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.32, alpha: 1), NSColor(srgbRed: 0.33, green: 0.20, blue: 0.62, alpha: 1)])!
    .draw(in: body, angle: 70)

// Three columns: the focused one in the middle, the neighbours cut off by the edges.
let colH: CGFloat = 520, y = (size - colH) / 2 - 10, gap: CGFloat = 34
let centreW: CGFloat = 330, sideW: CGFloat = 300
let columns: [(CGFloat, CGFloat, CGFloat)] = [
    (size / 2 - centreW / 2 - gap - sideW, sideW, 0.32),
    (size / 2 - centreW / 2, centreW, 1.0),
    (size / 2 + centreW / 2 + gap, sideW, 0.32),
]
for (x, w, alpha) in columns {
    let r = CGRect(x: x, y: y, width: w, height: colH)
    let p = NSBezierPath(roundedRect: r, xRadius: 40, yRadius: 40)
    NSColor.white.withAlphaComponent(alpha * 0.92).setFill()
    p.fill()
    // Title bar.
    let bar = NSBezierPath(roundedRect: CGRect(x: r.minX + 26, y: r.maxY - 64, width: r.width - 52, height: 22), xRadius: 11, yRadius: 11)
    NSColor(srgbRed: 0.33, green: 0.20, blue: 0.62, alpha: alpha * 0.55).setFill()
    bar.fill()
}
// Scroll arrows under the strip.
NSColor.white.withAlphaComponent(0.85).setFill()
for dir: CGFloat in [-1, 1] {
    let cx = size / 2 + dir * 70, cy = y - 62
    let tri = NSBezierPath()
    tri.move(to: CGPoint(x: cx + dir * 22, y: cy))
    tri.line(to: CGPoint(x: cx - dir * 14, y: cy + 22))
    tri.line(to: CGPoint(x: cx - dir * 14, y: cy - 22))
    tri.close()
    tri.fill()
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

extension NSShadow {
    func with(_ f: (NSShadow) -> Void) -> NSShadow { f(self); return self }
}
