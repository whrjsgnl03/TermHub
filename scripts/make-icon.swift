import AppKit
// 1024px 앱 아이콘: 어두운 둥근 사각형 안에 나뉜 터미널 두 칸
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset*2, height: size - inset*2)
let bg = NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180)
NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.21, blue: 0.24, alpha: 1),
           ending: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1))!.draw(in: bg, angle: -90)
let pad: CGFloat = 70, gap: CGFloat = 36
let inner = rect.insetBy(dx: pad, dy: pad)
let w = (inner.width - gap) / 2
for (i, color) in [NSColor.systemOrange, NSColor.systemBlue].enumerated() {
    let r = NSRect(x: inner.minX + CGFloat(i) * (w + gap), y: inner.minY, width: w, height: inner.height)
    NSColor(white: 0.05, alpha: 1).setFill()
    NSBezierPath(roundedRect: r, xRadius: 40, yRadius: 40).fill()
    let bar = NSRect(x: r.minX, y: r.maxY - 70, width: r.width, height: 70)
    color.setFill()
    let barPath = NSBezierPath(roundedRect: bar, xRadius: 40, yRadius: 40)
    barPath.append(NSBezierPath(rect: NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: 35)))
    barPath.fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 120, weight: .bold),
        .foregroundColor: color,
    ]
    (">_" as NSString).draw(at: NSPoint(x: r.minX + 40, y: r.maxY - 260), withAttributes: attrs)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
