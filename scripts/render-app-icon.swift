#!/usr/bin/env swift

import AppKit

enum IconRendererError: Error {
    case invalidArguments
    case unableToLoadSourceImage
    case unableToCreateBitmap
    case unableToEncodePNG
}

let arguments = CommandLine.arguments

guard arguments.count == 3 else {
    throw IconRendererError.invalidArguments
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    throw IconRendererError.unableToLoadSourceImage
}

let canvasSize = NSSize(width: 1024, height: 1024)
let canvasRect = NSRect(origin: .zero, size: canvasSize)
let tileInset: CGFloat = 56
let tileRect = canvasRect.insetBy(dx: tileInset, dy: tileInset)
let cornerRadius: CGFloat = 205

let outputImage = NSImage(size: canvasSize)
outputImage.lockFocus()

NSColor.clear.setFill()
canvasRect.fill()

if let context = NSGraphicsContext.current?.cgContext {
    context.setShadow(
        offset: CGSize(width: 0, height: -18),
        blur: 42,
        color: NSColor(calibratedWhite: 0, alpha: 0.14).cgColor
    )
}

let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)
tilePath.addClip()

sourceImage.draw(
    in: tileRect,
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)

NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0)

NSColor(calibratedWhite: 0.88, alpha: 1).setStroke()
tilePath.lineWidth = 2
tilePath.stroke()

outputImage.unlockFocus()

guard let representation = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    throw IconRendererError.unableToCreateBitmap
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
outputImage.draw(in: canvasRect)
NSGraphicsContext.restoreGraphicsState()

guard let pngData = representation.representation(using: .png, properties: [:]) else {
    throw IconRendererError.unableToEncodePNG
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try pngData.write(to: outputURL)
