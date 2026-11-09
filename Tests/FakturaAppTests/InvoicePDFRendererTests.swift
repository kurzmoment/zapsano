import Foundation
import AppKit
import PDFKit
import Vision
import Testing
import FakturaCore
@testable import Faktura

@MainActor
struct InvoicePDFRendererTests {
    private func invoice(lines: [InvoiceLine], note: String = "Děkujeme za spolupráci.", paymentTerms: String? = InvoiceTextDefaults.paymentTerms) throws -> IssuedInvoice {
        let draft = try InvoiceDraft(
            supplier: Party(name: "Jan Novák", registrationNumber: "12345678", address: "Dlouhá 123\n110 00 Praha", bankAccount: "123456789/0100"),
            customer: Party(name: "Žluťoučký kůň s.r.o.", address: "Česká 5\n602 00 Brno"),
            lines: lines,
            issueDate: CalendarDate(year: 2026, month: 10, day: 30),
            dueDate: CalendarDate(year: 2026, month: 11, day: 13),
            note: note,
            variableSymbol: "202612", paymentTerms: paymentTerms
        )
        return try IssuedInvoice.issue(draft: draft, number: "2026-12")
    }

    @Test func longCzechInvoiceKeepsEveryItemAndExactAmountsAcrossPages() throws {
        let lines = (1...80).map { index in
            InvoiceLine(description: "Položka \(index) — Návrh a implementace aplikace s českými znaky: příliš žluťoučký kůň.",
                        quantity: 2, unit: "hod", unitPrice: Decimal(string: "1234.567")!)
        }
        let invoice = try invoice(lines: lines)
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: invoice)))
        let text = try #require(document.string)
        let compact = text.filter { !$0.isWhitespace }
        #expect(document.pageCount > 1)
        #expect(text.contains("Jan Novák"))
        #expect(text.contains("Žluťoučký kůň"))
        #expect(text.contains("202612"))
        #expect(text.contains("123456789/0100"))
        #expect(compact.contains("1234,567Kč"))
        // PDF text extraction may interleave the two columns depending on their font sizes.
        #expect(compact.contains("CELKEMKÚHRADĚ"))
        #expect(compact.contains("197530,40Kč"))
        for index in 1...80 {
            #expect(text.contains("Položka \(index) —"))
        }
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            let pageText = try #require(page.string)
            #expect(pageText.contains("FAKTURA 2026-12"))
            #expect(pageText.contains("Strana \(index + 1)"))
            #expect(abs(page.bounds(for: .mediaBox).width - 595.28) < 0.1)
            #expect(abs(page.bounds(for: .mediaBox).height - 841.89) < 0.1)
        }
    }

    @Test func singleItemAndNoteCanEachSpanMultiplePagesWithoutLosingTail() throws {
        let description = String(repeating: "Příliš žluťoučký kůň úpěl ďábelské ódy. ", count: 220) + "KONECPOLOŽKY"
        let note = String(repeating: "Doplňující informace k dodané službě. ", count: 220) + "KONECPOZNÁMKY"
        let invoice = try invoice(lines: [InvoiceLine(description: description, quantity: 1, unitPrice: 100)], note: note)
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: invoice)))
        let text = try #require(document.string)
        #expect(document.pageCount > 2)
        #expect(text.contains("KONECPOLOŽKY"))
        #expect(text.contains("KONECPOZNÁMKY"))
        #expect(text.filter { !$0.isWhitespace }.contains("CELKEMKÚHRADĚ100,00Kč"))
    }

    @Test func showsNamedSignedAdjustmentAndAdjustedGrandTotal() throws {
        let original = try invoice(lines: [InvoiceLine(description: "Vývoj", quantity: 1, unitPrice: 1000)])
        let draft = InvoiceDraft(supplier: original.supplier, customer: original.customer, lines: original.lines,
                                 issueDate: original.issueDate, dueDate: original.dueDate,
                                 adjustment: -125, adjustmentDescription: "Sleva dle původní faktury")
        let adjusted = try IssuedInvoice.issue(draft: draft, number: "2026-12")
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: adjusted)))
        let text = try #require(document.string)
        let compact = text.filter { !$0.isWhitespace }
        #expect(text.contains("Sleva dle původní faktury"))
        #expect(compact.contains("-125,00Kč"))
        #expect(compact.contains("CELKEMKÚHRADĚ875,00Kč"))
    }

    @Test func showsDiscountSeparatelyFromPositiveRounding() throws {
        let original = try invoice(lines: [InvoiceLine(description: "Vývoj", quantity: 1, unitPrice: 100)])
        let draft = InvoiceDraft(supplier: original.supplier, customer: original.customer, lines: original.lines,
                                 issueDate: original.issueDate, dueDate: original.dueDate,
                                 adjustment: Decimal(string: "0.35"), adjustmentDescription: "Zaokrouhlení",
                                 discountAmount: Decimal(string: "0.20"))
        let issued = try IssuedInvoice.issue(draft: draft, number: "2026-12")
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: issued)))
        let compact = try #require(document.string).filter { !$0.isWhitespace }
        #expect(compact.contains("Sleva-0,20Kč"))
        #expect(compact.contains("Zaokrouhlení0,35Kč"))
        #expect(compact.contains("CELKEMKÚHRADĚ100,15Kč"))
    }

    @Test func IBANIsPrintedFromIssuedSnapshotAndOmittedForOlderInvoices() throws {
        let original = try invoice(lines: [InvoiceLine(description: "Služba", quantity: 1, unitPrice: 100)])
        var supplier = original.supplier
        supplier.iban = "CZ6508000000192000145399"
        let draft = InvoiceDraft(supplier: supplier, customer: original.customer, lines: original.lines,
                                 issueDate: original.issueDate, dueDate: original.dueDate)
        let issued = try IssuedInvoice.issue(draft: draft, number: "2026-13")
        supplier.iban = nil
        let text = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: issued))?.string)
        #expect(text.filter { !$0.isWhitespace }.contains("IBAN:CZ6508000000192000145399"))
        let legacyText = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: original))?.string)
        #expect(!legacyText.contains("IBAN:"))
    }

    @Test func qrOnRasterizedPDFDecodesToExactPaymentPayload() throws {
        let original = try invoice(lines: [InvoiceLine(description: "Vývoj", quantity: 2, unitPrice: 1250)])
        var supplier = original.supplier
        supplier.bankAccount = "19-2000145399/0800"
        supplier.iban = "CZ6508000000192000145399"
        let draft = InvoiceDraft(supplier: supplier, customer: original.customer, lines: original.lines,
                                 issueDate: original.issueDate, dueDate: original.dueDate, variableSymbol: "202612")
        let issued = try IssuedInvoice.issue(draft: draft, number: "2026-12")
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: issued)))
        #expect(document.string?.contains("QR platba") == true)
        var payloads: [String] = []
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            let image = page.thumbnail(of: NSSize(width: 1190, height: 1684), for: .mediaBox)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let cgImage = try #require(bitmap.cgImage)
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            payloads += request.results?.compactMap(\.payloadStringValue) ?? []
        }
        #expect(payloads == [try QRPayment.payload(invoice: issued)])
    }

    @Test func invalidAccountShowsExplanationInsteadOfIncorrectQRCode() throws {
        let original = try invoice(lines: [InvoiceLine(description: "Vývoj", quantity: 1, unitPrice: 100)])
        var supplier = original.supplier
        supplier.bankAccount = "nesprávný účet"
        let draft = InvoiceDraft(supplier: supplier, customer: original.customer, lines: original.lines,
                                 issueDate: original.issueDate, dueDate: original.dueDate)
        let issued = try IssuedInvoice.issue(draft: draft, number: "2026-12")
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: issued)))
        let text = try #require(document.string)
        #expect(text.contains("není dostupná"))
        let reason = try #require(BillingError.invalidDomesticAccount.errorDescription)
        #expect(text.filter { !$0.isWhitespace }.contains(reason.filter { !$0.isWhitespace }))
        #expect(text.contains("nesprávný účet"))
    }

    @Test func fortyCharacterInvoiceNumberRemainsCompleteInHeader() throws {
        let original = try invoice(lines: [InvoiceLine(description: "Vývoj", quantity: 1, unitPrice: 100)])
        let draft = InvoiceDraft(supplier: original.supplier, customer: original.customer, lines: original.lines,
                                 issueDate: original.issueDate, dueDate: original.dueDate)
        let number = String(repeating: "W", count: 40)
        let issued = try IssuedInvoice.issue(draft: draft, number: number)
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: issued)))
        let text = try #require(document.page(at: 0)?.string)
        #expect(text.components(separatedBy: number).count >= 3)
    }

    private func longCustomerInvoice(itemCount: Int, note: String) throws -> IssuedInvoice {
        let supplier = Party(name: "Ukázkový Dodavatel", registrationNumber: "12345678",
                             address: "Ukázková 12\n170 00 Praha\nČeská republika", email: "test@example.test",
                             bankAccount: "19-2000145399/0800", iban: "CZ6508000000192000145399",
                             phone: "+420 777 000 111", website: "https://example.test", bic: "GIBACZPX")
        let customer = Party(name: "SYNTHETIC INTERACTIVE STUDIO s.r.o.", registrationNumber: "87654321",
                             taxNumber: "CZ87654321", address: "Vzorová 8\n602 00 Brno\nČeská republika")
        let draft = try InvoiceDraft(supplier: supplier, customer: customer,
                                     lines: (1...itemCount).map { InvoiceLine(description: "Položka \($0) - Návrh a vývoj aplikace", quantity: 10, unit: "hod", unitPrice: 625) },
                                     issueDate: CalendarDate(year: 2026, month: 10, day: 30), dueDate: CalendarDate(year: 2026, month: 11, day: 13),
                                     note: note, variableSymbol: "202613", discountAmount: 200)
        return try IssuedInvoice.issue(draft: draft, number: "2026-13")
    }

    @Test(arguments: ["", "Děkujeme za spolupráci.\nDodané práce byly převzaty.\nÚhradu prosím označte variabilním symbolem.\nTěšíme se na další projekt."])
    func fourItemsLongCustomerAndDiscountFitOnePageWithPaymentBlock(note: String) throws {
        let invoice = try longCustomerInvoice(itemCount: 4, note: note)
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: invoice)))
        #expect(document.pageCount == 1)
        #expect(document.string?.contains("QR platba") == true)
        #expect(document.string?.contains("PLATEBNÍ ÚDAJE") == true)
        let text = try #require(document.string)
        for line in note.split(separator: "\n") { #expect(text.contains(line)) }
    }

    @Test func twelveSingleLineItemsWithDiscountIBANAndTwoLineNoteFitOneA4Page() throws {
        let note = "Děkujeme za spolupráci.\nDodané práce byly převzaty."
        let invoice = try longCustomerInvoice(itemCount: 12, note: note)
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: invoice)))
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        #expect(abs(page.bounds(for: .mediaBox).width - 595.28) < 0.1)
        #expect(abs(page.bounds(for: .mediaBox).height - 841.89) < 0.1)
        let text = try #require(page.string)
        let compact = text.filter { !$0.isWhitespace }
        for index in 1...12 { #expect(text.contains("Položka \(index) - Návrh a vývoj aplikace")) }
        for line in note.split(separator: "\n") { #expect(text.contains(line)) }
        #expect(compact.contains("IBAN:CZ6508000000192000145399"))
        #expect(compact.contains("Sleva-200,00Kč"))
        #expect(compact.contains("74800,00Kč"))
        #expect(text.contains("QR platba"))
    }

    @Test func longNotePreservesEveryLineAcrossPages() throws {
        let noteLines = (1...140).map { String(format: "Poznámka %03d: Převzetí služby potvrzeno zákazníkem.", $0) }
        let issued = try invoice(lines: [InvoiceLine(description: "Služba", quantity: 1, unitPrice: 100)],
                                 note: noteLines.joined(separator: "\n"))
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: issued)))
        let text = try #require(document.string)
        #expect(document.pageCount >= 3)
        for line in noteLines { #expect(text.contains(line)) }
        #expect(text.components(separatedBy: noteLines.last!).count == 2)
    }

    @Test(arguments: Array(stride(from: 4, through: 28, by: 2)))
    func paymentTermsHeadingStaysWithFirstLineNearPageBoundaries(itemCount: Int) throws {
        let firstLine = "ÚVODPOZNÁMKY: Dodané práce byly převzaty."
        let issued = try invoice(lines: (1...itemCount).map {
            InvoiceLine(description: "Služba \($0) — implementace a předání", quantity: 1, unit: "hod", unitPrice: 100)
        }, paymentTerms: firstLine + "\nZávěrečná informace pro odběratele.")
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: issued)))
        var headingPages = 0
        for index in 0..<document.pageCount {
            let text = try #require(document.page(at: index)?.string)
            if text.contains("PLATEBNÍ PODMÍNKY") {
                headingPages += 1
                #expect(text.contains(firstLine))
            }
        }
        #expect(headingPages == 1)
    }

    @Test func introTermsAndPaymentAreSeparateAndOrdered() throws {
        let original = try invoice(lines: [InvoiceLine(description: "UNIKÁTNÍ POLOŽKA", quantity: 1, unitPrice: 100)],
                                   note: "Fakturuji za říjnové služby.", paymentTerms: "SPECIÁLNÍ PODMÍNKY úhrady.")
        var draft = original.editableDraft()
        draft.supplier.phone = "+420 777 000 111"
        draft.supplier.website = "https://example.test"
        draft.supplier.bic = "GIBACZPX"
        draft.constantSymbol = "0308"
        draft.discountAmount = 20
        draft.adjustment = Decimal(string: "0.35")!
        draft.adjustmentDescription = "Zaokrouhlení"
        let issued = try IssuedInvoice.issue(draft: draft, number: original.number)
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: issued)))
        let text = try #require(document.string)
        let intro = try #require(text.range(of: draft.note))
        let item = try #require(text.range(of: "UNIKÁTNÍ POLOŽKA"))
        let terms = try #require(text.range(of: "SPECIÁLNÍ PODMÍNKY úhrady."))
        let payment = try #require(text.range(of: "PLATEBNÍ ÚDAJE"))
        #expect(intro.lowerBound < item.lowerBound)
        #expect(item.lowerBound < terms.lowerBound)
        #expect(terms.lowerBound < payment.lowerBound)
        #expect(!text.contains("POZNÁMKA"))
        for field in ["+420 777 000 111", "https://example.test", "BIC/SWIFT: GIBACZPX", "Konstantní symbol: 0308", "Celkem před slevou", "Zaokrouhlení"] {
            #expect(text.contains(field))
        }
        let compact = text.filter { !$0.isWhitespace }
        #expect(compact.contains("Celkempředslevou100,00Kč"))
        #expect(compact.contains("Sleva-20,00Kč"))
        #expect(compact.contains("80,35Kč"))
    }

    @Test(arguments: [Optional<String>.none, Optional("")])
    func missingLegacyTermsUseDefaultButExplicitEmptyRemainsEmpty(terms: String?) throws {
        let issued = try invoice(lines: [InvoiceLine(description: "Služba", quantity: 1, unitPrice: 100)], note: "", paymentTerms: terms)
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: issued)))
        let text = try #require(document.string)
        #expect(text.contains("Fakturuji Vám za dodané zboží či služby:"))
        let compact = text.filter { !$0.isWhitespace }
        #expect(compact.contains(InvoiceTextDefaults.paymentTerms.filter { !$0.isWhitespace }) == (terms == nil))
        #expect(text.contains("PLATEBNÍ PODMÍNKY") == (terms == nil))
        #expect(!text.contains("Celkem před slevou"))
    }


    @Test func longPaymentTermsPreserveEveryLineAcrossPages() throws {
        let lines = (1...140).map { String(format: "Podmínka %03d: Předání služby potvrzeno zákazníkem.", $0) }
        let issued = try invoice(lines: [InvoiceLine(description: "Služba", quantity: 1, unitPrice: 100)],
                                 paymentTerms: lines.joined(separator: "\n"))
        let document = try #require(PDFDocument(data: InvoicePDFRenderer.render(invoice: issued)))
        let text = try #require(document.string)
        #expect(document.pageCount >= 3)
        for line in lines { #expect(text.contains(line)) }
        #expect(text.components(separatedBy: lines.last!).count == 2)
    }

}
