// Une pochette dégradée avec un titre : swift art.swift <sortie.jpg> <hex1> <hex2> <texte> <taille>
import AppKit
let a = CommandLine.arguments
func color(_ hex: String) -> NSColor {
    let v = Int(hex, radix: 16)!
    return NSColor(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}
let size = 1000
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(starting: color(a[2]), ending: color(a[3]))!.draw(in: rect, angle: -45)
let text = NSAttributedString(string: a[4], attributes: [.font: NSFont.systemFont(ofSize: CGFloat(Double(a[5])!), weight: .heavy),
                                                         .foregroundColor: NSColor.white])
let bounds = text.size()
text.draw(at: NSPoint(x: (CGFloat(size) - bounds.width) / 2, y: (CGFloat(size) - bounds.height) / 2))
NSGraphicsContext.current = nil
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to: URL(fileURLWithPath: a[1]))
