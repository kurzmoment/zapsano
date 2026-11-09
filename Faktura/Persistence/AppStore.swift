import Combine
import CryptoKit
import FakturaCore
import Foundation
import OSLog
import PDFKit
import SwiftData

struct ClientRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var party: Party
    var archived = false
}

private struct StoredState: Codable {
    var version = 1
    var company = Party()
    var clients: [ClientRecord] = []
    var drafts: [InvoiceDraft] = []
    var invoices: [IssuedInvoice] = []
    var payments: [Payment] = []
    var sequenceYear = 2026
    var nextNumber = 12
    var needsSequenceConfirmation = false
    var editableInvoiceIDs: [UUID]?
    var catalogItems: [CatalogItem]? = []
}

@Model final class AppStateRecord {
    @Attribute(.unique) var key: String
    var payload: Data
    init(payload: Data) { key = "main"; self.payload = payload }
}

@Model final class PDFRecord {
    @Attribute(.unique) var invoiceID: UUID
    @Attribute(.externalStorage) var data: Data
    var checksum: String
    init(invoiceID: UUID, data: Data, checksum: String) {
        self.invoiceID = invoiceID; self.data = data; self.checksum = checksum
    }
}

private struct BackupDocument: Codable {
    let invoiceID: UUID
    let data: Data
    let checksum: String
}
private struct BackupArchive: Codable {
    let version: Int
    let state: StoredState
    let documents: [BackupDocument]
}

enum StoreError: LocalizedError {
    case invalidSequence, confirmSequence, wrongYear, missingRecord, immutableDocument, lockedInvoice, staleInvoice
    case invalidBackup, unsupportedVersion, issuedDraft, invalidPDF, invalidInvoiceNumber, duplicateInvoiceNumber, duplicateDocument, duplicateCatalogItem
    var errorDescription: String? {
        switch self {
        case .invalidSequence: "Číselná řada musí mít platný rok a nepoužité kladné pořadové číslo."
        case .confirmSequence: "Po obnově zálohy potvrďte v Nastavení další číslo podle poslední skutečně vystavené faktury."
        case .wrongYear: "Rok vystavení neodpovídá číselné řadě. Nastavte příslušný rok a další číslo v Nastavení."
        case .missingRecord: "Požadovaný záznam nebyl nalezen."
        case .immutableDocument: "Původní PDF vystavené faktury nelze přepsat."
        case .lockedInvoice: "Upravovat a mazat lze pouze faktury vytvořené v této aplikaci. Importované a starší doklady zůstávají zachované."
        case .staleInvoice: "Faktura se mezitím změnila v jiném okně. Zavřete editor a otevřete aktuální verzi."
        case .invalidBackup: "Záloha obsahuje neplatná nebo nekonzistentní data."
        case .unsupportedVersion: "Tato verze dat není podporována."
        case .issuedDraft: "Vystavenou fakturu nelze změnit na koncept."
        case .invalidPDF: "Dokument není platné PDF."
        case .invalidInvoiceNumber: "Číslo faktury musí mít 1 až 40 znaků: písmena, číslice, mezery nebo - _ . /."
        case .duplicateInvoiceNumber: "Faktura s tímto číslem už existuje. Zvolte jiné číslo."
        case .duplicateDocument: "Tento PDF dokument už je v evidenci uložený."
        case .duplicateCatalogItem: "Položka se stejným popisem, jednotkou a cenou už v ceníku existuje."
        }
    }
}

/// All mutations use a single non-suspending writer and publish only after a successful save.
/// Metadata currently uses one envelope; PDFs are separate and fetched on demand.
@MainActor final class AppStore: ObservableObject {
    @Published private(set) var company: Party
    @Published private(set) var clients: [ClientRecord]
    @Published private(set) var drafts: [InvoiceDraft]
    @Published private(set) var invoices: [IssuedInvoice]
    @Published private(set) var payments: [Payment]
    @Published private(set) var catalogItems: [CatalogItem]
    @Published private(set) var sequenceYear: Int
    @Published private(set) var nextNumber: Int
    @Published private(set) var needsSequenceConfirmation: Bool
    private var state: StoredState
    private let context: ModelContext
    private let saveContext: (ModelContext) throws -> Void
    private let directory: URL
    private let logger = Logger(subsystem: "cz.faktura.app", category: "Persistence")

    init(directory: URL? = nil, saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        let location = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "Faktura", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        self.directory = location
        self.saveContext = saveContext
        let schema = Schema([AppStateRecord.self, PDFRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: location.appending(path: "Faktura.store"))
        let container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
        let records = try context.fetch(FetchDescriptor<AppStateRecord>())
        guard records.count <= 1 else { throw StoreError.invalidBackup }
        var loaded = try records.first.map { try JSONDecoder().decode(StoredState.self, from: $0.payload) } ?? StoredState()
        try Self.validate(loaded)
        let needsCatalogSeed = loaded.catalogItems == nil
        if needsCatalogSeed { try Self.seedLegacyCatalog(in: &loaded) }
        state = loaded
        company = loaded.company; clients = loaded.clients; drafts = loaded.drafts
        invoices = loaded.invoices; payments = loaded.payments
        catalogItems = loaded.catalogItems ?? []
        sequenceYear = loaded.sequenceYear; nextNumber = loaded.nextNumber
        needsSequenceConfirmation = loaded.needsSequenceConfirmation
        if needsCatalogSeed { try commit(loaded) }
    }

    private func commit(_ updated: StoredState, documents: [BackupDocument]? = nil, addingDocument: BackupDocument? = nil, replacingDocument: BackupDocument? = nil, deletingDocumentID: UUID? = nil) throws {
        do {
            let payload = try JSONEncoder().encode(updated)
            if let record = try context.fetch(FetchDescriptor<AppStateRecord>()).first {
                record.payload = payload
            } else { context.insert(AppStateRecord(payload: payload)) }
            if let documents {
                for old in try context.fetch(FetchDescriptor<PDFRecord>()) { context.delete(old) }
                for document in documents {
                    context.insert(PDFRecord(invoiceID: document.invoiceID, data: document.data, checksum: document.checksum))
                }
            }
            if let document = addingDocument {
                context.insert(PDFRecord(invoiceID: document.invoiceID, data: document.data, checksum: document.checksum))
            }
            if let replacement = replacingDocument {
                if let existing = try document(invoiceID: replacement.invoiceID) {
                    existing.data = replacement.data
                    existing.checksum = replacement.checksum
                } else {
                    context.insert(PDFRecord(invoiceID: replacement.invoiceID, data: replacement.data, checksum: replacement.checksum))
                }
            }
            if let id = deletingDocumentID, let existing = try document(invoiceID: id) { context.delete(existing) }
            try saveContext(context)
        } catch { context.rollback(); throw error }
        state = updated
        company = updated.company; clients = updated.clients; drafts = updated.drafts
        invoices = updated.invoices; payments = updated.payments
        catalogItems = updated.catalogItems ?? []
        sequenceYear = updated.sequenceYear; nextNumber = updated.nextNumber
        needsSequenceConfirmation = updated.needsSequenceConfirmation
    }

    func saveSettings(company: Party, nextNumber: Int, year: Int) throws {
        var updated = state
        updated.company = company; updated.nextNumber = nextNumber; updated.sequenceYear = year
        updated.company.iban = try BankAccountDetails.normalizedIBAN(company.iban ?? "")
        guard Self.validSequence(updated) else { throw StoreError.invalidSequence }
        updated.needsSequenceConfirmation = false
        try commit(updated)
        logger.info("Saved settings and sequence for year \(year)")
    }

    @discardableResult func saveCatalogItem(_ item: CatalogItem) throws -> CatalogItem {
        let item = try item.validated()
        var updated = state
        var items = updated.catalogItems ?? []
        if let duplicate = items.first(where: { $0.id != item.id && CatalogKey($0) == CatalogKey(item) }) {
            guard !items.contains(where: { $0.id == item.id }) else { throw StoreError.duplicateCatalogItem }
            return duplicate
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
        updated.catalogItems = items
        try commit(updated)
        logger.info("Saved catalog item \(item.id.uuidString, privacy: .public)")
        return item
    }

    func deleteCatalogItem(id: UUID) throws {
        guard state.catalogItems?.contains(where: { $0.id == id }) == true else { throw StoreError.missingRecord }
        var updated = state
        updated.catalogItems?.removeAll { $0.id == id }
        try commit(updated)
        logger.info("Deleted catalog item \(id.uuidString, privacy: .public)")
    }

    func saveClient(party: Party, id: UUID? = nil) throws {
        var updated = state
        let clientID = id ?? UUID()
        if let id {
            guard let index = updated.clients.firstIndex(where: { $0.id == id }) else { throw StoreError.missingRecord }
            updated.clients[index].party = party
        } else { updated.clients.append(ClientRecord(id: clientID, party: party)) }
        try commit(updated)
        logger.info("Saved client \(clientID.uuidString, privacy: .public)")
    }

    func archiveClient(id: UUID) throws {
        var updated = state
        guard let index = updated.clients.firstIndex(where: { $0.id == id }) else { throw StoreError.missingRecord }
        updated.clients[index].archived = true
        try commit(updated)
        logger.info("Archived client \(id.uuidString, privacy: .public)")
    }

    func saveDraft(_ draft: InvoiceDraft) throws {
        guard !state.invoices.contains(where: { $0.id == draft.id }) else { throw StoreError.issuedDraft }
        var updated = state
        if let index = updated.drafts.firstIndex(where: { $0.id == draft.id }) { updated.drafts[index] = draft }
        else { updated.drafts.append(draft) }
        try commit(updated)
        logger.info("Saved draft \(draft.id.uuidString, privacy: .public)")
    }

    func deleteDraft(id: UUID) throws {
        guard state.drafts.contains(where: { $0.id == id }) else { throw StoreError.missingRecord }
        var updated = state
        updated.drafts.removeAll { $0.id == id }
        try saveSafetyBackup(reason: "BeforeDeleteDraft")
        try commit(updated)
        logger.info("Deleted draft \(id.uuidString, privacy: .public)")
    }

    var nextInvoiceNumber: String { Self.number(year: state.sequenceYear, ordinal: state.nextNumber) }

    @discardableResult func issue(draft: InvoiceDraft, number requestedNumber: String? = nil) throws -> IssuedInvoice {
        if let existing = state.invoices.first(where: { $0.id == draft.id }) { return existing }
        let (invoice, prepared) = try prepareIssuance(draft: draft, number: requestedNumber)
        var updated = prepared
        updated.editableInvoiceIDs = (updated.editableInvoiceIDs ?? []) + [invoice.id]
        try Self.remember(invoice.lines, in: &updated)
        try commit(updated)
        logger.info("Issued invoice \(invoice.id.uuidString, privacy: .public)")
        return invoice
    }

    func canEditInvoice(id: UUID) -> Bool {
        state.invoices.contains(where: { $0.id == id }) && (state.editableInvoiceIDs?.contains(id) ?? false)
    }

    @discardableResult func updateInvoice(
        id: UUID, draft: InvoiceDraft, number: String, expectedDraft: InvoiceDraft? = nil,
        render: (IssuedInvoice) throws -> Data = { try InvoicePDFRenderer.render(invoice: $0) }
    ) throws -> IssuedInvoice {
        guard canEditInvoice(id: id) else { throw StoreError.lockedInvoice }
        if let expectedDraft {
            guard state.invoices.first(where: { $0.id == id })?.editableDraft() == expectedDraft else { throw StoreError.staleInvoice }
        }
        var replacement = draft
        replacement.id = id
        let (invoice, prepared) = try prepareIssuance(draft: replacement, number: number, replacingID: id)
        var updated = prepared
        try Self.remember(invoice.lines, in: &updated)
        guard try invoice.outstanding(payments: updated.payments) >= 0 else { throw BillingError.overpayment }
        let pdfData = try render(invoice)
        guard let pdf = PDFDocument(data: pdfData), !pdf.isLocked, pdf.pageCount > 0 else { throw StoreError.invalidPDF }
        let document = BackupDocument(invoiceID: id, data: pdfData, checksum: Self.digest(pdfData))
        try saveSafetyBackup(reason: "BeforeEdit")
        try commit(updated, replacingDocument: document)
        logger.info("Updated native invoice \(id.uuidString, privacy: .public)")
        return invoice
    }

    func deleteInvoice(id: UUID) throws {
        guard canEditInvoice(id: id) else { throw StoreError.lockedInvoice }
        var updated = state
        updated.invoices.removeAll { $0.id == id }
        updated.payments.removeAll { $0.invoiceID == id }
        updated.editableInvoiceIDs?.removeAll { $0 == id }
        try saveSafetyBackup(reason: "BeforeDelete")
        try commit(updated, deletingDocumentID: id)
        logger.info("Deleted native invoice \(id.uuidString, privacy: .public)")
    }

    /// Full payment requires an explicit date or explicit confirmation that its date is unknown.
    @discardableResult func importInvoice(draft: InvoiceDraft, number: String, originalPDF: Data, paidOn: CalendarDate?, paidWithoutDate: Bool = false) throws -> IssuedInvoice {
        guard !state.invoices.contains(where: { $0.id == draft.id }) else { throw StoreError.duplicateInvoiceNumber }
        guard originalPDF.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: originalPDF),
              !pdf.isLocked, pdf.pageCount > 0 else { throw StoreError.invalidPDF }
        let checksum = Self.digest(originalPDF)
        var duplicates = FetchDescriptor<PDFRecord>(predicate: #Predicate { $0.checksum == checksum })
        duplicates.fetchLimit = 1
        guard try context.fetch(duplicates).isEmpty else { throw StoreError.duplicateDocument }
        let (invoice, prepared) = try prepareIssuance(draft: draft, number: number)
        var updated = prepared
        if (paidOn != nil || paidWithoutDate), invoice.total > 0 {
            let payment = Payment(invoiceID: invoice.id, date: paidOn, amount: invoice.total, note: "Úhrada potvrzená při importu")
            try invoice.validatePayment(payment, existing: updated.payments)
            updated.payments.append(payment)
        }
        if !updated.clients.contains(where: { Self.sameClient($0.party, invoice.customer) }) {
            updated.clients.append(ClientRecord(party: invoice.customer))
        }
        let document = BackupDocument(invoiceID: invoice.id, data: originalPDF, checksum: checksum)
        try commit(updated, addingDocument: document)
        logger.info("Imported invoice \(invoice.id.uuidString, privacy: .public) with original PDF")
        return invoice
    }

    private func prepareIssuance(draft: InvoiceDraft, number requestedNumber: String?, replacingID: UUID? = nil) throws -> (IssuedInvoice, StoredState) {
        guard !state.needsSequenceConfirmation else { throw StoreError.confirmSequence }
        if requestedNumber == nil {
            guard draft.issueDate.year == state.sequenceYear else { throw StoreError.wrongYear }
        }
        guard Self.validSequence(state) else { throw StoreError.invalidSequence }
        let number = try Self.normalizedInvoiceNumber(requestedNumber ?? nextInvoiceNumber)
        let key = Self.numberIdentity(number)
        guard !state.invoices.contains(where: { $0.id != replacingID && Self.numberIdentity($0.number) == key }) else {
            throw StoreError.duplicateInvoiceNumber
        }
        var updated = state
        if let series = Self.standardSeries(number), series.year == state.sequenceYear {
            guard let ordinal = Int(series.ordinal), ordinal > 0, ordinal < Int.max else { throw StoreError.invalidSequence }
            updated.nextNumber = max(updated.nextNumber, ordinal + 1)
        }
        let invoice = try IssuedInvoice.issue(draft: draft, number: number)
        if let replacingID, let index = updated.invoices.firstIndex(where: { $0.id == replacingID }) {
            updated.invoices[index] = invoice
        } else { updated.invoices.append(invoice) }
        updated.drafts.removeAll { $0.id == draft.id }
        return (invoice, updated)
    }

    private static func sameClient(_ lhs: Party, _ rhs: Party) -> Bool {
        func normalized(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        let leftID = normalized(lhs.registrationNumber)
        let rightID = normalized(rhs.registrationNumber)
        if !leftID.isEmpty || !rightID.isEmpty { return !leftID.isEmpty && leftID == rightID }
        return normalized(lhs.name) == normalized(rhs.name) && normalized(lhs.address) == normalized(rhs.address)
    }

    func addPayment(_ payment: Payment) throws {
        guard let invoice = state.invoices.first(where: { $0.id == payment.invoiceID }) else { throw StoreError.missingRecord }
        try invoice.validatePayment(payment, existing: state.payments)
        var updated = state
        updated.payments.append(payment)
        try commit(updated)
        logger.info("Added payment \(payment.id.uuidString, privacy: .public) for invoice \(payment.invoiceID.uuidString, privacy: .public)")
    }

    func reversePayment(id: UUID) throws {
        var updated = state
        guard let index = updated.payments.firstIndex(where: { $0.id == id }) else { throw StoreError.missingRecord }
        updated.payments[index].reverse()
        try commit(updated)
        logger.info("Reversed payment \(id.uuidString, privacy: .public)")
    }

    private func document(invoiceID: UUID) throws -> PDFRecord? {
        let id = invoiceID
        var descriptor = FetchDescriptor<PDFRecord>(predicate: #Predicate { $0.invoiceID == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func pdfData(invoiceID: UUID) throws -> Data? {
        guard let record = try document(invoiceID: invoiceID) else { return nil }
        guard record.checksum == Self.digest(record.data) else { throw StoreError.invalidPDF }
        return record.data
    }

    func savePDF(data: Data, invoiceID: UUID) throws {
        guard state.invoices.contains(where: { $0.id == invoiceID }) else { throw StoreError.missingRecord }
        guard data.starts(with: Data("%PDF-".utf8)) else { throw StoreError.invalidPDF }
        if let existing = try document(invoiceID: invoiceID) {
            guard existing.data == data else { throw StoreError.immutableDocument }
            return
        }
        context.insert(PDFRecord(invoiceID: invoiceID, data: data, checksum: Self.digest(data)))
        do { try saveContext(context) } catch { context.rollback(); throw error }
        logger.info("Saved original PDF for invoice \(invoiceID.uuidString, privacy: .public)")
    }

    func exportBackup() throws -> Data {
        let documents = try context.fetch(FetchDescriptor<PDFRecord>()).map {
            guard $0.checksum == Self.digest($0.data) else { throw StoreError.invalidPDF }
            return BackupDocument(invoiceID: $0.invoiceID, data: $0.data, checksum: $0.checksum)
        }
        return try JSONEncoder().encode(BackupArchive(version: 1, state: state, documents: documents))
    }

    func restoreBackup(data: Data) throws {
        let archive = try JSONDecoder().decode(BackupArchive.self, from: data)
        guard archive.version == 1 else { throw StoreError.unsupportedVersion }
        try Self.validate(archive.state)
        let ids = Set(archive.state.invoices.map(\.id))
        guard Set(archive.documents.map(\.invoiceID)).count == archive.documents.count,
              archive.documents.allSatisfy({ ids.contains($0.invoiceID) && $0.checksum == Self.digest($0.data) && $0.data.starts(with: Data("%PDF-".utf8)) }) else { throw StoreError.invalidBackup }
        // No filesystem paths are accepted from the archive. Verify the complete candidate before touching active data.
        try saveSafetyBackup(reason: "BeforeRestore")
        var restored = archive.state
        try Self.seedLegacyCatalog(in: &restored)
        restored.needsSequenceConfirmation = true
        try commit(restored, documents: archive.documents)
        logger.info("Restored backup; sequence confirmation required")
    }

    private func saveSafetyBackup(reason: String) throws {
        let url = directory.appending(path: "\(reason)-\(UUID().uuidString).fakturabackup")
        try exportBackup().write(to: url, options: .atomic)
    }

    private struct CatalogKey: Hashable {
        let description: String
        let unit: String
        let price: Decimal
        init(_ item: CatalogItem) {
            func normalized(_ text: String) -> String {
                text.split(whereSeparator: \.isWhitespace).joined(separator: " ").precomposedStringWithCanonicalMapping.lowercased()
            }
            description = normalized(item.description)
            unit = normalized(item.unit)
            price = item.unitPrice
        }
    }

    private static func remember(_ lines: [InvoiceLine], in state: inout StoredState) throws {
        var items = state.catalogItems ?? []
        var known = Set(items.map(CatalogKey.init))
        for line in lines {
            let item = try CatalogItem(description: line.description, unit: line.unit, unitPrice: line.unitPrice).validated()
            if known.insert(CatalogKey(item)).inserted { items.append(item) }
        }
        state.catalogItems = items
    }

    private static func seedLegacyCatalog(in state: inout StoredState) throws {
        guard state.catalogItems == nil else { return }
        try remember(state.invoices.flatMap(\.lines), in: &state)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func number(year: Int, ordinal: Int) -> String {
        "\(year)-" + String(repeating: "0", count: max(0, 2 - String(ordinal).count)) + String(ordinal)
    }

    private static func normalizedInvoiceNumber(_ input: String) throws -> String {
        let number = input.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " -_./"))
        guard (1...40).contains(number.count), number.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              number.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
            throw StoreError.invalidInvoiceNumber
        }
        return number
    }

    private static func standardSeries(_ number: String) -> (year: Int, ordinal: String)? {
        guard number.range(of: #"^[0-9]{1,4}-[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        let parts = number.split(separator: "-")
        guard let year = Int(parts[0]) else { return nil }
        let ordinal = String(parts[1].drop(while: { $0 == "0" }))
        return (year, ordinal.isEmpty ? "0" : ordinal)
    }

    private static func numberIdentity(_ number: String) -> String {
        guard let series = standardSeries(number) else { return number }
        return "\(series.year)-\(series.ordinal)"
    }

    private static func validSequence(_ state: StoredState) -> Bool {
        guard (1...9999).contains(state.sequenceYear), state.nextNumber > 0 else { return false }
        let highest = state.invoices.compactMap { invoice -> Int? in
            guard let series = standardSeries(invoice.number), series.year == state.sequenceYear else { return nil }
            return Int(series.ordinal)
        }.max() ?? 0
        return state.nextNumber > highest
    }

    private static func validate(_ state: StoredState) throws {
        guard state.version == 1 else { throw StoreError.unsupportedVersion }
        let catalog = state.catalogItems ?? []
        guard Set(catalog.map(\.id)).count == catalog.count,
              Set(catalog.map(CatalogKey.init)).count == catalog.count else { throw StoreError.invalidBackup }
        for item in catalog { _ = try item.validated() }
        let editableIDs = state.editableInvoiceIDs ?? []
        guard Set(editableIDs).count == editableIDs.count,
              Set(editableIDs).isSubset(of: Set(state.invoices.map(\.id))) else { throw StoreError.invalidBackup }
        guard validSequence(state),
              Set(state.clients.map(\.id)).count == state.clients.count,
              Set(state.drafts.map(\.id)).count == state.drafts.count,
              Set(state.invoices.map(\.id)).count == state.invoices.count,
              Set(state.invoices.map { numberIdentity($0.number) }).count == state.invoices.count,
              Set(state.payments.map(\.id)).count == state.payments.count,
              Set(state.drafts.map(\.id)).isDisjoint(with: state.invoices.map(\.id)) else { throw StoreError.invalidBackup }
        for invoice in state.invoices {
            guard try normalizedInvoiceNumber(invoice.number) == invoice.number else { throw StoreError.invalidBackup }
            let draft = invoice.editableDraft()
            guard try IssuedInvoice.issue(draft: draft, number: invoice.number) == invoice else { throw StoreError.invalidBackup }
            let active = state.payments.filter { $0.invoiceID == invoice.id && $0.reversedAt == nil }
            var checked: [Payment] = []
            for payment in active {
                try invoice.validatePayment(payment, existing: checked)
                checked.append(payment)
            }
        }
        let invoiceIDs = Set(state.invoices.map(\.id))
        for payment in state.payments {
            guard invoiceIDs.contains(payment.invoiceID), !payment.amount.isNaN, payment.amount > 0,
                  BillingMath.rounded(payment.amount) == payment.amount else { throw StoreError.invalidBackup }
        }
    }
}
