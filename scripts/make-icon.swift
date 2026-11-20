import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dist", isDirectory: true)
let folder = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
        NSColor(srgbRed: 0.17, green: 0.36, blue: 0.29, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 205, yRadius: 205).fill()
        NSColor(srgbRed: 0.90, green: 0.95, blue: 0.85, alpha: 1).setStroke()
        let book = NSBezierPath(); book.lineWidth = 40; book.lineCapStyle = .round; book.lineJoinStyle = .round
        book.move(to: NSPoint(x: 315, y: 710)); book.line(to: NSPoint(x: 315, y: 320)); book.curve(to: NSPoint(x: 370, y: 270), controlPoint1: NSPoint(x: 315, y: 285), controlPoint2: NSPoint(x: 338, y: 270))
        book.line(to: NSPoint(x: 725, y: 270)); book.line(to: NSPoint(x: 725, y: 710)); book.close(); book.stroke()
        let spine = NSBezierPath(); spine.lineWidth = 25; spine.move(to: NSPoint(x: 385, y: 710)); spine.line(to: NSPoint(x: 385, y: 270)); spine.stroke()
        let bars = NSBezierPath(); bars.lineWidth = 32; bars.lineCapStyle = .round
        bars.move(to: NSPoint(x: 463, y: 430)); bars.line(to: NSPoint(x: 463, y: 510))
        bars.move(to: NSPoint(x: 548, y: 430)); bars.line(to: NSPoint(x: 548, y: 570))
        bars.move(to: NSPoint(x: 633, y: 430)); bars.line(to: NSPoint(x: 633, y: 625)); bars.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 1 ? "" : "@2x"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); task.arguments = ["-c", "icns", folder.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit(); if task.terminationStatus != 0 { exit(task.terminationStatus) }
