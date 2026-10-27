import Cocoa

let iconsetPath = "/tmp/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetPath)
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]

for s in sizes {
    let size = NSSize(width: s, height: s)
    let img = NSImage(size: size)
    img.lockFocus()
    
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: CGFloat(s)*0.08, y: CGFloat(s)*0.08, width: CGFloat(s)*0.84, height: CGFloat(s)*0.84)
    let radius = CGFloat(s) * 0.185
    
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()
    let colors = [
        NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.95, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.06, green: 0.22, blue: 0.58, alpha: 1.0).cgColor
    ] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(s)), end: CGPoint(x: 0, y: 0), options: [])
    
    if let sym = NSImage(systemSymbolName: "externaldrive.fill.badge.checkmark", accessibilityDescription: nil) 
              ?? NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(s) * 0.44, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let configured = sym.withSymbolConfiguration(config) {
            let symSize = configured.size
            let drawRect = NSRect(
                x: (CGFloat(s) - symSize.width) / 2.0,
                y: (CGFloat(s) - symSize.height) / 2.0,
                width: symSize.width,
                height: symSize.height
            )
            configured.draw(in: drawRect)
        }
    }
    
    img.unlockFocus()
    
    if let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        if s <= 512 {
            try! png.write(to: URL(fileURLWithPath: "\(iconsetPath)/icon_\(s)x\(s).png"))
        }
        if s >= 32 {
            let half = s / 2
            try! png.write(to: URL(fileURLWithPath: "\(iconsetPath)/icon_\(half)x\(half)@2x.png"))
        }
    }
}
