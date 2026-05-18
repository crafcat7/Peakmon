//
//  AppIconExporter.swift
//  Peakmon
//
//  Debug-only utility that rasterises `AppIconArtwork` at every
//  size required by `AppIcon.appiconset` and writes the PNGs into
//  the asset catalog so a developer can refresh the icon by running
//  the app and invoking "Export App Icons" from the Settings About
//  page (DEBUG builds only).
//

#if DEBUG
    import AppKit
    import SwiftUI

    enum AppIconExporter {
        struct Variant {
            let fileName: String
            let pixelSize: Int
        }

        /// Exact set of files referenced by `AppIcon.appiconset`'s
        /// `Contents.json` (idiom = mac, 16/32/128/256/512 @1x@2x).
        static let variants: [Variant] = [
            .init(fileName: "icon_16x16.png", pixelSize: 16),
            .init(fileName: "icon_16x16@2x.png", pixelSize: 32),
            .init(fileName: "icon_32x32.png", pixelSize: 32),
            .init(fileName: "icon_32x32@2x.png", pixelSize: 64),
            .init(fileName: "icon_128x128.png", pixelSize: 128),
            .init(fileName: "icon_128x128@2x.png", pixelSize: 256),
            .init(fileName: "icon_256x256.png", pixelSize: 256),
            .init(fileName: "icon_256x256@2x.png", pixelSize: 512),
            .init(fileName: "icon_512x512.png", pixelSize: 512),
            .init(fileName: "icon_512x512@2x.png", pixelSize: 1024),
        ]

        /// Renders each variant and writes PNGs to the chosen
        /// directory. Returns the directory that received the files.
        @MainActor
        @discardableResult
        static func export(to directory: URL) throws -> URL {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
            )

            for variant in variants {
                let pngData = try renderPNG(pixelSize: variant.pixelSize)
                let outURL = directory.appendingPathComponent(variant.fileName)
                try pngData.write(to: outURL)
            }
            return directory
        }

        @MainActor
        private static func renderPNG(pixelSize: Int) throws -> Data {
            let view = AppIconArtwork()
                .frame(width: AppIconArtwork.canvas, height: AppIconArtwork.canvas)
            let renderer = ImageRenderer(content: view)
            // `scale` controls the backing-store density. We want a
            // final bitmap of `pixelSize` px on each side, derived
            // from the 1024-pt canvas, so the scale factor is the
            // ratio between the two.
            renderer.scale = CGFloat(pixelSize) / AppIconArtwork.canvas
            renderer.isOpaque = true

            guard let cgImage = renderer.cgImage else {
                throw ExportError.renderingFailed
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = NSSize(width: pixelSize, height: pixelSize)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw ExportError.encodingFailed
            }
            return png
        }

        enum ExportError: Error {
            case renderingFailed
            case encodingFailed
        }
    }
#endif
