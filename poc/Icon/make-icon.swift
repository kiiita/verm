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

// prompt chevron (dim) + "V_" (bright), monospaced
let promptFont = NSFont.monospacedSystemFont(ofSize: size * 0.30, weight: .heavy)
let mainFont = NSFont.monospacedSystemFont(ofSize: size * 0.42, weight: .heavy)

let prompt = NSAttributedString(string: "›", attributes: [.font: promptFont, .foregroundColor: greenDim])
let main = NSAttributedString(string: "V_", attributes: [.font: mainFont, .foregroundColor: green])

let pSize = prompt.size()
let mSize = main.size()
let gap = size * 0.03
let totalW = pSize.width + gap + mSize.width
let startX = (size - totalW) / 2
let midY = size * 0.5

prompt.draw(at: NSPoint(x: startX, y: midY - pSize.height / 2))
main.draw(at: NSPoint(x: startX + pSize.width + gap, y: midY - mSize.height / 2))

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
