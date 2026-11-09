import Foundation
import Testing
import FakturaCore
@testable import Faktura

struct InvoicePDFImportTests {
    private func source(rows: String = "hod Návrh aplikace 2,00 625,00\n1 250,00", discount: String = "", total: String = "1 250,00") -> String {
        """
        Dodavatel
        Testovací Dodavatel
        Testovací 1
        100 00 Testov
        Česká republika
        IČ: 12345678
        Nejsme plátci DPH
        Faktura
        2026-12
        Kontaktní údaje
        E-mail: test@example.test
        Odběratel
        Testovací Odběratel s.r.o.
        Ukázková 2
        200 00 Testov
        Česká republika
        IČ: 87654321 DIČ: CZ87654321
        Datum vystavení: 01.10.2026 Datum splatnosti: 15.10.2026
        Bankovní účet Symbol Způsob platby: Převodem
        123456789/0100
        variabilní: 202612
        IBAN: CZ00 0000 0000 0000 0000 0000
        K úhradě
        \(total) Kč
        Fakturujeme Vám za dodané zboží či služby:
        Označení dodávky Počet m. j. Cena za m.j. Celkem
        \(rows)
        Dovolujeme si Vás upozornit na datum splatnosti.
        \(discount)
        Celkem k úhradě: \(total) Kč
        Vystaveno v online fakturační službě iDoklad www.iDoklad.cz Strana 1/1
        """
    }

    private func parse(_ text: String) -> ImportedInvoiceCandidate {
        InvoicePDFImport.parse(text: text, filename: "fixture.pdf", pdfData: Data("fixture".utf8))
    }

    @Test func readsPartiesDatesUnitsAndPreservesOriginalBytes() throws {
        let candidate = parse(source())
        let draft = try #require(candidate.draft)
        #expect(candidate.number == "2026-12")
        #expect(draft.supplier.registrationNumber == "12345678")
        #expect(draft.customer.taxNumber == "CZ87654321")
        #expect(draft.supplier.bankAccount == "123456789/0100")
        #expect(draft.lines[0].unit == "hod")
        #expect(draft.issueDate == (try CalendarDate(year: 2026, month: 10, day: 1)))
        #expect(draft.variableSymbol == "202612")
        #expect(draft.constantSymbol == nil)
        #expect(draft.paymentTerms == nil)
        #expect(try draft.total() == 1250)
        #expect(candidate.pdfData == Data("fixture".utf8))
        #expect(candidate.warnings.contains { $0.contains("úhradu") })
    }

    @Test func exactPrintedDiscountAndNegativeRoundingAreNotRecalculatedFromRate() throws {
        let text = source(
            rows: "hod Návrh aplikace 176,00 625,00\n110 000,00\nZaokrouhlení 1,00 -0,01 -0,01",
            discount: "Celkem před slevou: 110 000,00 Kč\nSleva 0,82 %: -901,99 Kč", total: "109 098,00"
        )
        let draft = try #require(parse(text).draft)
        #expect(draft.lines.count == 1)
        #expect(draft.adjustment == Decimal(string: "-0.01"))
        #expect(draft.discountAmount == Decimal(string: "901.99"))
        #expect(try draft.total() == 109098)
        #expect(draft.adjustmentDescription?.contains("Zaokrouhlení") == true)
    }

    @Test func acceptsLabelsBeforeValuesAndUnitExtractedOnFollowingLine() throws {
        let text = source(rows: "Vývoj 2,00 625,00\nhod 1 250,00",
                          discount: "Celkem před slevou: Sleva 10 %: 1 250,00 Kč\n-125,00 Kč", total: "1 125,00")
        let draft = try #require(parse(text).draft)
        #expect(draft.adjustment == nil)
        #expect(draft.discountAmount == 125)
        #expect(draft.lines[0].unit == "hod")
        #expect(try draft.total() == 1125)
    }

    @Test func acceptsNoUnitAndPositiveRounding() throws {
        let text = source(rows: "Vývoj 1,00 100,25 100,25\nZaokrouhlení 1,00 0,75 0,75", total: "101,00")
        let draft = try #require(parse(text).draft)
        #expect(draft.lines[0].unit.isEmpty)
        #expect(draft.adjustment == Decimal(string: "0.75"))
        #expect(try draft.total() == 101)
    }

    @Test func rejectsTotalMismatchUnknownRowsAndMissingDiscountValue() {
        #expect(parse(source(total: "1 251,00")).draft == nil)
        #expect(parse(source(rows: "Vývoj 2,00 625,00 1 249,00")).draft == nil)
        #expect(parse(source(rows: "Vývoj 2,00 625,00 1 250,00\nNečitelná položka")).draft == nil)
        #expect(parse(source(discount: "Celkem před slevou: 1 250,00 Kč\nSleva 10 %:", total: "1 125,00")).draft == nil)
        #expect(parse(source().replacingOccurrences(of: "Nejsme plátci DPH", with: "Plátce DPH")).draft == nil)
        #expect(parse("Nerozpoznané PDF").draft == nil)
    }

    @Test func adjustmentsRoundtripAndOldSnapshotsWithoutAdjustmentRemainReadable() throws {
        let draft = try #require(parse(source()).draft)
        let issued = try IssuedInvoice.issue(draft: draft, number: "2026-12")
        let encoded = try JSONEncoder().encode(issued)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "adjustment")
        json.removeValue(forKey: "adjustmentDescription")
        json.removeValue(forKey: "discountAmount")
        let decoded = try JSONDecoder().decode(IssuedInvoice.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == issued)
        var discounted = draft
        discounted.adjustment = -125
        discounted.adjustmentDescription = "Sleva"
        let discountedInvoice = try IssuedInvoice.issue(draft: discounted, number: "2026-12")
        #expect(try JSONDecoder().decode(IssuedInvoice.self, from: JSONEncoder().encode(discountedInvoice)) == discountedInvoice)
        #expect(discountedInvoice.total == 1125)
        discounted.adjustment = -1251
        #expect(throws: BillingError.self) { try IssuedInvoice.issue(draft: discounted, number: "2026-12") }
        discounted.adjustment = Decimal(string: "-0.001")
        #expect(throws: BillingError.self) { try discounted.total() }
        var numbered = draft
        numbered.requestedNumber = "CUSTOM-42"
        #expect(try JSONDecoder().decode(InvoiceDraft.self, from: JSONEncoder().encode(numbered)).requestedNumber == "CUSTOM-42")
    }
}
