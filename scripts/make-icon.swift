#!/usr/bin/swift
// Generates Resources/AppIcon.icns for MacClean.
//
// Design (drawn here, no third-party artwork): a Big Sur style squircle with a
// subtle top-to-bottom gradient and a white glyph — a disk platter with a
// sparkle — for "disk cleaning".
//
// Usage: swift scripts/make-icon.swift
// Re-runnable: regenerates the .iconset, AppIcon.icns and a 512px preview.

import AppKit
import CoreGraphics
import Foundation

// MARK: - paths

/// Big Sur style squircle: superellipse |x|^n + |y|^n = 1 sampled into a path.
/// n ~= 4.6 closely matches macOS's continuous corner shape.
func squircle(in rect: CGRect, n: CGFloat = 4.6) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...240 {
        let t = CGFloat(i) / 240 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = rect.midY + b * pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Four-point sparkle: tips at the cardinal directions, concave sides drawn as
/// quadratic curves through inner control points.
func sparkle(center c: CGPoint, radius r: CGFloat, inner: CGFloat = 0.22) -> CGPath {
    let k = r * inner
    let tips = [CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x + r, y: c.y),
                CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - r, y: c.y)]
    let ctrls = [CGPoint(x: c.x + k, y: c.y + k), CGPoint(x: c.x + k, y: c.y - k),
                 CGPoint(x: c.x - k, y: c.y - k), CGPoint(x: c.x - k, y: c.y + k)]
    let path = CGMutablePath()
    path.move(to: tips[0])
    for i in 0..<4 { path.addQuadCurve(to: tips[(i + 1) % 4], control: ctrls[i]) }
    path.closeSubpath()
    return path
}

// MARK: - drawing

func draw(_ ctx: CGContext, size s: CGFloat) {
    // transparent canvas margin: the shape spans ~80% like stock macOS icons
    let shape = squircle(in: CGRect(x: s * 0.10, y: s * 0.10,
                                    width: s * 0.80, height: s * 0.80))

    // soft baked shadow under the shape
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.030,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // base gradient: bright teal-blue top to deep blue bottom
    let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor(calibratedRed: 0.30, green: 0.74, blue: 0.98, alpha: 1).cgColor,
                 NSColor(calibratedRed: 0.16, green: 0.41, blue: 0.90, alpha: 1).cgColor] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(base,
                           start: CGPoint(x: s * 0.5, y: s * 0.90),
                           end: CGPoint(x: s * 0.5, y: s * 0.10),
                           options: [])

    // subtle top glow
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.withAlphaComponent(0.20).cgColor,
                 NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: s * 0.5, y: s * 0.82), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.5, y: s * 0.82), endRadius: s * 0.55,
                           options: [])

    // glyph: disk platter (ring + hub), white with a hair of transparency
    let white = NSColor.white.withAlphaComponent(0.96).cgColor
    ctx.setFillColor(white)
    ctx.setStrokeColor(white)
    ctx.setLineCap(.round)
    let diskC = CGPoint(x: s * 0.455, y: s * 0.43)
    ctx.setLineWidth(s * 0.075)
    ctx.strokeEllipse(in: CGRect(x: diskC.x - s * 0.185, y: diskC.y - s * 0.185,
                                 width: s * 0.37, height: s * 0.37))
    ctx.fillEllipse(in: CGRect(x: diskC.x - s * 0.075, y: diskC.y - s * 0.075,
                               width: s * 0.15, height: s * 0.15))

    // sparkles: big one overlapping the disk's top-right, small one up-left
    ctx.addPath(sparkle(center: CGPoint(x: s * 0.685, y: s * 0.68), radius: s * 0.115))
    ctx.fillPath()
    if s >= 48 {
        ctx.addPath(sparkle(center: CGPoint(x: s * 0.315, y: s * 0.735), radius: s * 0.055))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // crisp inner edge
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()
}

func render(size s: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    draw(ctx, size: CGFloat(s))
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - main

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in variants {
    try render(size: px, to: iconset.appendingPathComponent(name))
}

// 512px preview next to the iconset
try render(size: 512, to: root.appendingPathComponent("Resources/AppIcon-preview.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed: \(p.terminationStatus)") }
try? FileManager.default.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
