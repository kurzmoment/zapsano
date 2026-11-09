import AppKit
import CoreImage.CIFilterBuiltins
import CoreText
import FakturaCore

/// Renders the immutable invoice snapshot. The caller archives the returned bytes once.
@MainActor
enum InvoicePDFRenderer {
    static let templateVersion = 8

    private static let ink = Brand.documentInk
    private static let muted = NSColor(srgbRed: 0.38, green: 0.40, blue: 0.44, alpha: 1)
    private static let accent = Brand.documentAccent
    private static let paper = Brand.documentTint

    static func render(invoice: IssuedInvoice) throws -> Data {
        guard invoice.lineTotals.count == invoice.lines.count, invoice.currency == "CZK" else {
            throw RenderingError.invalidSnapshot
        }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else { throw RenderingError.creationFailed }
        var mediaBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let metadata = [
            kCGPDFContextTitle: "Faktura \(invoice.number)",
            kCGPDFContextCreator: Brand.name,
        ] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata) else {
            throw RenderingError.creationFailed
        }
        let page = PageWriter(context: context, bounds: mediaBox, invoiceNumber: invoice.number)
        page.beginPage()
        try page.columns([
            .init(text: "DODAVATEL", x: 44, width: 242, fontSize: 8, bold: true, color: muted),
            .init(text: "ODBĚRATEL", x: 310, width: 241, fontSize: 8, bold: true, color: muted),
        ])
        page.space(4)
        try page.columns([
            .init(text: invoice.supplier.name, x: 44, width: 242, fontSize: 10, bold: true),
            .init(text: invoice.customer.name, x: 310, width: 241, fontSize: 10, bold: true),
        ])
        page.space(3)
        try page.columns([
            .init(text: partyText(invoice.supplier), x: 44, width: 242, fontSize: 8.5),
            .init(text: partyText(invoice.customer), x: 310, width: 241, fontSize: 8.5),
        ])
        page.space(10)
        page.dates(issueDate: date(invoice.issueDate), dueDate: date(invoice.dueDate))
        page.space(6)
        let intro = invoice.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Fakturuji Vám za dodané zboží či služby:" : invoice.note
        try page.textBlock(intro)
        page.space(6)
        page.tableHeader()
        for (index, line) in invoice.lines.enumerated() {
            try page.columns([
                .init(text: line.description, x: 44, width: 231),
                .init(text: decimal(line.quantity) + " " + line.unit, x: 285, width: 66, alignment: .right),
                .init(text: money(line.unitPrice, maximumFractionDigits: 38), x: 361, width: 85, alignment: .right),
                .init(text: money(invoice.lineTotals[index]), x: 456, width: 95, alignment: .right),
            ], repeatTableHeader: true)
            page.space(1.5)
            page.rule()
            page.space(1.5)
        }
        if let discount = invoice.discountAmount, discount > .zero {
            page.space(4)
            try page.columns([
                .init(text: "Celkem před slevou", x: 44, width: 330),
                .init(text: money(invoice.lineTotals.reduce(.zero, +)), x: 390, width: 161, alignment: .right),
            ])
            page.space(2)
            try page.columns([
                .init(text: "Sleva", x: 44, width: 330),
                .init(text: money(-discount), x: 390, width: 161, alignment: .right),
            ])
        }
        if let adjustment = invoice.adjustment, adjustment != .zero {
            page.space(8)
            try page.columns([
                .init(text: invoice.adjustmentDescription ?? "Úprava částky", x: 44, width: 330),
                .init(text: money(adjustment), x: 390, width: 161, alignment: .right),
            ])
        }
        let terms = invoice.paymentTerms ?? InvoiceTextDefaults.paymentTerms
        if !terms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            page.space(8)
            try page.textBlock(terms, heading: "PLATEBNÍ PODMÍNKY")
        }
        page.space(8)
        try page.paymentSummary(invoice: invoice)
        page.endPage()
        context.closePDF()
        return output as Data
    }

    private static func partyText(_ party: Party) -> String {
        [
            party.address,
            party.registrationNumber.isEmpty ? "" : "IČO: \(party.registrationNumber)",
            party.taxNumber.isEmpty ? "" : "DIČ: \(party.taxNumber)",
            [party.email, party.phone ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
            party.website ?? "",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func paymentText(_ invoice: IssuedInvoice) -> String {
        [
            invoice.supplier.bankAccount.isEmpty ? "" : "Bankovní účet: \(invoice.supplier.bankAccount)",
            invoice.supplier.iban.map { "IBAN: \($0)" } ?? "",
            invoice.supplier.bic.flatMap { $0.isEmpty ? nil : "BIC/SWIFT: \($0)" } ?? "",
            [invoice.variableSymbol.isEmpty ? "" : "Variabilní symbol: \(invoice.variableSymbol)",
             invoice.constantSymbol.flatMap { $0.isEmpty ? nil : "Konstantní symbol: \($0)" } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · "),
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func date(_ value: CalendarDate) -> String {
        "\(value.day). \(value.month). \(value.year)"
    }

    private static func decimal(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "cs_CZ")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 38
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }

    private static func money(_ value: Decimal, maximumFractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "cs_CZ")
        formatter.numberStyle = .currency
        formatter.currencyCode = "CZK"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value) Kč"
    }

    private enum RenderingError: LocalizedError {
        case creationFailed
        case textDoesNotFit
        case invalidSnapshot

        var errorDescription: String? {
            switch self {
            case .creationFailed: "Nepodařilo se vytvořit PDF faktury."
            case .textDoesNotFit: "Text faktury se nepodařilo rozložit na stránky."
            case .invalidSnapshot: "Uložená faktura nemá platné částky nebo podporovanou měnu."
            }
        }
    }

    @MainActor private struct Column {
        let text: String
        let x: CGFloat
        let width: CGFloat
        var fontSize: CGFloat = 8.5
        var bold = false
        var alignment: NSTextAlignment = .left
        var color: NSColor = ink

        var attributedText: NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineSpacing = 1.2
            paragraph.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: bold ? .semibold : .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
        }
    }

    @MainActor private final class PageWriter {
        let context: CGContext
        let bounds: CGRect
        let invoiceNumber: String
        var y: CGFloat = 0
        var pageNumber = 0
        let bottom: CGFloat = 782

        init(context: CGContext, bounds: CGRect, invoiceNumber: String) {
            self.context = context
            self.bounds = bounds
            self.invoiceNumber = invoiceNumber
        }

        func beginPage(repeatTableHeader: Bool = false) {
            context.beginPDFPage(nil)
            pageNumber += 1
            if let logo = Brand.supplierLogo?.page(at: 1) {
                let target = CGRect(x: 44, y: bounds.height - 74, width: 64, height: 40)
                context.saveGState()
                context.concatenate(logo.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(logo)
                context.restoreGState()
            }
            y = 43
            drawFixed("FAKTURA", x: 177, top: y, width: 155, height: 30, size: 16, bold: true)
            drawFittedLine(invoiceNumber, x: 337, top: y, width: 214, size: 18, color: accent, rightAligned: true)
            y = 84
            if repeatTableHeader { tableHeader() }
        }

        func endPage() {
            let contentY = y
            y = 794
            rule()
            y = contentY
            drawFittedLine("Faktura \(invoiceNumber)", x: 44, top: 805, width: 325, size: 8, color: muted)
            context.saveGState()
            context.translateBy(x: 382, y: bounds.height - 804)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(muted.cgColor)
            context.addPath(BrandSymbol().path(in: CGRect(x: 0, y: 0, width: 14, height: 14)).cgPath)
            context.fillPath()
            context.restoreGState()
            drawFixed(Brand.name, x: 400, top: 805, width: 65, height: 15, size: 8, color: muted)
            drawFixed("Strana \(pageNumber)", x: 477, top: 805, width: 74, height: 15, size: 8, alignment: .right, color: muted)
            context.endPDFPage()
        }

        func ensureSpace(_ height: CGFloat, repeatTableHeader: Bool = false) {
            if y + height > bottom {
                endPage()
                beginPage(repeatTableHeader: repeatTableHeader)
            }
        }

        func space(_ height: CGFloat) { y += height }

        func rule() {
            context.setStrokeColor(CGColor(gray: 0.88, alpha: 1))
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: 44, y: bounds.height - y))
            context.addLine(to: CGPoint(x: 551, y: bounds.height - y))
            context.strokePath()
        }

        func tableHeader() {
            ensureSpace(28 + minimumLineHeight(Column(text: "Položka", x: 44, width: 231)))
            fill(x: 36, top: y - 5, width: 523, height: 25, color: paper)
            drawFixed("Položka", x: 44, top: y, width: 231, height: 18, size: 8.5, bold: true, color: accent)
            drawFixed("Množství", x: 285, top: y, width: 66, height: 18, size: 8.5, bold: true, alignment: .right, color: accent)
            drawFixed("Cena / jedn.", x: 361, top: y, width: 85, height: 18, size: 8.5, bold: true, alignment: .right, color: accent)
            drawFixed("Celkem", x: 456, top: y, width: 95, height: 18, size: 8.5, bold: true, alignment: .right, color: accent)
            y += 28
        }

        func dates(issueDate: String, dueDate: String) {
            ensureSpace(35)
            drawFixed("VYSTAVENO", x: 44, top: y, width: 150, height: 15, size: 8, bold: true, color: muted)
            drawFixed("SPLATNOST", x: 220, top: y, width: 150, height: 15, size: 8, bold: true, color: muted)
            drawFixed("ZPŮSOB ÚHRADY", x: 396, top: y, width: 155, height: 15, size: 8, bold: true, color: muted)
            y += 16
            drawFixed(issueDate, x: 44, top: y, width: 150, height: 22, size: 9.5, bold: true)
            drawFixed(dueDate, x: 220, top: y, width: 150, height: 22, size: 9.5, bold: true)
            drawFixed("Bankovním převodem", x: 396, top: y, width: 155, height: 22, size: 9.5)
            y += 19
        }

        func paymentSummary(invoice: IssuedInvoice) throws {
            var qrImage: CGImage?
            var fallback: String?
            do {
                let payload = try QRPayment.payload(invoice: invoice)
                let filter = CIFilter.qrCodeGenerator()
                filter.message = Data(payload.utf8)
                filter.correctionLevel = "M"
                if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) {
                    qrImage = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
                }
                if qrImage == nil { fallback = "QR kód se nepodařilo vytvořit. Použijte uvedené platební údaje." }
            } catch {
                fallback = error.localizedDescription
            }
            let totalColumns = [
                Column(text: "CELKEM K ÚHRADĚ", x: 184, width: 148, fontSize: 8.5, bold: true, color: accent),
                Column(text: money(invoice.total), x: 338, width: 203, fontSize: 17, bold: true, alignment: .right, color: accent),
            ]
            let tax = Column(text: "Dodavatel není plátcem DPH.", x: 184, width: 357, fontSize: 8.5, color: muted)
            let paymentHeading = Column(text: "PLATEBNÍ ÚDAJE", x: 184, width: 357, fontSize: 8, bold: true, color: muted)
            let bank = Column(text: paymentText(invoice), x: 184, width: 357, fontSize: 8.5)
            let explanation = fallback.map { Column(text: $0, x: 184, width: 357, fontSize: 8.5, color: muted) }
            let rightHeight = (totalColumns.map(measuredHeight).max() ?? 0) + measuredHeight(tax) + measuredHeight(paymentHeading)
                + measuredHeight(bank) + (explanation.map(measuredHeight) ?? 0) + (explanation == nil ? 26 : 32)
            let panelHeight = max(148, rightHeight + 24)
            // Ordinary payment summaries stay whole. Pathological long bank text can continue on the next page.
            ensureSpace(min(panelHeight, bottom - 84))
            let start = y
            let startingPage = pageNumber
            fill(x: 36, top: start, width: 523, height: min(panelHeight, bottom - start), color: paper)
            if let qrImage {
                // A 12pt quiet zone around the 96pt matrix is at least four modules for this payload.
                fill(x: 44, top: start + 8, width: 120, height: 120, color: .white)
                context.saveGState()
                context.interpolationQuality = .none
                context.draw(qrImage, in: CGRect(x: 56, y: bounds.height - start - 116, width: 96, height: 96))
                context.restoreGState()
                drawFixed("QR platba", x: 44, top: start + 130, width: 120, height: 15, size: 8, alignment: .center, color: muted)
            } else {
                drawFixed("QR platba\nnení dostupná", x: 56, top: start + 47, width: 96, height: 40, size: 10, alignment: .center, color: muted)
            }
            y += 12
            try columns(totalColumns)
            space(5)
            try columns([tax])
            space(9)
            try columns([paymentHeading])
            space(4)
            try columns([bank])
            if let explanation {
                space(6)
                try columns([explanation])
            }
            if pageNumber == startingPage { y = max(y + 12, start + panelHeight) }
        }

        func textBlock(_ text: String, heading: String? = nil) throws {
            let body = Column(text: text, x: 44, width: 507, fontSize: 8.5, color: muted)
            if let heading {
                let label = Column(text: heading, x: 44, width: 507, fontSize: 8, bold: true, color: muted)
                ensureSpace(measuredHeight(label) + 3 + minimumLineHeight(body))
                try columns([label])
                space(3)
            }
            try columns([body])
        }

        private func measuredHeight(_ column: Column) -> CGFloat {
            guard !column.text.isEmpty else { return 0 }
            let setter = CTFramesetterCreateWithAttributedString(column.attributedText)
            return ceil(CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                    CGSize(width: column.width, height: CGFloat.greatestFiniteMagnitude), nil).height) + 3
        }

        private func minimumLineHeight(_ column: Column, offset: Int = 0) -> CGFloat {
            let typesetter = CTTypesetterCreateWithAttributedString(column.attributedText)
            let length = CTTypesetterSuggestLineBreak(typesetter, offset, Double(column.width))
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: length))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            return max(ceil(ascent + descent + leading) + 3, column.fontSize + 3)
        }

        private func fill(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, color: NSColor) {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: bounds.height - top - height, width: width, height: height))
        }

        /// Each column consumes its own UTF-16 range, so even a single long item can span pages.
        func columns(_ columns: [Column], repeatTableHeader: Bool = false) throws {
            let texts = columns.map(\.attributedText)
            let setters = texts.map { CTFramesetterCreateWithAttributedString($0) }
            var offsets = Array(repeating: 0, count: columns.count)
            while offsets.indices.contains(where: { offsets[$0] < texts[$0].length }) {
                let firstLineHeight = columns.indices.filter { offsets[$0] < texts[$0].length }
                    .map { minimumLineHeight(columns[$0], offset: offsets[$0]) }.max() ?? 0
                ensureSpace(firstLineHeight, repeatTableHeader: repeatTableHeader)
                let available = bottom - y
                var needed: CGFloat = 0
                for index in columns.indices where offsets[index] < texts[index].length {
                    let size = CTFramesetterSuggestFrameSizeWithConstraints(
                        setters[index], CFRange(location: offsets[index], length: 0), nil,
                        CGSize(width: columns[index].width, height: .greatestFiniteMagnitude), nil
                    )
                    needed = max(needed, ceil(size.height) + 3)
                }
                let height = min(needed, available)
                for index in columns.indices where offsets[index] < texts[index].length {
                    let rect = CGRect(x: columns[index].x, y: bounds.height - y - height, width: columns[index].width, height: height)
                    let frame = CTFramesetterCreateFrame(setters[index], CFRange(location: offsets[index], length: 0), CGPath(rect: rect, transform: nil), nil)
                    let visible = CTFrameGetVisibleStringRange(frame)
                    guard visible.length > 0 else { throw RenderingError.textDoesNotFit }
                    context.textMatrix = .identity
                    CTFrameDraw(frame, context)
                    offsets[index] += visible.length
                }
                y += height
                if offsets.indices.contains(where: { offsets[$0] < texts[$0].length }) {
                    endPage()
                    beginPage(repeatTableHeader: repeatTableHeader)
                }
            }
        }

        private func drawFittedLine(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat, size: CGFloat, color: NSColor, rightAligned: Bool = false) {
            let line = CTLineCreateWithAttributedString(Column(text: text, x: x, width: width, fontSize: size, color: color).attributedText)
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let scale = min(1, width / max(textWidth, 1))
            context.saveGState()
            context.translateBy(x: rightAligned ? x + width - textWidth * scale : x, y: bounds.height - top - size)
            context.scaleBy(x: scale, y: scale)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }

        private func drawFixed(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, size: CGFloat, bold: Bool = false, alignment: NSTextAlignment = .left, color: NSColor? = nil) {
            let column = Column(text: text, x: x, width: width, fontSize: size, bold: bold, alignment: alignment, color: color ?? ink)
            let setter = CTFramesetterCreateWithAttributedString(column.attributedText)
            let path = CGPath(rect: CGRect(x: x, y: bounds.height - top - height, width: width, height: height), transform: nil)
            context.textMatrix = .identity
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        }
    }
}
