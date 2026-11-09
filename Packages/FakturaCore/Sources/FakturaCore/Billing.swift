import Foundation

public enum BillingError: Error, Equatable, LocalizedError {
    case invalidDecimal, invalidDate, missingParty, missingPartyAddress, missingSupplierRegistration, missingNumber, emptyLines
    case invalidLine, invalidPayment, duplicatePayment, overpayment, invalidDueDate, invalidAdjustment, invalidDiscount, invalidIBAN
    case invalidDomesticAccount, missingPaymentAccount, mismatchedPaymentAccounts, invalidQRAmount, invalidQRVariableSymbol, invalidQRConstantSymbol
    case invalidCatalogItem

    public var errorDescription: String? {
        switch self {
        case .invalidDecimal: "Zadejte platné číslo, například 1250,50."
        case .invalidDate: "Datum není platné."
        case .missingParty: "Vyplňte název dodavatele i odběratele."
        case .missingPartyAddress: "Vyplňte adresu dodavatele i odběratele."
        case .missingSupplierRegistration: "Vyplňte IČO dodavatele v nastavení firmy."
        case .missingNumber: "Vyplňte číslo faktury."
        case .emptyLines: "Faktura musí mít alespoň jednu položku."
        case .invalidLine: "Položka vyžaduje popis, kladné množství a nezápornou cenu."
        case .invalidPayment: "Úhrada musí mít kladnou částku s nejvýše dvěma desetinnými místy."
        case .duplicatePayment: "Tato úhrada už byla zapsána."
        case .overpayment: "Úhrada převyšuje zbývající částku faktury."
        case .invalidDueDate: "Splatnost nesmí předcházet datu vystavení."
        case .invalidAdjustment: "Úprava částky musí mít popis, nejvýše dvě desetinná místa a nesmí vytvořit záporný součet."
        case .invalidDiscount: "Sleva musí být nezáporná částka s nejvýše dvěma desetinnými místy a nesmí převýšit celkovou částku."
        case .invalidIBAN: "IBAN nemá platný formát nebo kontrolní součet. Zkontrolujte ho podle údajů banky."
        case .invalidDomesticAccount: "České číslo účtu nemá platný formát nebo kontrolní součet. Použijte číslo účtu/kód banky, případně předčíslí-číslo účtu/kód banky."
        case .missingPaymentAccount: "Pro QR platbu vyplňte bankovní účet nebo IBAN dodavatele."
        case .mismatchedPaymentAccounts: "Bankovní účet a IBAN označují různé účty. Před vytvořením QR platby údaje sjednoťte."
        case .invalidQRAmount: "QR platba vyžaduje kladnou částku v CZK, nejvýše 9 999 999,99 Kč a dvě desetinná místa."
        case .invalidQRVariableSymbol: "Variabilní symbol pro QR platbu musí obsahovat nejvýše 10 číslic."
        case .invalidQRConstantSymbol: "Konstantní symbol pro QR platbu musí obsahovat nejvýše 10 číslic."
        case .invalidCatalogItem: "Ceníková položka vyžaduje popis a nezápornou jednotkovou cenu."
        }
    }
}

public enum BankAccountDetails {
    /// Checks structure and MOD 97, not whether an account exists or who owns it.
    /// CNB format reference: https://www.cnb.cz/cs/platebni-styk/iban/iban-mezinarodni-format-cisla-uctu/
    public static func normalizedIBAN(_ text: String) throws -> String? {
        let iban = text.filter { !$0.isWhitespace }.uppercased()
        guard !iban.isEmpty else { return nil }
        guard iban.range(of: #"^[A-Z]{2}[0-9]{2}[A-Z0-9]{1,30}$"#, options: .regularExpression) != nil else {
            throw BillingError.invalidIBAN
        }
        let bytes = Array(iban.utf8)
        let checkDigits = Int(bytes[2] - 48) * 10 + Int(bytes[3] - 48)
        guard (2...98).contains(checkDigits) else { throw BillingError.invalidIBAN }
        if iban.hasPrefix("CZ") {
            guard bytes.count == 24, bytes.dropFirst(4).allSatisfy({ (48...57).contains($0) }) else {
                throw BillingError.invalidIBAN
            }
        }
        guard modulo97(Array(bytes.dropFirst(4) + bytes.prefix(4))) == 1 else { throw BillingError.invalidIBAN }
        return iban
    }

    /// Validates the Czech domestic account structure and both MOD 11 checksums.
    /// Does not check the existence of the bank/account or the identity of its owner.
    public static func czechIBAN(from account: String) throws -> String {
        let text = account.filter { !$0.isWhitespace }
        guard text.range(of: #"^(?:[0-9]{1,6}-)?[0-9]{2,10}/[0-9]{4}$"#, options: .regularExpression) != nil else {
            throw BillingError.invalidDomesticAccount
        }
        let parts = text.split(separator: "/")
        let accountParts = parts[0].split(separator: "-")
        let prefix = accountParts.count == 2 ? String(accountParts[0]) : ""
        let base = String(accountParts.last!)
        let bank = String(parts[1])
        guard base.filter({ $0 != "0" }).count >= 2,
              domesticChecksum(prefix), domesticChecksum(base) else { throw BillingError.invalidDomesticAccount }
        let bban = bank + String(repeating: "0", count: 6 - prefix.count) + prefix
            + String(repeating: "0", count: 10 - base.count) + base
        let checkDigits = 98 - modulo97(Array((bban + "CZ00").utf8))
        let result = "CZ" + String(format: "%02d", checkDigits) + bban
        guard let iban = try normalizedIBAN(result) else { throw BillingError.invalidDomesticAccount }
        return iban
    }

    private static func domesticChecksum(_ part: String) -> Bool {
        // Powers of two modulo eleven, assigned from the right (CNB decree 169/2011 appendix).
        let weights = [1, 2, 4, 8, 5, 10, 9, 7, 3, 6]
        return zip(part.utf8.reversed(), weights).reduce(0) { $0 + Int($1.0 - 48) * $1.1 } % 11 == 0
    }

    private static func modulo97(_ bytes: [UInt8]) -> Int {
        var remainder = 0
        for byte in bytes {
            if (48...57).contains(byte) {
                remainder = (remainder * 10 + Int(byte - 48)) % 97
            } else {
                remainder = (remainder * 100 + Int(byte - 65) + 10) % 97
            }
        }
        return remainder
    }
}

public enum QRPayment {
    /// SPAYD 1.0 for the issued invoice's full amount, independent of later payments.
    /// https://qr-platba.cz/pro-vyvojare/specifikace-formatu/
    public static func payload(invoice: IssuedInvoice) throws -> String {
        guard invoice.currency == "CZK", !invoice.total.isNaN, invoice.total > 0,
              invoice.total <= Decimal(string: "9999999.99")!, BillingMath.rounded(invoice.total) == invoice.total else {
            throw BillingError.invalidQRAmount
        }
        let symbol = try normalizedSymbol(invoice.variableSymbol, failure: .invalidQRVariableSymbol)
        let constantSymbol = try normalizedSymbol(invoice.constantSymbol, failure: .invalidQRConstantSymbol)
        let explicitIBAN = try BankAccountDetails.normalizedIBAN(invoice.supplier.iban ?? "")
        let domestic = invoice.supplier.bankAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedIBAN = domestic.isEmpty ? nil : try BankAccountDetails.czechIBAN(from: domestic)
        if let explicitIBAN, let derivedIBAN, explicitIBAN != derivedIBAN { throw BillingError.mismatchedPaymentAccounts }
        guard let iban = explicitIBAN ?? derivedIBAN else { throw BillingError.missingPaymentAccount }
        let amountParts = NSDecimalNumber(decimal: invoice.total).stringValue.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = amountParts.count == 2 ? String(amountParts[1]) : ""
        let amount = String(amountParts[0]) + "." + fraction + String(repeating: "0", count: 2 - fraction.count)
        var fields = ["SPD", "1.0", "ACC:\(iban)", "AM:\(amount)", "CC:CZK"]
        if !symbol.isEmpty { fields.append("X-VS:\(symbol)") }
        if !constantSymbol.isEmpty { fields.append("X-KS:\(constantSymbol)") }
        return fields.joined(separator: "*")
    }

    private static func normalizedSymbol(_ input: String?, failure: BillingError) throws -> String {
        let value = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || value.range(of: #"^[0-9]{1,10}$"#, options: .regularExpression) != nil else { throw failure }
        return value
    }
}

public enum DecimalInput {
    /// Accepts an ungrouped Czech decimal number; never guesses thousands separators.
    public static func parse(_ input: String) throws -> Decimal {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^[+-]?[0-9]+(?:,[0-9]+)?$"#, options: .regularExpression) != nil,
              text.filter({ $0.isNumber }).count <= 28,
              let value = Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN else { throw BillingError.invalidDecimal }
        return value
    }
}

public enum BillingMath {
    public static func rounded(_ value: Decimal) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, 2, .plain)
        return result
    }

    public static func lineTotal(quantity: Decimal, unitPrice: Decimal) throws -> Decimal {
        guard !quantity.isNaN, !unitPrice.isNaN, quantity > 0, unitPrice >= 0 else {
            throw BillingError.invalidLine
        }
        var left = quantity
        var right = unitPrice
        var product = Decimal()
        guard NSDecimalMultiply(&product, &left, &right, .plain) == .noError else {
            throw BillingError.invalidLine
        }
        return rounded(product)
    }

    static func sum(_ values: [Decimal]) throws -> Decimal {
        var total = Decimal.zero
        for var value in values {
            var next = Decimal()
            guard NSDecimalAdd(&next, &total, &value, .plain) == .noError else {
                throw BillingError.invalidDecimal
            }
            total = next
        }
        return total
    }
}

public struct CalendarDate: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard (1...9999).contains(year), let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else {
            throw BillingError.invalidDate
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public init(date: Date, calendar: Calendar = .current) throws {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        try self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private enum CodingKeys: String, CodingKey { case year, month, day }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(year: container.decode(Int.self, forKey: .year),
                      month: container.decode(Int.self, forKey: .month),
                      day: container.decode(Int.self, forKey: .day))
    }
}

public struct Party: Codable, Equatable, Sendable {
    public var name: String
    public var registrationNumber: String
    public var taxNumber: String
    public var address: String
    public var email: String
    public var bankAccount: String
    public var iban: String?
    public var phone: String?
    public var website: String?
    public var bic: String?

    public init(name: String = "", registrationNumber: String = "", taxNumber: String = "", address: String = "", email: String = "", bankAccount: String = "", iban: String? = nil, phone: String? = nil, website: String? = nil, bic: String? = nil) {
        self.name = name
        self.registrationNumber = registrationNumber
        self.taxNumber = taxNumber
        self.address = address
        self.email = email
        self.bankAccount = bankAccount
        self.iban = iban
        self.phone = phone
        self.website = website
        self.bic = bic
    }
}

public struct CatalogItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var description: String
    public var unit: String
    public var unitPrice: Decimal

    public init(id: UUID = UUID(), description: String, unit: String, unitPrice: Decimal) {
        self.id = id
        self.description = description
        self.unit = unit
        self.unitPrice = unitPrice
    }

    public func validated() throws -> Self {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, !unitPrice.isNaN, unitPrice >= 0 else { throw BillingError.invalidCatalogItem }
        return Self(id: id, description: description, unit: unit.trimmingCharacters(in: .whitespacesAndNewlines), unitPrice: unitPrice)
    }
}

public struct InvoiceLine: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var description: String
    public var quantity: Decimal
    public var unit: String
    public var unitPrice: Decimal

    public init(id: UUID = UUID(), description: String = "", quantity: Decimal = 1, unit: String = "ks", unitPrice: Decimal = 0) {
        self.id = id
        self.description = description
        self.quantity = quantity
        self.unit = unit
        self.unitPrice = unitPrice
    }

    public func total() throws -> Decimal {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BillingError.invalidLine
        }
        return try BillingMath.lineTotal(quantity: quantity, unitPrice: unitPrice)
    }
}

public enum InvoiceTextDefaults {
    public static let paymentTerms = "Dovolujeme si Vás upozornit, že v případě nedodržení data splatnosti uvedeného na faktuře Vám můžeme účtovat zákonný úrok z prodlení."
}

public struct InvoiceDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var supplier: Party
    public var customer: Party
    public var lines: [InvoiceLine]
    public var issueDate: CalendarDate
    public var dueDate: CalendarDate
    public var note: String
    public var variableSymbol: String
    public var adjustment: Decimal?
    public var adjustmentDescription: String?
    public var requestedNumber: String?
    public var discountAmount: Decimal?
    public var paymentTerms: String?
    public var constantSymbol: String?

    public init(id: UUID = UUID(), supplier: Party, customer: Party, lines: [InvoiceLine], issueDate: CalendarDate, dueDate: CalendarDate, note: String = "", variableSymbol: String = "", adjustment: Decimal? = nil, adjustmentDescription: String? = nil, requestedNumber: String? = nil, discountAmount: Decimal? = nil, paymentTerms: String? = InvoiceTextDefaults.paymentTerms, constantSymbol: String? = "0308") {
        self.id = id
        self.supplier = supplier
        self.customer = customer
        self.lines = lines
        self.issueDate = issueDate
        self.dueDate = dueDate
        self.note = note
        self.variableSymbol = variableSymbol
        self.adjustment = adjustment
        self.adjustmentDescription = adjustmentDescription
        self.requestedNumber = requestedNumber
        self.discountAmount = discountAmount
        self.paymentTerms = paymentTerms
        self.constantSymbol = constantSymbol
    }

    public func total() throws -> Decimal {
        if let adjustment {
            guard !adjustment.isNaN, BillingMath.rounded(adjustment) == adjustment,
                  !(adjustmentDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BillingError.invalidAdjustment
            }
        }
        if let discountAmount {
            guard !discountAmount.isNaN, discountAmount >= 0, BillingMath.rounded(discountAmount) == discountAmount else {
                throw BillingError.invalidDiscount
            }
        }
        let total = try BillingMath.sum(lines.map { try $0.total() } + [adjustment ?? .zero, -(discountAmount ?? .zero)])
        guard total >= 0 else { throw discountAmount == nil ? BillingError.invalidAdjustment : BillingError.invalidDiscount }
        return total
    }
}

public struct IssuedInvoice: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let number: String
    public let supplier: Party
    public let customer: Party
    public let lines: [InvoiceLine]
    public let lineTotals: [Decimal]
    public let issueDate: CalendarDate
    public let dueDate: CalendarDate
    public let note: String
    public let variableSymbol: String
    public let total: Decimal
    public let currency: String
    public let calculationVersion: Int
    public let adjustment: Decimal?
    public let adjustmentDescription: String?
    public let discountAmount: Decimal?
    public let paymentTerms: String?
    public let constantSymbol: String?

    public static func issue(draft: InvoiceDraft, number: String) throws -> Self {
        guard !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BillingError.missingNumber }
        guard !draft.supplier.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.customer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BillingError.missingParty }
        guard !draft.supplier.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.customer.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BillingError.missingPartyAddress }
        guard !draft.supplier.registrationNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BillingError.missingSupplierRegistration
        }
        guard !draft.lines.isEmpty else { throw BillingError.emptyLines }
        guard draft.dueDate >= draft.issueDate else { throw BillingError.invalidDueDate }
        var supplier = draft.supplier
        var customer = draft.customer
        supplier.iban = try BankAccountDetails.normalizedIBAN(supplier.iban ?? "")
        customer.iban = try BankAccountDetails.normalizedIBAN(customer.iban ?? "")
        return try Self(id: draft.id, number: number, supplier: supplier, customer: customer,
                        lines: draft.lines, lineTotals: draft.lines.map { try $0.total() }, issueDate: draft.issueDate, dueDate: draft.dueDate,
                        note: draft.note, variableSymbol: draft.variableSymbol.isEmpty ? number.filter(\.isNumber) : draft.variableSymbol,
                        total: draft.total(), currency: "CZK", calculationVersion: 1,
                        adjustment: draft.adjustment, adjustmentDescription: draft.adjustmentDescription,
                        discountAmount: draft.discountAmount, paymentTerms: draft.paymentTerms, constantSymbol: draft.constantSymbol)
    }

    public func editableDraft() -> InvoiceDraft {
        InvoiceDraft(id: id, supplier: supplier, customer: customer, lines: lines,
                     issueDate: issueDate, dueDate: dueDate, note: note, variableSymbol: variableSymbol,
                     adjustment: adjustment, adjustmentDescription: adjustmentDescription,
                     requestedNumber: number, discountAmount: discountAmount, paymentTerms: paymentTerms, constantSymbol: constantSymbol)
    }

    public func outstanding(payments: [Payment]) throws -> Decimal {
        total - (try BillingMath.sum(payments.filter { $0.invoiceID == id && $0.reversedAt == nil }.map(\.amount)))
    }

    public func validatePayment(_ payment: Payment, existing: [Payment]) throws {
        guard payment.invoiceID == id, payment.reversedAt == nil, !payment.amount.isNaN,
              payment.amount > 0, BillingMath.rounded(payment.amount) == payment.amount else { throw BillingError.invalidPayment }
        guard !existing.contains(where: { $0.id == payment.id }) else { throw BillingError.duplicatePayment }
        guard payment.amount <= (try outstanding(payments: existing)) else { throw BillingError.overpayment }
    }

    public func isOverdue(on day: CalendarDate, payments: [Payment]) throws -> Bool {
        try day > dueDate && outstanding(payments: payments) > 0
    }
}

public struct Payment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let invoiceID: UUID
    /// Historical confirmed payments may have an unknown date; never substitute the invoice date.
    public let date: CalendarDate?
    public let amount: Decimal
    public let note: String
    public private(set) var reversedAt: Date?

    public init(id: UUID = UUID(), invoiceID: UUID, date: CalendarDate?, amount: Decimal, note: String = "") {
        self.id = id
        self.invoiceID = invoiceID
        self.date = date
        self.amount = amount
        self.note = note
        self.reversedAt = nil
    }

    public mutating func reverse(at date: Date = Date()) {
        if reversedAt == nil { reversedAt = date }
    }
}
