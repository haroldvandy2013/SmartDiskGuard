import Cocoa

let iconsetPath = "/tmp/AppIcon.iconset"
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon.icns"
try? FileManager.default.removeItem(atPath: iconsetPath)
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let icons: [(fileName: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for icon in icons {
    let s = CGFloat(icon.pixels)
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
        try! png.write(to: URL(fileURLWithPath: iconsetPath).appendingPathComponent(icon.fileName))
    }
}

let chunks: [(type: String, fileName: String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]

var payload = Data()
for chunk in chunks {
    let url = URL(fileURLWithPath: iconsetPath).appendingPathComponent(chunk.fileName)
    let png = try! Data(contentsOf: url)
    payload.append(Data(chunk.type.utf8))
    var chunkLength = UInt32(png.count + 8).bigEndian
    withUnsafeBytes(of: &chunkLength) { payload.append(contentsOf: $0) }
    payload.append(png)
}

var icns = Data("icns".utf8)
var fileLength = UInt32(payload.count + 8).bigEndian
withUnsafeBytes(of: &fileLength) { icns.append(contentsOf: $0) }
icns.append(payload)
try! icns.write(to: URL(fileURLWithPath: outputPath))
try? FileManager.default.removeItem(atPath: iconsetPath)
