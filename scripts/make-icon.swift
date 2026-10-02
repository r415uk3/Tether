#!/usr/bin/env swift
// Usage: swift scripts/make-icon.swift <outdir>
// Draws the Tether app icon and writes every macOS AppIcon slot plus Contents.json.
import AppKit

let master = 1024
let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <outdir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func symbol(_ names: [String], pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
    for name in names {
        if let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
           let img = base.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) {
            return tinted(img, .white)
        }
    }
    fatalError("no symbol available among \(names)")
}

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    return out
}

func drawMaster() -> CGImage {
    let size = CGFloat(master)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: master, pixelsHigh: master,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let inset: CGFloat = 100
    let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = body.width * 0.224
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Soft drop shadow under the body.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(srgbRed: 0x1E / 255, green: 0x4F / 255, blue: 0xD8 / 255, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Vertical gradient #3D7BFD (top) to #1E4FD8 (bottom).
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0x3D / 255, green: 0x7B / 255, blue: 0xFD / 255, alpha: 1),
        ending: NSColor(srgbRed: 0x1E / 255, green: 0x4F / 255, blue: 0xD8 / 255, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    // Phone on top, transfer arrows beneath it.
    let phone = symbol(["smartphone", "iphone.gen3"], pointSize: 400, weight: .regular)
    let arrows = symbol(["arrow.left.arrow.right"], pointSize: 150, weight: .bold)
    let gap: CGFloat = 40
    let total = phone.size.height + gap + arrows.size.height
    let top = body.midY + total / 2
    let phoneRect = NSRect(x: body.midX - phone.size.width / 2, y: top - phone.size.height,
                           width: phone.size.width, height: phone.size.height)
    let arrowRect = NSRect(x: body.midX - arrows.size.width / 2, y: phoneRect.minY - gap - arrows.size.height,
                           width: arrows.size.width, height: arrows.size.height)

    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    glyphShadow.shadowBlurRadius = 16
    glyphShadow.shadowOffset = NSSize(width: 0, height: -6)
    glyphShadow.set()
    phone.draw(in: phoneRect)
    arrows.draw(in: arrowRect)
    NSGraphicsContext.restoreGraphicsState()

    return rep.cgImage!
}

func write(_ image: CGImage, pixels: Int, to name: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}

let image = drawMaster()
var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try write(image, pixels: points * scale, to: name)
        entries.append(#"    {"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(points)x\#(points)"}"#)
    }
}

let json = "{\n  \"images\":[\n" + entries.joined(separator: ",\n") + "\n  ],\n  \"info\":{\"author\":\"xcode\",\"version\":1}\n}\n"
try json.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
