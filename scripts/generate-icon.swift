import AppKit
import SwiftUI

@main
struct IconGenerator {
    @MainActor static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let variants = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                        (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                        (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
        for (size, name) in variants {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let context = graphics.cgContext
            context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
            let tile = CGRect(x: 80, y: 80, width: 864, height: 864)
            context.setFillColor(Brand.documentAccent.cgColor)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 192, cornerHeight: 192, transform: nil))
            context.fillPath()
            // Draw the same top-down geometry that SwiftUI uses.
            context.translateBy(x: 0, y: 1024)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(NSColor.white.cgColor)
            context.addPath(BrandSymbol().path(in: CGRect(x: 206, y: 206, width: 612, height: 612)).cgPath)
            context.fillPath()
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: destination.appendingPathComponent("icon_\(name).png"))
        }
    }
}
