import AppKit
import SwiftUI

/// Display identity only. The bundle identifier and data directory remain stable across renames.
enum Brand {
    static let name = "Zapsáno"
    static let documentInk = NSColor(srgbRed: 0.09, green: 0.11, blue: 0.14, alpha: 1)
    static let documentAccent = NSColor(srgbRed: 0.11, green: 0.32, blue: 0.64, alpha: 1)
    static let documentTint = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1)

    /// Personal supplier mark bundled with this single-company app; never read from another project at runtime.
    static var supplierLogo: CGPDFDocument? {
        if let url = Bundle.main.url(forResource: "SupplierLogo", withExtension: "pdf") {
            return CGPDFDocument(url as CFURL)
        }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "SupplierLogo", withExtension: "pdf") {
            return CGPDFDocument(url as CFURL)
        }
        #endif
        return nil
    }
}

/// A folded Z drawn as a single ledger stroke. Shared vector geometry for the app and Dock icon.
struct BrandSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let transform = CGAffineTransform(scaleX: side, y: side)
            .concatenating(CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2))
        var path = Path()
        path.move(to: CGPoint(x: 0.15, y: 0.14))
        path.addLine(to: CGPoint(x: 0.73, y: 0.14))
        path.addLine(to: CGPoint(x: 0.85, y: 0.26))
        path.addLine(to: CGPoint(x: 0.85, y: 0.31))
        path.addLine(to: CGPoint(x: 0.42, y: 0.69))
        path.addLine(to: CGPoint(x: 0.85, y: 0.69))
        path.addLine(to: CGPoint(x: 0.85, y: 0.86))
        path.addLine(to: CGPoint(x: 0.27, y: 0.86))
        path.addLine(to: CGPoint(x: 0.15, y: 0.74))
        path.addLine(to: CGPoint(x: 0.15, y: 0.69))
        path.addLine(to: CGPoint(x: 0.58, y: 0.31))
        path.addLine(to: CGPoint(x: 0.15, y: 0.31))
        path.closeSubpath()
        return path.applying(transform)
    }
}

struct BrandMark: View {
    var body: some View {
        BrandSymbol().fill(.primary).accessibilityHidden(true)
    }
}
