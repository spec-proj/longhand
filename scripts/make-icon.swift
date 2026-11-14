// Superseded by src/Longhand/AppIcon.icon (Icon Composer file, 2026-11-13).
import AppKit

// Renders the Longhand app icon at 1024pt. Run: swift scripts/make-icon.swift path.png

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let inset: CGFloat = 62
let cover = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: cover, xRadius: 172, yRadius: 172)

NSColor(srgbRed: 0.976, green: 0.961, blue: 0.925, alpha: 1).setFill()
shape.fill()

NSColor(srgbRed: 0.10, green: 0.10, blue: 0.09, alpha: 0.14).setStroke()
shape.lineWidth = 4
shape.stroke()

let font = NSFont(name: "NewYork-Regular", size: 566)
    ?? NSFont.systemFont(ofSize: 566, weight: .regular)
let ink = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.11, alpha: 1)
let letter = NSAttributedString(string: "L", attributes: [.font: font, .foregroundColor: ink])
let letterSize = letter.size()
letter.draw(at: NSPoint(
    x: (size - letterSize.width) / 2,
    y: (size - letterSize.height) / 2 + 34
))

// A quiet rule beneath the letter, like a colophon.
let rule = NSBezierPath()
rule.move(to: NSPoint(x: size / 2 - 118, y: 306))
rule.line(to: NSPoint(x: size / 2 + 118, y: 306))
rule.lineWidth = 7
rule.lineCapStyle = .round
NSColor(srgbRed: 0.12, green: 0.12, blue: 0.11, alpha: 0.55).setStroke()
rule.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Could not render icon\n", stderr)
    exit(1)
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
