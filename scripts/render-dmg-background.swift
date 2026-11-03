import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift render-dmg-background.swift <output.png>\n", stderr)
    exit(1)
}

let width = 720
let height = 420
let scale = 2
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width * scale,
    pixelsHigh: height * scale,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create DMG background.\n", stderr)
    exit(1)
}
bitmap.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

let background = NSGradient(
    starting: NSColor(calibratedWhite: 0.985, alpha: 1),
    ending: NSColor(calibratedWhite: 0.95, alpha: 1)
)!
background.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

func drawCentered(_ text: String, y: CGFloat, height: CGFloat, font: NSFont, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (text as NSString).draw(
        in: NSRect(x: 0, y: y, width: CGFloat(width), height: height),
        withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    )
}

drawCentered("Codex Account Manager", y: 305, height: 48,
             font: .systemFont(ofSize: 31, weight: .semibold), color: NSColor(calibratedWhite: 0.12, alpha: 1))
drawCentered("macOS", y: 276, height: 22,
             font: .systemFont(ofSize: 15, weight: .medium), color: NSColor(calibratedWhite: 0.47, alpha: 1))

let arrow = NSBezierPath()
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 340, y: 185))
arrow.line(to: NSPoint(x: 379, y: 185))
arrow.move(to: NSPoint(x: 370, y: 193))
arrow.line(to: NSPoint(x: 379, y: 185))
arrow.line(to: NSPoint(x: 370, y: 177))
NSColor(calibratedWhite: 0.2, alpha: 1).setStroke()
arrow.stroke()

let instructionColor = NSColor(calibratedWhite: 0.43, alpha: 1)
drawCentered("将 CAM 拖入“应用程序”", y: 137, height: 21,
             font: .systemFont(ofSize: 14), color: instructionColor)
drawCentered("以完成安装", y: 115, height: 21,
             font: .systemFont(ofSize: 14), color: instructionColor)

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode DMG background.\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
