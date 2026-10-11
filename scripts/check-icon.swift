#!/usr/bin/env swift
// Renders what AppKit hands back for a built bundle, so the app icon can be checked without
// screenshotting anyone's screen.
//
//   scripts/check-icon.swift <path/to/Marquee.app> <output-dir>

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: check-icon.swift <app> <outdir>\n".data(using: .utf8)!)
    exit(2)
}
let app = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

guard FileManager.default.fileExists(atPath: app.path) else {
    FileHandle.standardError.write("no bundle at \(app.path)\n".data(using: .utf8)!)
    exit(2)
}

func write(_ image: NSImage, _ name: String) {
    let pixels = Int(image.size.width * 2)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Checkerboard, so a transparent icon cannot masquerade as a white one.
    let square: CGFloat = 8
    for row in 0..<Int(rep.size.height / square) {
        for column in 0..<Int(rep.size.width / square) {
            ((row + column) % 2 == 0 ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.72, alpha: 1))
                .setFill()
            NSRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square).fill()
        }
    }
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!
    try! data.write(to: out.appending(path: name))
    print("wrote \(name) \(image.size)")
}

/// What Finder and the Dock would show, drawn under a forced appearance.
/// NSWorkspace caches the resolved icon, so each appearance gets a fresh copy.
func icon(_ appearance: NSAppearance.Name, _ name: String) {
    let image = NSWorkspace.shared.icon(forFile: app.path).copy() as! NSImage
    image.size = NSSize(width: 256, height: 256)
    let saved = NSAppearance.currentDrawing()
    NSAppearance.current = NSAppearance(named: appearance)!
    defer { NSAppearance.current = saved }
    write(image, name)
}

icon(.aqua, "bundle-icon-light.png")
icon(.darkAqua, "bundle-icon-dark.png")
print("OK")