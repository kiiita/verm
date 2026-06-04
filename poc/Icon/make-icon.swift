import AppKit
import Foundation

// Renders the verm app icon: a dark terminal squircle with a green "V_" prompt.
// Usage: swift make-icon.swift <out.png> [size]

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 1024.0

func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let green = srgb(0.224, 0.827, 0.325)        // #39d353
let greenDim = srgb(0.149, 0.651, 0.255)     // #26a641

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let radius = size * 0.225
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
squircle.addClip()

// background gradient
NSGradient(colors: [srgb(0.043, 0.055, 0.078), srgb(0.090, 0.110, 0.137)])!
    .draw(in: rect, angle: -90)

// faint green glow band near the bottom (terminal phosphor feel)
NSGradient(colors: [green.withAlphaComponent(0.0), green.withAlphaComponent(0.10)])!
    .draw(in: rect, angle: 90)

// subtle inner border
let inset = size * 0.045
let border = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                          xRadius: radius * 0.86, yRadius: radius * 0.86)
green.withAlphaComponent(0.45).setStroke()
border.lineWidth = size * 0.012
border.stroke()

// A downward chevron (∨) — a "V"-shaped arrow — plus an underscore cursor.
_ = greenDim
green.setStroke()
green.setFill()

let strokeW = size * 0.090
let chW = size * 0.30        // chevron width
let chH = size * 0.25        // chevron height
let uW  = size * 0.17        // underscore width
let uH  = size * 0.075       // underscore thickness
let gap = size * 0.055
let totalW = chW + gap + uW
let startX = (size - totalW) / 2
let cy = size * 0.52
let topY = cy + chH / 2
let botY = cy - chH / 2

let chev = NSBezierPath()
chev.move(to: NSPoint(x: startX, y: topY))
chev.line(to: NSPoint(x: startX + chW / 2, y: botY))
chev.line(to: NSPoint(x: startX + chW, y: topY))
chev.lineWidth = strokeW
chev.lineCapStyle = .round
chev.lineJoinStyle = .round
chev.stroke()

// underscore, baseline-aligned with the chevron's apex
let uRect = NSRect(x: startX + chW + gap, y: botY, width: uW, height: uH)
NSBezierPath(roundedRect: uRect, xRadius: uH / 2, yRadius: uH / 2).fill()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
