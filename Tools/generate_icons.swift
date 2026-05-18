#!/usr/bin/env swift
//
// generate_icons.swift
//
// Renders the Peakmon app icon (SF Symbol `gauge.medium` on a
// blue → purple gradient squircle) at every size declared in
// `AppIcon.appiconset/Contents.json`, writes the PNGs into the
// appiconset, and rewrites Contents.json with filename entries.
//
// Style is intentionally aligned with the SSH-Key-Manager icon
// pipeline: same blue→purple gradient, same top-leading highlight,
// same squircle corner radius, same Core Graphics rendering path —
// the only visual change is the SF Symbol at the center, which is
// now a gauge instead of a key.
//
// Usage: swift Tools/generate_icons.swift
//

import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// MARK: - Configuration

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetDir = projectRoot
    .appendingPathComponent("Peakmon", isDirectory: true)
    .appendingPathComponent("Assets.xcassets", isDirectory: true)
    .appendingPathComponent("AppIcon.appiconset", isDirectory: true)

struct IconSpec {
    let pixels: Int
    let idiom: String
    let size: String
    let scale: String
    var filename: String { "icon_\(pixels).png" }
}

let specs: [IconSpec] = [
    .init(pixels: 16, idiom: "mac", size: "16x16", scale: "1x"),
    .init(pixels: 32, idiom: "mac", size: "16x16", scale: "2x"),
    .init(pixels: 32, idiom: "mac", size: "32x32", scale: "1x"),
    .init(pixels: 64, idiom: "mac", size: "32x32", scale: "2x"),
    .init(pixels: 128, idiom: "mac", size: "128x128", scale: "1x"),
    .init(pixels: 256, idiom: "mac", size: "128x128", scale: "2x"),
    .init(pixels: 256, idiom: "mac", size: "256x256", scale: "1x"),
    .init(pixels: 512, idiom: "mac", size: "256x256", scale: "2x"),
    .init(pixels: 512, idiom: "mac", size: "512x512", scale: "1x"),
    .init(pixels: 1024, idiom: "mac", size: "512x512", scale: "2x"),
]

let uniqueSizes = Array(Set(specs.map(\.pixels))).sorted()

// MARK: - Rendering

func renderIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = gfx

    // 1. Clip to squircle (continuous-corner rounded rect).
    let cornerRadius = size * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    squircle.addClip()

    // 2. Diagonal blue → purple gradient (matches SSH-Key-Manager).
    let top = NSColor(srgbRed: 0.29, green: 0.42, blue: 1.00, alpha: 1.0) // #4A6BFF
    let bottom = NSColor(srgbRed: 0.69, green: 0.29, blue: 1.00, alpha: 1.0) // #B14AFF
    if let gradient = NSGradient(colors: [top, bottom]) {
        gradient.draw(in: rect, angle: -45)
    }

    // 3. Subtle top-leading highlight.
    if let highlight = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.18),
        NSColor(white: 1.0, alpha: 0.0),
    ]) {
        highlight.draw(in: rect, angle: -90)
    }

    // 4. SF Symbol — `gauge.medium`, white, semibold. This is
    //    Apple's modern full-ring dashboard gauge symbol; on
    //    macOS 26 it renders as a closed circular dial with tick
    //    marks and a needle.
    let symbolPointSize = size * 0.62
    let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
    else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }

    let symbolRect = CGRect(
        x: (size - symbol.size.width) / 2,
        y: (size - symbol.size.height) / 2,
        width: symbol.size.width,
        height: symbol.size.height,
    )

    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.015)
    shadow.shadowBlurRadius = size * 0.035
    shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
    shadow.set()

    symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = ctx.makeImage() else { return nil }
    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
    bitmapRep.size = NSSize(width: pixels, height: pixels)
    return bitmapRep.representation(using: .png, properties: [:])
}

// MARK: - Write PNGs

let fileManager = FileManager.default
try? fileManager.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for pixelSize in uniqueSizes {
    guard let data = renderIcon(pixels: pixelSize) else {
        FileHandle.standardError.write(Data("Failed to render \(pixelSize)px\n".utf8))
        exit(1)
    }
    let url = iconsetDir.appendingPathComponent("icon_\(pixelSize).png")
    do {
        try data.write(to: url)
        print("wrote \(url.lastPathComponent) (\(data.count) bytes)")
    } catch {
        FileHandle.standardError.write(Data("Failed to write \(url.path): \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - Rewrite Contents.json

let contents: [String: Any] = [
    "info": ["author": "xcode", "version": 1],
    "images": specs.map { spec in
        [
            "idiom": spec.idiom,
            "size": spec.size,
            "scale": spec.scale,
            "filename": spec.filename,
        ]
    },
]

let json = try JSONSerialization.data(
    withJSONObject: contents,
    options: [.prettyPrinted, .sortedKeys],
)
try json.write(to: iconsetDir.appendingPathComponent("Contents.json"))
print("done -> \(iconsetDir.path)")
