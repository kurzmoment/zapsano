import Foundation
import Testing
@testable import FakturaCore

private func sampleDraft() throws -> InvoiceDraft {
    try InvoiceDraft(supplier: Party(name: "Dodavatel", registrationNumber: "12345678", address: "Praha 1"),
                     customer: Party(name: "Odběratel", address: "Brno 1"),
                     lines: [InvoiceLine(description: "Práce", quantity: 3, unitPrice: DecimalInput.parse("0,335"))],
                     issueDate: CalendarDate(year: 2026, month: 10, day: 30),
                     dueDate: CalendarDate(year: 2026, month: 11, day: 13))
}

@Test func contactAndPaymentFieldsRoundtripAndStayInIssuedSnapshot() throws {
    var draft = try sampleDraft()
    #expect(draft.paymentTerms == InvoiceTextDefaults.paymentTerms)
    #expect(draft.constantSymbol == "0308")
    draft.supplier.phone = "+420 123 456 789"
    draft.supplier.website = "https://example.test"
    draft.supplier.bic = "GIBACZPX"
    draft.customer.phone = "+420 987 654 321"
    draft.note = "Fakturujeme vývoj za říjen."
    draft.paymentTerms = "Dohodnuté platební podmínky."
    draft.constantSymbol = "0008"
    let restoredDraft = try JSONDecoder().decode(InvoiceDraft.self, from: JSONEncoder().encode(draft))
    #expect(restoredDraft == draft)
    let issued = try IssuedInvoice.issue(draft: draft, number: "2026-12")
    let restored = try JSONDecoder().decode(IssuedInvoice.self, from: JSONEncoder().encode(issued))
    #expect(restored == issued)
    var expectedEdit = draft
    expectedEdit.requestedNumber = issued.number
    expectedEdit.variableSymbol = issued.variableSymbol
    #expect(restored.editableDraft() == expectedEdit)
    draft.supplier.phone = nil
    draft.paymentTerms = "Nové podmínky"
    #expect(issued.supplier.phone == "+420 123 456 789")
    #expect(issued.paymentTerms == "Dohodnuté platební podmínky.")
    #expect(issued.note == "Fakturujeme vývoj za říjen.")
}

@Test func legacyMissingContactAndPaymentFieldsDecodeToNilAndReissueUnchanged() throws {
    var draft = try sampleDraft()
    draft.lines[0].unitPrice = 100
    func legacyJSON(_ data: Data) throws -> Data {
        var fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields.removeValue(forKey: "paymentTerms")
        fields.removeValue(forKey: "constantSymbol")
        for key in ["supplier", "customer"] {
            var party = try #require(fields[key] as? [String: Any])
            for contact in ["phone", "website", "bic"] { party.removeValue(forKey: contact) }
            fields[key] = party
        }
        return try JSONSerialization.data(withJSONObject: fields)
    }
    let restoredDraft = try JSONDecoder().decode(InvoiceDraft.self, from: legacyJSON(JSONEncoder().encode(draft)))
    #expect(restoredDraft.paymentTerms == nil)
    #expect(restoredDraft.constantSymbol == nil)
    #expect(restoredDraft.supplier.phone == nil)
    #expect(restoredDraft.supplier.website == nil)
    #expect(restoredDraft.supplier.bic == nil)
    let issued = try IssuedInvoice.issue(draft: draft, number: "2026-12")
    let legacy = try JSONDecoder().decode(IssuedInvoice.self, from: legacyJSON(JSONEncoder().encode(issued)))
    #expect(legacy.paymentTerms == nil)
    #expect(legacy.constantSymbol == nil)
    #expect(legacy.editableDraft().paymentTerms == nil)
    #expect(legacy.editableDraft().constantSymbol == nil)
    #expect(try IssuedInvoice.issue(draft: legacy.editableDraft(), number: legacy.number) == legacy)
}

@Test func deliberatelyEmptyPaymentTermsAndConstantSymbolStayEmpty() throws {
    var draft = try sampleDraft()
    draft.paymentTerms = ""
    draft.constantSymbol = ""
    let invoice = try IssuedInvoice.issue(draft: draft, number: "2026-12")
    let restored = try JSONDecoder().decode(IssuedInvoice.self, from: JSONEncoder().encode(invoice))
    #expect(restored.paymentTerms == "")
    #expect(restored.constantSymbol == "")
    #expect(restored.editableDraft().paymentTerms == "")
    #expect(restored.editableDraft().constantSymbol == "")
}

@Test func catalogItemValidationPreservesExactRateAndEmptyUnit() throws {
    let item = try CatalogItem(description: "  Konzultace  ", unit: "", unitPrice: Decimal(string: "123.4567")!).validated()
    #expect(item.description == "Konzultace")
    #expect(item.unit.isEmpty)
    #expect(item.unitPrice == Decimal(string: "123.4567"))
    #expect(try JSONDecoder().decode(CatalogItem.self, from: JSONEncoder().encode(item)) == item)
    for item in [CatalogItem(description: " ", unit: "hod", unitPrice: 1),
                 CatalogItem(description: "Práce", unit: "hod", unitPrice: -1),
                 CatalogItem(description: "Práce", unit: "hod", unitPrice: .nan)] {
        #expect(throws: BillingError.invalidCatalogItem) { try item.validated() }
    }
}

@Test func ibanNormalizesAndRejectsInvalidStructureOrChecksum() throws {
    #expect(try BankAccountDetails.normalizedIBAN(" cz65 0800 0000 1920 0014 5399 ") == "CZ6508000000192000145399")
    #expect(try BankAccountDetails.normalizedIBAN("GB82 WEST 1234 5698 7654 32") == "GB82WEST12345698765432")
    #expect(try BankAccountDetails.normalizedIBAN(" \n\t") == nil)
    for invalid in ["CZ6508000000192000145398", "CZ650800000019200014539", "CZ65080000001920001453999",
                    "CZ65-0800-0000192000145399", "CZAB08000000192000145399", "CZ650800000019200014539Ž",
                    "CZ650800000019200014539A", "GB00WEST12345698765432", String(repeating: "A", count: 35)] {
        #expect(throws: BillingError.invalidIBAN) { try BankAccountDetails.normalizedIBAN(invalid) }
    }
}

@Test func domesticAccountConversionUsesBothChecksumsAndKnownExamples() throws {
    #expect(try BankAccountDetails.czechIBAN(from: "19-2000145399 / 0800") == "CZ6508000000192000145399")
    #expect(try BankAccountDetails.czechIBAN(from: "000019-2000145399/0800") == "CZ6508000000192000145399")
    #expect(try BankAccountDetails.czechIBAN(from: "1265098001/5500") == "CZ5855000000001265098001")
    #expect(try BankAccountDetails.czechIBAN(from: "123/0600") == "CZ9106000000000000000123")
    for invalid in ["18-2000145399/0800", "19-2000145398/0800", "0000000000/0800", "8/0800",
                    "1234567-123/0600", "12345678901/0600", "123/600", "123/0600*AM:1", "１２３/0600"] {
        #expect(throws: BillingError.invalidDomesticAccount) { try BankAccountDetails.czechIBAN(from: invalid) }
    }
}

@Test func qrPaymentUsesExactSnapshotAmountAndPreservesLeadingSymbolZeroes() throws {
    var draft = try sampleDraft()
    draft.supplier.bankAccount = "19-2000145399/0800"
    draft.variableSymbol = "000123"
    draft.lines = [InvoiceLine(description: "Služba", unitPrice: 100)]
    draft.discountAmount = 10
    draft.adjustment = Decimal(string: "0.25")!
    draft.adjustmentDescription = "Zaokrouhlení"
    let invoice = try IssuedInvoice.issue(draft: draft, number: "2026-12")
    #expect(try QRPayment.payload(invoice: invoice) == "SPD*1.0*ACC:CZ6508000000192000145399*AM:90.25*CC:CZK*X-VS:000123*X-KS:0308")
    draft.supplier.iban = "CZ6508000000192000145399"
    #expect(try QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "2026-12")) == QRPayment.payload(invoice: invoice))
    draft.supplier.bankAccount = ""
    draft.variableSymbol = ""
    draft.discountAmount = nil
    draft.adjustment = nil
    draft.adjustmentDescription = nil
    #expect(try QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "FV")) == "SPD*1.0*ACC:CZ6508000000192000145399*AM:100.00*CC:CZK*X-KS:0308")
}

@Test func qrConstantSymbolPreservesZeroesOmitsAbsentAndRejectsInvalidValues() throws {
    var draft = try sampleDraft()
    draft.supplier.bankAccount = "123/0600"
    draft.constantSymbol = " 0000000308 "
    #expect(try QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "1")).hasSuffix("*X-KS:0000000308"))
    for absent: String? in [nil, "", " "] {
        draft.constantSymbol = absent
        #expect(try !QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "1")).contains("X-KS:"))
    }
    for invalid in ["12345678901", "0308*AM:1", "A308", "０３０８", "03 08"] {
        draft.constantSymbol = invalid
        #expect(throws: BillingError.invalidQRConstantSymbol) { try QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "1")) }
    }
}

@Test func qrPaymentRejectsMissingConflictingAccountsAndInvalidSymbols() throws {
    var draft = try sampleDraft()
    #expect(throws: BillingError.missingPaymentAccount) { try QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "1")) }
    draft.supplier.iban = "CZ6508000000192000145399"
    draft.supplier.bankAccount = "123/0600"
    #expect(throws: BillingError.mismatchedPaymentAccounts) { try QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "1")) }
    draft.supplier.iban = "GB82WEST12345698765432"
    #expect(throws: BillingError.mismatchedPaymentAccounts) { try QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "1")) }
    draft.supplier.bankAccount = "bad"
    #expect(throws: BillingError.invalidDomesticAccount) { try QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "1")) }
    draft.supplier.bankAccount = ""
    for symbol in ["12345678901", "123*AM:1", "ABC", "１２３", "1 23"] {
        draft.variableSymbol = symbol
        #expect(throws: BillingError.invalidQRVariableSymbol) { try QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "1")) }
    }
}

@Test func qrPaymentEnforcesOfficialAmountLimitWithoutRoundingOrScientificNotation() throws {
    var draft = try sampleDraft()
    draft.supplier.bankAccount = "123/0600"
    for amount in [Decimal(string: "0.01")!, Decimal(string: "9999999.99")!] {
        draft.lines = [InvoiceLine(description: "Služba", unitPrice: amount)]
        let payload = try QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "1"))
        #expect(payload.contains("AM:\(NSDecimalNumber(decimal: amount).stringValue)*CC:CZK"))
    }
    for amount in [Decimal.zero, Decimal(10_000_000)] {
        draft.lines = [InvoiceLine(description: "Služba", unitPrice: amount)]
        #expect(throws: BillingError.invalidQRAmount) { try QRPayment.payload(invoice: IssuedInvoice.issue(draft: draft, number: "1")) }
    }
}

@Test func ibanSnapshotAndLegacyPartyDecoding() throws {
    var draft = try sampleDraft()
    draft.lines[0].unitPrice = 100
    let original = try IssuedInvoice.issue(draft: draft, number: "2026-12")
    var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    for key in ["supplier", "customer"] {
        var party = try #require(fields[key] as? [String: Any])
        party.removeValue(forKey: "iban")
        fields[key] = party
    }
    let legacy = try JSONDecoder().decode(IssuedInvoice.self, from: JSONSerialization.data(withJSONObject: fields))
    #expect(legacy == original)
    #expect(legacy.supplier.iban == nil)
    draft.supplier.iban = "cz65 0800 0000 1920 0014 5399"
    let invoice = try IssuedInvoice.issue(draft: draft, number: "2026-13")
    #expect(invoice.supplier.iban == "CZ6508000000192000145399")
    draft.supplier.iban = nil
    #expect(invoice.supplier.iban != draft.supplier.iban)
    #expect(try JSONDecoder().decode(IssuedInvoice.self, from: JSONEncoder().encode(invoice)) == invoice)
    draft.supplier.iban = "CZ6508000000192000145398"
    #expect(throws: BillingError.invalidIBAN) { try IssuedInvoice.issue(draft: draft, number: "2026-14") }
}

@Test func editableDraftPreservesEverySnapshotAndAmountField() throws {
    var draft = try sampleDraft()
    draft.supplier.iban = "CZ6508000000192000145399"
    draft.lines[0].unitPrice = 100
    draft.note = "Poznámka"
    draft.variableSymbol = "123456"
    draft.discountAmount = 10
    draft.adjustment = Decimal(string: "0.25")!
    draft.adjustmentDescription = "Zaokrouhlení"
    let invoice = try IssuedInvoice.issue(draft: draft, number: "VLASTNI/42")
    let editable = invoice.editableDraft()
    draft.requestedNumber = invoice.number
    #expect(editable == draft)
    #expect(try IssuedInvoice.issue(draft: editable, number: invoice.number) == invoice)
}

@Test func issuanceRequiresCompletePartiesButAllowsIndividualCustomer() throws {
    var draft = try sampleDraft()
    #expect(draft.customer.registrationNumber.isEmpty)
    _ = try IssuedInvoice.issue(draft: draft, number: "2026-12")
    draft.customer.address = " \n "
    #expect(throws: BillingError.missingPartyAddress) { try IssuedInvoice.issue(draft: draft, number: "2026-12") }
    draft.customer.address = "Brno"
    draft.supplier.registrationNumber = " "
    #expect(throws: BillingError.missingSupplierRegistration) { try IssuedInvoice.issue(draft: draft, number: "2026-12") }
}

@Test func arithmeticOverflowAndFractionalPaymentRejected() throws {
    #expect(throws: BillingError.invalidLine) {
        try BillingMath.lineTotal(quantity: Decimal.greatestFiniteMagnitude, unitPrice: 2)
    }
    let invoice = try IssuedInvoice.issue(draft: sampleDraft(), number: "2026-12")
    let payment = Payment(invoiceID: invoice.id, date: invoice.dueDate, amount: Decimal(string: "0.001")!)
    #expect(throws: BillingError.invalidPayment) { try invoice.validatePayment(payment, existing: []) }
}

@Test func strictCzechInput() throws {
    #expect(try DecimalInput.parse(" 1234,56 ") == Decimal(string: "1234.56")!)
    for invalid in ["", "1.25", "1,2,3", "1 000", "1e2", "NaN", "1,", ",5"] {
        #expect(throws: BillingError.invalidDecimal) { try DecimalInput.parse(invalid) }
    }
}

@Test func roundingAndInvalidLines() throws {
    let draft = try sampleDraft()
    #expect(try draft.total() == Decimal(string: "1.01")!)
    #expect(throws: BillingError.invalidLine) { try BillingMath.lineTotal(quantity: 0, unitPrice: 10) }
    #expect(throws: BillingError.invalidLine) { try BillingMath.lineTotal(quantity: 1, unitPrice: -1) }
    #expect(throws: BillingError.invalidLine) { try BillingMath.lineTotal(quantity: .nan, unitPrice: 1) }
}

@Test func snapshotAndJSONRoundTrip() throws {
    var draft = try sampleDraft()
    draft.lines[0].unitPrice = try DecimalInput.parse("12345678901234567890,12345678")
    let invoice = try IssuedInvoice.issue(draft: draft, number: "2026-12")
    draft.customer.name = "Změněný klient"
    draft.lines[0].unitPrice = 0
    #expect(invoice.customer.name == "Odběratel")
    #expect(invoice.lines[0].unitPrice != 0)
    #expect(invoice.variableSymbol == "202612")
    let encoded = try JSONEncoder().encode(invoice)
    #expect(try JSONDecoder().decode(IssuedInvoice.self, from: encoded) == invoice)
    #expect(invoice.lineTotals == [invoice.total])
}

@Test func paymentsReversalAndOverdue() throws {
    let invoice = try IssuedInvoice.issue(draft: sampleDraft(), number: "2026-12")
    var payment = Payment(invoiceID: invoice.id, date: invoice.dueDate, amount: 1)
    try invoice.validatePayment(payment, existing: [])
    #expect(try invoice.outstanding(payments: [payment]) == Decimal(string: "0.01")!)
    #expect(throws: BillingError.duplicatePayment) { try invoice.validatePayment(payment, existing: [payment]) }
    let tooMuch = Payment(invoiceID: invoice.id, date: invoice.dueDate, amount: 2)
    #expect(throws: BillingError.overpayment) { try invoice.validatePayment(tooMuch, existing: []) }
    #expect(try !invoice.isOverdue(on: invoice.dueDate, payments: []))
    #expect(try invoice.isOverdue(on: CalendarDate(year: 2026, month: 11, day: 14), payments: [payment]))
    payment.reverse(at: Date(timeIntervalSince1970: 100))
    payment.reverse(at: Date(timeIntervalSince1970: 200))
    #expect(payment.reversedAt == Date(timeIntervalSince1970: 100))
    #expect(payment.amount == 1)
    #expect(try invoice.outstanding(payments: [payment]) == invoice.total)
}

@Test func calendarValidationAndRoundTrip() throws {
    #expect(throws: BillingError.invalidDate) { try CalendarDate(year: 2026, month: 2, day: 29) }
    let leapDay = try CalendarDate(year: 2028, month: 2, day: 29)
    #expect(try JSONDecoder().decode(CalendarDate.self, from: JSONEncoder().encode(leapDay)) == leapDay)
    #expect(throws: BillingError.invalidDate) {
        try JSONDecoder().decode(CalendarDate.self, from: Data(#"{"year":2026,"month":2,"day":30}"#.utf8))
    }
}

@Test func confirmedHistoricalPaymentKeepsUnknownDateAndSettlesBalance() throws {
    let invoice = try IssuedInvoice.issue(draft: sampleDraft(), number: "2026-12")
    var payment = Payment(invoiceID: invoice.id, date: nil, amount: invoice.total, note: "Historická úhrada potvrzená uživatelem; datum neznámé.")
    try invoice.validatePayment(payment, existing: [])
    let restored = try JSONDecoder().decode(Payment.self, from: JSONEncoder().encode(payment))
    #expect(restored.date == nil)
    #expect(restored == payment)
    #expect(try invoice.outstanding(payments: [restored]) == .zero)
    #expect(try !invoice.isOverdue(on: CalendarDate(year: 2026, month: 11, day: 14), payments: [restored]))
    payment.reverse()
    #expect(try invoice.outstanding(payments: [payment]) == invoice.total)
    let dated = Payment(invoiceID: invoice.id, date: invoice.dueDate, amount: invoice.total)
    #expect(try JSONDecoder().decode(Payment.self, from: JSONEncoder().encode(dated)).date == invoice.dueDate)
}

@Test func discountAndPositiveRoundingRemainIndependentAfterDraftRoundtripAndEdit() throws {
    var draft = try sampleDraft()
    draft.lines = [InvoiceLine(description: "Služba", quantity: 1, unitPrice: 100)]
    draft.adjustment = Decimal(string: "0.35")!
    draft.adjustmentDescription = "Zaokrouhlení"
    draft.discountAmount = Decimal(string: "0.20")!
    #expect(try draft.total() == Decimal(string: "100.15"))
    var restored = try JSONDecoder().decode(InvoiceDraft.self, from: JSONEncoder().encode(draft))
    #expect(restored == draft)
    restored.discountAmount = Decimal(string: "0.30")!
    #expect(restored.adjustment == Decimal(string: "0.35"))
    #expect(try restored.total() == Decimal(string: "100.05"))
    let invoice = try IssuedInvoice.issue(draft: restored, number: "2026-12")
    #expect(invoice.discountAmount == Decimal(string: "0.30"))
    #expect(invoice.adjustment == Decimal(string: "0.35"))
    #expect(try JSONDecoder().decode(IssuedInvoice.self, from: JSONEncoder().encode(invoice)) == invoice)
    for invalid in [Decimal(-1), Decimal(string: "0.001")!, Decimal(101), Decimal.nan] {
        restored.discountAmount = invalid
        #expect(throws: BillingError.self) { try restored.total() }
    }
}

@Test func legacyCombinedAdjustmentWithoutDiscountFieldKeepsOriginalAmount() throws {
    var draft = try sampleDraft()
    draft.lines = [InvoiceLine(description: "Služba", quantity: 1, unitPrice: 100)]
    draft.adjustment = Decimal(string: "-1.25")!
    draft.adjustmentDescription = "Sleva + zaokrouhlení dle původní faktury"
    let invoice = try IssuedInvoice.issue(draft: draft, number: "2026-12")
    var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(invoice)) as? [String: Any])
    fields.removeValue(forKey: "discountAmount")
    let restored = try JSONDecoder().decode(IssuedInvoice.self, from: JSONSerialization.data(withJSONObject: fields))
    #expect(restored == invoice)
    #expect(restored.discountAmount == nil)
    #expect(restored.total == Decimal(string: "98.75"))
}
