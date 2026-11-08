import AppKit

// Renders the 1024pt app icon in the classic Things style: a white rounded
// square with a bold blue check mark. Run with: swift tools/makeicon.swift <output.png>
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size = NSSize(width: 1024, height: 1024)

let image = NSImage(size: size)
image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

// macOS icon grid: the squircle occupies ~82% of the canvas.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
let radius: CGFloat = rect.width * 0.2237

// Shadow
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -14)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
NSGraphicsContext.restoreGraphicsState()

// Body: very soft top-to-bottom gradient so the white reads as a surface.
let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
    NSColor(srgbRed: 0.955, green: 0.960, blue: 0.972, alpha: 1)
])!
gradient.draw(in: body, angle: -90)

// Hairline edge
NSColor(srgbRed: 0.80, green: 0.82, blue: 0.86, alpha: 0.9).setStroke()
let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: radius - 1.5, yRadius: radius - 1.5)
edge.lineWidth = 3
edge.stroke()

// The check mark. Things blue.
let blue = NSColor(srgbRed: 0.153, green: 0.502, blue: 0.945, alpha: 1)   // #2780F1
let check = NSBezierPath()
check.move(to: NSPoint(x: 318, y: 520))
check.line(to: NSPoint(x: 454, y: 384))
check.line(to: NSPoint(x: 716, y: 646))
check.lineWidth = 118
check.lineCapStyle = .round
check.lineJoinStyle = .round

// Subtle inner shadow under the check so it sits in the surface.
NSGraphicsContext.saveGraphicsState()
let checkShadow = NSShadow()
checkShadow.shadowColor = blue.withAlphaComponent(0.25)
checkShadow.shadowBlurRadius = 18
checkShadow.shadowOffset = NSSize(width: 0, height: -8)
checkShadow.set()
blue.setStroke()
check.stroke()
NSGraphicsContext.restoreGraphicsState()

// Light gradient across the check for depth.
let checkGradient = NSGradient(colors: [
    NSColor(srgbRed: 0.33, green: 0.63, blue: 0.98, alpha: 1),
    blue
])!
let strokeCopy = check.copy() as! NSBezierPath
let outline = strokeCopy.cgPath.copy(strokingWithWidth: 118, lineCap: .round, lineJoin: .round, miterLimit: 10)
let outlinePath = NSBezierPath(cgPath: outline)
checkGradient.draw(in: outlinePath, angle: -90)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not render the icon")
}
try! png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
