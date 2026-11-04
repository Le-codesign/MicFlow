// Renders Design/AppIcon.svg to the 1024×1024 app icon PNG. macOS draws SVG itself (macOS 14 or
// later on the Mac that builds; the finished app still runs on macOS 13).
// Usage: swift make-icon.swift <icon.svg> <output.png>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let svg = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write("Usage: swift make-icon.swift <icon.svg> <output.png>\n".data(using: .utf8)!)
    exit(1)
}

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
svg.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
