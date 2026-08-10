#!/usr/bin/env swift
// Draws the app icon and writes every size the asset catalog asks for.
//
// The icon is in the repository as generated PNGs, because that is what
// Xcode's asset catalog compiler consumes — but the *source* is this file, so
// a change means editing code and re-running rather than nudging pixels in a
// binary nobody can diff. Run it with:
//
//     xcrun swift Scripts/make-app-icon.swift
//
// Everything is drawn with Core Graphics paths. Deliberately no SF Symbol:
// Apple's licence for those forbids using them in app icons, and a shipped,
// signed, notarised app is exactly the case that covers.
//
// This is placeholder art with the right shape, not a designed identity — a
// dark rounded square with a padlock, which reads at 16pt and says "secrets"
// without pretending to be a brand. Replacing it means editing the drawing
// below and re-running; nothing else in the build refers to the PNGs by name.

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root
    .appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

/// macOS icons do not fill their canvas: the artwork sits in a rounded square
/// inset from the edge, and the system's own grid puts that square at 824/1024
/// with a corner radius of 185/1024. Matching it is why the icon looks the same
/// size as its neighbours in the Dock instead of slightly too big.
let canvas: CGFloat = 1024
let plateInset: CGFloat = 100
let plateRadius: CGFloat = 185

func drawIcon(into context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let plate = CGRect(x: plateInset, y: plateInset,
                       width: canvas - plateInset * 2, height: canvas - plateInset * 2)
    let platePath = CGPath(roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius,
                           transform: nil)

    // Background: a top-lit slate gradient. Dark, because the shackle and body
    // below are light, and a light-on-dark padlock is legible at 16pt where a
    // two-tone one is mud.
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [CGColor(colorSpace: space, components: [0.24, 0.27, 0.36, 1])!,
                 CGColor(colorSpace: space, components: [0.10, 0.11, 0.16, 1])!] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: plate.maxY),
                               end: CGPoint(x: 0, y: plate.minY),
                               options: [])
    context.restoreGState()

    // A hairline along the top edge — the one cue that keeps the plate from
    // looking flat against a dark Dock.
    context.saveGState()
    context.addPath(platePath)
    context.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.14])!)
    context.setLineWidth(6)
    context.strokePath()
    context.restoreGState()

    // The padlock. Body first, then the shackle behind it.
    let bodyWidth: CGFloat = 420
    let bodyHeight: CGFloat = 330
    let body = CGRect(x: (canvas - bodyWidth) / 2, y: 300, width: bodyWidth, height: bodyHeight)

    let shackleWidth: CGFloat = 250
    let shackleThickness: CGFloat = 58
    let shackleTop: CGFloat = 790
    let shackleCentre = CGPoint(x: canvas / 2, y: shackleTop - shackleWidth / 2)

    context.saveGState()
    context.setStrokeColor(CGColor(colorSpace: space, components: [0.78, 0.83, 0.93, 1])!)
    context.setLineWidth(shackleThickness)
    context.setLineCap(.butt)
    let shackle = CGMutablePath()
    shackle.addArc(center: shackleCentre, radius: shackleWidth / 2,
                   startAngle: 0, endAngle: .pi, clockwise: false)
    shackle.move(to: CGPoint(x: shackleCentre.x - shackleWidth / 2, y: shackleCentre.y))
    shackle.addLine(to: CGPoint(x: shackleCentre.x - shackleWidth / 2, y: body.maxY - 20))
    shackle.move(to: CGPoint(x: shackleCentre.x + shackleWidth / 2, y: shackleCentre.y))
    shackle.addLine(to: CGPoint(x: shackleCentre.x + shackleWidth / 2, y: body.maxY - 20))
    context.addPath(shackle)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.addPath(CGPath(roundedRect: body, cornerWidth: 64, cornerHeight: 64, transform: nil))
    context.setFillColor(CGColor(colorSpace: space, components: [0.98, 0.80, 0.35, 1])!)
    context.fillPath()
    context.restoreGState()

    // Keyhole, punched out of the body so the plate shows through.
    context.saveGState()
    let keyholeCentre = CGPoint(x: canvas / 2, y: body.midY + 28)
    let keyhole = CGMutablePath()
    keyhole.addEllipse(in: CGRect(x: keyholeCentre.x - 44, y: keyholeCentre.y - 44,
                                  width: 88, height: 88))
    keyhole.addPath(CGPath(roundedRect: CGRect(x: keyholeCentre.x - 26,
                                               y: keyholeCentre.y - 120,
                                               width: 52, height: 110),
                           cornerWidth: 26, cornerHeight: 26, transform: nil))
    context.addPath(keyhole)
    context.setBlendMode(.destinationOut)
    context.fillPath()
    context.restoreGState()
}

func render(size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / canvas
    context.scaleBy(x: scale, y: scale)
    drawIcon(into: context)
    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])!
}

/// The ten entries `AppIcon.appiconset` declares, as (point size, scale).
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var images: [[String: String]] = []
for (points, scale) in variants {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try render(size: pixels).write(to: iconset.appendingPathComponent(name))
    images.append([
        "idiom": "mac",
        "size": "\(points)x\(points)",
        "scale": "\(scale)x",
        "filename": name,
    ])
    print("✓ \(name)  (\(pixels)×\(pixels) px)")
}

let contents: [String: Any] = [
    "images": images,
    "info": ["version": 1, "author": "Scripts/make-app-icon.swift"],
]
let json = try JSONSerialization.data(withJSONObject: contents,
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconset.appendingPathComponent("Contents.json"))
print("→ \(iconset.path)")
