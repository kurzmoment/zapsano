import Foundation
import PDFKit
import FakturaCore

struct ImportedInvoiceCandidate: Identifiable {
    let id = UUID()
    let filename: String
    let pdfData: Data
    var draft: InvoiceDraft?
    var number: String?
    var declaredTotal: Decimal?
    var supplier: Party?
    var customer: Party?
    var issueDate: CalendarDate?
    var dueDate: CalendarDate?
    var variableSymbol: String?
    var parsedLines: [InvoiceLine] = []
    var warnings: [String] = []
}

/// Deliberately recognises one verified iDoklad layout. Other PDFs remain review-only.
enum InvoicePDFImport {
    static func inspect(url: URL) throws -> ImportedInvoiceCandidate {
        let resource = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resource.isRegularFile == true, (resource.fileSize ?? .max) <= 20_000_000 else {
            throw ImportError.unreadablePDF
        }
        let data = try Data(contentsOf: url)
        guard let document = PDFDocument(data: data), !document.isLocked,
              document.pageCount > 0, document.pageCount <= 100 else { throw ImportError.unreadablePDF }
        guard document.pageCount == 1 else {
            return ImportedInvoiceCandidate(filename: url.lastPathComponent, pdfData: data,
                                            warnings: ["Vícestránkový import vyžaduje ruční kontrolu; tento formát zatím nerozpoznáváme."])
        }
        return parse(text: document.string ?? "", filename: url.lastPathComponent, pdfData: data)
    }

    static func parse(text: String, filename: String, pdfData: Data) -> ImportedInvoiceCandidate {
        var result = ImportedInvoiceCandidate(filename: filename, pdfData: pdfData)
        guard text.count <= 1_000_000 else {
            result.warnings = ["PDF obsahuje příliš mnoho textu pro bezpečný import."]
            return result
        }
        let text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\r", with: "\n")
        guard text.contains("iDoklad"), text.contains("Nejsme plátci DPH"),
              text.contains("Označení dodávky Počet m. j. Cena za m.j. Celkem") else {
            result.warnings = ["Nerozpoznaný formát nebo režim DPH. PDF je potřeba zkontrolovat ručně."]
            return result
        }
        do {
            result.number = first(#"(?m)^Faktura\s*\n([^\n]+)$"#, in: text)?.trimmingCharacters(in: .whitespaces)
            result.issueDate = try date(label: "Datum vystavení:", text: text)
            result.dueDate = try date(label: "Datum splatnosti:", text: text)
            result.variableSymbol = first(#"variabilní:\s*([0-9]+)"#, in: text)
            result.declaredTotal = try amountAfter(#"Celkem k úhradě:\s*"#, text: text)
            result.supplier = try party(block: section(text, after: "Dodavatel\n", before: "Nejsme plátci DPH"))
            result.customer = try party(block: section(text, after: "Odběratel\n", before: "Datum vystavení:"))
            result.supplier?.bankAccount = first(#"(?m)^([0-9]+(?:-[0-9]+)?/[0-9]{4})\s*$"#, in: text) ?? ""
            result.supplier?.email = first(#"E-mail:\s*([^\s]+)"#, in: text) ?? ""
            guard let number = result.number, !number.isEmpty,
                  let supplier = result.supplier, let customer = result.customer,
                  let issued = result.issueDate, let due = result.dueDate,
                  let total = result.declaredTotal, let variableSymbol = result.variableSymbol else {
                throw ImportError.missingFields
            }
            let header = "Označení dodávky Počet m. j. Cena za m.j. Celkem"
            guard let tableStart = text.range(of: header)?.upperBound,
                  let tableEnd = text.range(of: #"Dovol(?:ujeme|uji) si"#, options: .regularExpression, range: tableStart..<text.endIndex)?.lowerBound else {
                throw ImportError.unsupportedTable
            }
            let rows = try parseRows(String(text[tableStart..<tableEnd]))
            result.parsedLines = rows.lines
            var discountAmount: Decimal?
            if text.contains("Celkem před slevou:") || text.contains("Sleva ") {
                let totalsBlock = try section(text, after: "Celkem před slevou:", before: "Celkem k úhradě:")
                guard first(#"Sleva\s+[0-9]+(?:,[0-9]+)?\s*%:"#, in: totalsBlock, group: 0) != nil else {
                    throw ImportError.unsupportedDiscount
                }
                // PDFKit sometimes extracts both labels before both values; match signed currency values in order.
                let values = try matches("(" + moneyPattern + ")\\s*Kč", in: totalsBlock).map { try amount($0[1]) }
                guard values.count == 2, values[0] >= 0, values[1] <= 0 else { throw ImportError.unsupportedDiscount }
                let beforeDiscount = try InvoiceDraft(supplier: supplier, customer: customer, lines: rows.lines,
                                                     issueDate: issued, dueDate: due).total()
                guard beforeDiscount == values[0] else { throw ImportError.amountMismatch }
                discountAmount = -values[1]
            }
            let draft = InvoiceDraft(supplier: supplier, customer: customer, lines: rows.lines,
                                     issueDate: issued, dueDate: due, variableSymbol: variableSymbol,
                                     adjustment: rows.rounding == .zero ? nil : rows.rounding,
                                     adjustmentDescription: rows.rounding == .zero ? nil : "Zaokrouhlení dle původní faktury",
                                     discountAmount: discountAmount, paymentTerms: nil, constantSymbol: nil)
            let invoice = try IssuedInvoice.issue(draft: draft, number: number)
            guard invoice.total == total else { throw ImportError.amountMismatch }
            result.draft = draft
            if let filenameNumber = first(#"([0-9]{4}-[0-9]+)"#, in: filename), filenameNumber != number {
                result.warnings.append("Číslo v názvu souboru se liší od čísla uvnitř PDF; použije se číslo z dokladu.")
            }
            if let today = try? CalendarDate(date: Date()), issued > today {
                result.warnings.append("Faktura má datum vystavení v budoucnosti. Před importem ho ověřte.")
            }
            result.warnings.append("Z PDF nelze zjistit úhradu. Stav platby je nutné určit samostatně.")
        } catch {
            result.draft = nil
            result.warnings.append(error.localizedDescription)
        }
        return result
    }

    private static let moneyPattern = #"-?[0-9]+(?: [0-9]{3})*,[0-9]{2}"#

    private static func parseRows(_ text: String) throws -> (lines: [InvoiceLine], rounding: Decimal) {
        var lines: [InvoiceLine] = []
        var rounding = Decimal.zero
        var buffer = ""
        var roundingSeen = false
        for sourceLine in text.components(separatedBy: .newlines) {
            let trimmed = sourceLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            buffer += (buffer.isEmpty ? "" : " ") + trimmed
            let amounts = matches("(" + moneyPattern + ")", in: buffer)
            if amounts.count < 3 { continue }
            guard amounts.count == 3,
                  let firstAmount = buffer.range(of: amounts[0][0]) else { throw ImportError.unsupportedTable }
            var description = String(buffer[..<firstAmount.lowerBound]).trimmingCharacters(in: .whitespaces)
            let quantity = try amount(amounts[0][1])
            let unitPrice = try amount(amounts[1][1])
            let lineTotal = try amount(amounts[2][1])
            var unit = ""
            if let prefix = first(#"^(hod|ks|den|dny|měsíc|m|m2|m3|kg|l)\s+"#, in: description) {
                unit = prefix
                description = String(description.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            let numericPart = String(buffer[firstAmount.lowerBound...])
            let rest = replacing("(" + moneyPattern + ")", in: numericPart, with: "")
                .trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                guard unit.isEmpty, first(#"^(hod|ks|den|dny|měsíc|m|m2|m3|kg|l)$"#, in: rest) != nil else {
                    throw ImportError.unsupportedTable
                }
                unit = rest
            }
            if description == "Zaokrouhlení" {
                guard !roundingSeen, quantity == 1, unitPrice == lineTotal, abs(lineTotal) < 1 else {
                    throw ImportError.unsupportedTable
                }
                roundingSeen = true
                rounding = lineTotal
            } else {
                let line = InvoiceLine(description: description, quantity: quantity, unit: unit, unitPrice: unitPrice)
                guard try line.total() == lineTotal else { throw ImportError.amountMismatch }
                lines.append(line)
            }
            buffer = ""
        }
        guard buffer.isEmpty, !lines.isEmpty else { throw ImportError.unsupportedTable }
        return (lines, rounding)
    }

    private static func party(block: String) throws -> Party {
        let lines = block.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let name = lines.first, let index = lines.firstIndex(where: { $0.hasPrefix("IČ:") }), index > 1,
              let registration = first(#"IČ:\s*([0-9]{8})"#, in: lines[index]) else { throw ImportError.missingFields }
        return Party(name: name, registrationNumber: registration,
                     taxNumber: first(#"DIČ:\s*([A-Z]{2}[0-9]+)"#, in: lines[index]) ?? "",
                     address: lines[1..<index].joined(separator: "\n"))
    }

    private static func date(label: String, text: String) throws -> CalendarDate {
        guard let raw = first(NSRegularExpression.escapedPattern(for: label) + #"\s*([0-9]{2}\.[0-9]{2}\.[0-9]{4})"#, in: text) else {
            throw ImportError.missingFields
        }
        let parts = raw.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { throw ImportError.missingFields }
        return try CalendarDate(year: parts[2], month: parts[1], day: parts[0])
    }

    private static func amountAfter(_ pattern: String, text: String) throws -> Decimal {
        let values = matches(pattern + "(" + moneyPattern + ")\\s*Kč", in: text)
        guard values.count == 1 else { throw ImportError.missingFields }
        return try amount(values[0][1])
    }

    private static func amount(_ text: String) throws -> Decimal {
        try DecimalInput.parse(text.replacingOccurrences(of: " ", with: ""))
    }

    private static func section(_ text: String, after start: String, before end: String) throws -> String {
        guard let lower = text.range(of: start)?.upperBound,
              let upper = text.range(of: end, range: lower..<text.endIndex)?.lowerBound else { throw ImportError.missingFields }
        return String(text[lower..<upper])
    }

    private static func first(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let match = matches(pattern, in: text).first, match.indices.contains(group) else { return nil }
        return match[group]
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private enum ImportError: LocalizedError {
        case unreadablePDF, missingFields, unsupportedTable, unsupportedDiscount, amountMismatch
        var errorDescription: String? {
            switch self {
            case .unreadablePDF: "Soubor není čitelné PDF nebo překračuje povolenou velikost."
            case .missingFields: "V PDF se nepodařilo jednoznačně přečíst povinné údaje faktury."
            case .unsupportedTable: "Položky PDF mají nepodporované rozložení. Import vyžaduje ruční kontrolu."
            case .unsupportedDiscount: "Slevu z PDF se nepodařilo jednoznačně přečíst jako přesnou částku."
            case .amountMismatch: "Součet položek, slevy a zaokrouhlení nesouhlasí s částkou vytištěnou v PDF."
            }
        }
    }
}
