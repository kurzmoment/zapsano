import Foundation
import SwiftData

@Model
final class ProbeInvoice {
    @Attribute(.unique) var id: UUID
    var number: Int?
    var amount: String

    init(id: UUID = UUID(), amount: Decimal) {
        self.id = id
        self.amount = NSDecimalNumber(decimal: amount).stringValue
    }
}

@Model
final class ProbeSequence {
    @Attribute(.unique) var key: String
    var nextNumber: Int

    init(nextNumber: Int = 1) {
        self.key = "probe"
        self.nextNumber = nextNumber
    }
}

enum ProbeError: Error {
    case missingInvoice, alreadyIssued, invalidBackup, injectedFailure
}

struct ProbeBackup: Codable {
    struct Invoice: Codable {
        let id: UUID
        let number: Int?
        let amount: String
    }
    let version: Int
    let nextNumber: Int
    let invoices: [Invoice]
}

/// A deliberately isolated probe. One owner serializes every mutation.
@MainActor
final class ProbeStore {
    let container: ModelContainer
    private let context: ModelContext

    init(url: URL) throws {
        let schema = Schema([ProbeInvoice.self, ProbeSequence.self])
        let configuration = ModelConfiguration(schema: schema, url: url)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func create(amount: Decimal) throws -> UUID {
        let invoice = ProbeInvoice(amount: amount)
        context.insert(invoice)
        try context.save()
        return invoice.id
    }

    func invoices() throws -> [ProbeInvoice] {
        try context.fetch(FetchDescriptor<ProbeInvoice>())
    }

    func nextNumber() throws -> Int {
        try context.fetch(FetchDescriptor<ProbeSequence>()).first?.nextNumber ?? 1
    }

    func issue(id: UUID, failBeforeSave: Bool = false) throws -> Int {
        guard let invoice = try invoices().first(where: { $0.id == id }) else {
            throw ProbeError.missingInvoice
        }
        guard invoice.number == nil else { throw ProbeError.alreadyIssued }
        let sequence: ProbeSequence
        if let existing = try context.fetch(FetchDescriptor<ProbeSequence>()).first {
            sequence = existing
        } else {
            sequence = ProbeSequence()
            context.insert(sequence)
        }
        let number = sequence.nextNumber
        invoice.number = number
        sequence.nextNumber += 1
        do {
            if failBeforeSave { throw ProbeError.injectedFailure }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return number
    }

    func backup() throws -> Data {
        let rows = try invoices().map {
            ProbeBackup.Invoice(id: $0.id, number: $0.number, amount: $0.amount)
        }
        return try JSONEncoder().encode(ProbeBackup(
            version: 1, nextNumber: nextNumber(), invoices: rows
        ))
    }

    /// Restore only into an empty staging store; active-store replacement is out of scope.
    func restore(_ data: Data) throws {
        let backup = try JSONDecoder().decode(ProbeBackup.self, from: data)
        let numbers = backup.invoices.compactMap(\.number)
        guard try invoices().isEmpty,
              backup.version == 1,
              Set(backup.invoices.map(\.id)).count == backup.invoices.count,
              Set(numbers).count == numbers.count,
              numbers.allSatisfy({ $0 > 0 }),
              backup.nextNumber > (numbers.max() ?? 0),
              backup.invoices.allSatisfy({ Decimal(string: $0.amount, locale: Locale(identifier: "en_US_POSIX")) != nil })
        else { throw ProbeError.invalidBackup }

        context.insert(ProbeSequence(nextNumber: backup.nextNumber))
        for row in backup.invoices {
            let invoice = ProbeInvoice(id: row.id, amount: .zero)
            invoice.amount = row.amount
            invoice.number = row.number
            context.insert(invoice)
        }
        do { try context.save() }
        catch { context.rollback(); throw error }
    }
}
