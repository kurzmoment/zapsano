import Foundation
import Testing
import SwiftData
import FakturaCore
import PDFKit
@testable import Faktura

@MainActor struct AppStoreTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
    private func draft() throws -> InvoiceDraft {
        try InvoiceDraft(supplier: Party(name: "Dodavatel", registrationNumber: "12345678", address: "Praha 1"), customer: Party(name: "Odběratel", address: "Brno 1"),
                         lines: [InvoiceLine(description: "Služba", quantity: 3, unitPrice: Decimal(string: "123.45")!)],
                         issueDate: CalendarDate(year: 2026, month: 10, day: 30),
                         dueDate: CalendarDate(year: 2026, month: 11, day: 13))
    }

    @Test func catalogDeduplicatesNormalizedRatesButPreservesDistinctPricesAndInvoiceSnapshots() throws {
        try withDirectory { directory in
            let original: IssuedInvoice
            do {
                let store = try AppStore(directory: directory)
                let item = try store.saveCatalogItem(CatalogItem(description: "Konzultace", unit: "hod", unitPrice: 100))
                let duplicate = try store.saveCatalogItem(CatalogItem(description: "  KONZULTACE  ", unit: " HOD ", unitPrice: Decimal(string: "100.00")!))
                #expect(duplicate.id == item.id)
                #expect(store.catalogItems.count == 1)
                _ = try store.saveCatalogItem(CatalogItem(description: "Konzultace", unit: "hod", unitPrice: 150))
                var input = try draft()
                input.lines = [InvoiceLine(description: item.description, quantity: 2, unit: item.unit, unitPrice: item.unitPrice)]
                original = try store.issue(draft: input)
                #expect(store.catalogItems.count == 2)
                var edited = item
                edited.description = "Jiná služba"
                edited.unitPrice = 200
                try store.saveCatalogItem(edited)
                #expect(store.invoices[0] == original)
                for saved in store.catalogItems { try store.deleteCatalogItem(id: saved.id) }
                #expect(store.catalogItems.isEmpty)
            }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.catalogItems.isEmpty)
            #expect(reopened.invoices == [original])
        }
    }

    @Test func successfulIssueAndUpdateRememberRatesButDraftsAndFailedSavesDoNot() throws {
        enum InjectedFailure: Error { case save }
        try withDirectory { directory in
            var shouldFail = false
            let store = try AppStore(directory: directory, saveContext: { context in
                if shouldFail { throw InjectedFailure.save }
                try context.save()
            })
            var input = try draft()
            input.lines = [InvoiceLine(description: "Práce", unit: "den", unitPrice: 100)]
            try store.saveDraft(input)
            #expect(store.catalogItems.isEmpty)
            shouldFail = true
            #expect(throws: InjectedFailure.self) { try store.issue(draft: input) }
            #expect(store.catalogItems.isEmpty)
            #expect(store.invoices.isEmpty)
            shouldFail = false
            let invoice = try store.issue(draft: input)
            #expect(store.catalogItems.map(\.unit) == ["den"])
            var edited = invoice.editableDraft()
            edited.lines[0].unitPrice = 200
            shouldFail = true
            #expect(throws: InjectedFailure.self) { try store.updateInvoice(id: invoice.id, draft: edited, number: invoice.number) }
            #expect(store.catalogItems.map(\.unitPrice) == [100])
            shouldFail = false
            _ = try store.updateInvoice(id: invoice.id, draft: edited, number: invoice.number)
            #expect(store.catalogItems.map(\.unitPrice) == [100, 200])
            let reopened = try AppStore(directory: directory)
            #expect(reopened.catalogItems == store.catalogItems)
        }
    }

    @Test func legacyStateSeedsCatalogExactlyOnceAndPreservesUnknownUnits() throws {
        try withDirectory { directory in
            do {
                let store = try AppStore(directory: directory)
                var input = try draft()
                input.lines = [InvoiceLine(description: "Práce", unit: "", unitPrice: 100),
                               InvoiceLine(description: "  PRÁCE  ", unit: "", unitPrice: 100),
                               InvoiceLine(description: "Práce", unit: "", unitPrice: 200)]
                _ = try store.issue(draft: input)
            }
            do {
                let schema = Schema([AppStateRecord.self, PDFRecord.self])
                let configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "Faktura.store"))
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let context = ModelContext(container)
                let record = try #require(context.fetch(FetchDescriptor<AppStateRecord>()).first)
                var fields = try #require(JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
                fields.removeValue(forKey: "catalogItems")
                record.payload = try JSONSerialization.data(withJSONObject: fields)
                try context.save()
            }
            let firstIDs: [UUID]
            do {
                let migrated = try AppStore(directory: directory)
                #expect(migrated.catalogItems.count == 2)
                #expect(migrated.catalogItems.allSatisfy { $0.unit.isEmpty })
                firstIDs = migrated.catalogItems.map(\.id)
            }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.catalogItems.map(\.id) == firstIDs)
        }
    }

    @Test func catalogBackupRoundtripAndInvalidCatalogCannotReplaceActiveData() throws {
        try withDirectory { directory in
            let source = try AppStore(directory: directory.appending(path: "source"))
            let item = try source.saveCatalogItem(CatalogItem(description: "Práce", unit: "ks", unitPrice: 100))
            let backup = try source.exportBackup()
            let target = try AppStore(directory: directory.appending(path: "target"))
            try target.restoreBackup(data: backup)
            #expect(target.catalogItems == [item])
            var archive = try #require(JSONSerialization.jsonObject(with: backup) as? [String: Any])
            var state = try #require(archive["state"] as? [String: Any])
            var catalog = try #require(state["catalogItems"] as? [[String: Any]])
            catalog[0]["unitPrice"] = -1
            state["catalogItems"] = catalog
            archive["state"] = state
            #expect(throws: (any Error).self) { try target.restoreBackup(data: JSONSerialization.data(withJSONObject: archive)) }
            #expect(target.catalogItems == [item])
            catalog[0]["unitPrice"] = 100
            state["catalogItems"] = [catalog[0], catalog[0]]
            archive["state"] = state
            #expect(throws: StoreError.self) { try target.restoreBackup(data: JSONSerialization.data(withJSONObject: archive)) }
            #expect(target.catalogItems == [item])
        }
    }

    @Test func restoringLegacyBackupSeedsCatalogWithoutInventingUnits() throws {
        try withDirectory { directory in
            let source = try AppStore(directory: directory.appending(path: "source"))
            var input = try draft()
            input.lines = [InvoiceLine(description: "Služba", unit: "", unitPrice: 100)]
            _ = try source.issue(draft: input)
            var archive = try #require(JSONSerialization.jsonObject(with: source.exportBackup()) as? [String: Any])
            var state = try #require(archive["state"] as? [String: Any])
            state.removeValue(forKey: "catalogItems")
            archive["state"] = state
            let targetDirectory = directory.appending(path: "target")
            let target = try AppStore(directory: targetDirectory)
            try target.restoreBackup(data: JSONSerialization.data(withJSONObject: archive))
            #expect(target.catalogItems.count == 1)
            #expect(target.catalogItems[0].unit.isEmpty)
            #expect(target.catalogItems[0].unitPrice == 100)
            let reopened = try AppStore(directory: targetDirectory)
            #expect(reopened.catalogItems == target.catalogItems)
        }
    }

    @Test func nativeEditReplacesSnapshotAndPDFTogetherAndSurvivesReopen() throws {
        try withDirectory { directory in
            let id: UUID
            let updated: IssuedInvoice
            do {
                let store = try AppStore(directory: directory)
                let original = try store.issue(draft: draft())
                id = original.id
                #expect(store.canEditInvoice(id: id))
                try store.savePDF(data: InvoicePDFRenderer.render(invoice: original), invoiceID: id)
                var changed = original.editableDraft()
                changed.id = UUID() // Store owns the identity even if the caller passes a different one.
                changed.customer.name = "Nový odběratel"
                changed.lines[0].unitPrice = 200
                updated = try store.updateInvoice(id: id, draft: changed, number: "2026-20")
                #expect(updated.id == id)
                #expect(updated.total == 600)
                #expect(store.nextNumber == 21)
                let pdf = try #require(try store.pdfData(invoiceID: id))
                #expect(PDFDocument(data: pdf)?.string?.contains("Nový odběratel") == true)
                let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("BeforeEdit-") }
                #expect(backups.count == 1)
                let backupStore = try AppStore(directory: directory.appending(path: "recovery"))
                try backupStore.restoreBackup(data: Data(contentsOf: backups[0]))
                #expect(backupStore.invoices == [original])
                #expect(backupStore.canEditInvoice(id: id))
            }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.invoices == [updated])
            #expect(reopened.canEditInvoice(id: id))
            #expect(PDFDocument(data: try #require(try reopened.pdfData(invoiceID: id)))?.string?.contains("Nový odběratel") == true)
        }
    }

    @Test func editRejectsDuplicateNumberAndTotalBelowExistingPayments() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            let first = try store.issue(draft: draft())
            let second = try store.issue(draft: draft())
            try store.addPayment(Payment(invoiceID: first.id, date: nil, amount: 100))
            var changed = first.editableDraft()
            #expect(throws: StoreError.self) { try store.updateInvoice(id: first.id, draft: changed, number: second.number) }
            changed.lines = [InvoiceLine(description: "Služba", unitPrice: 99)]
            #expect(throws: BillingError.overpayment) { try store.updateInvoice(id: first.id, draft: changed, number: first.number) }
            #expect(store.invoices == [first, second])
            changed.lines[0].unitPrice = 100
            let updated = try store.updateInvoice(id: first.id, draft: changed, number: first.number)
            #expect(try updated.outstanding(payments: store.payments) == 0)
            #expect(store.nextNumber == 14)
        }
    }

    @Test func importedAndLegacyInvoicesRemainLocked() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            let input = try draft()
            let pdf = try InvoicePDFRenderer.render(invoice: IssuedInvoice.issue(draft: input, number: "2026-01"))
            let imported = try store.importInvoice(draft: input, number: "2026-01", originalPDF: pdf, paidOn: nil)
            #expect(!store.canEditInvoice(id: imported.id))
            #expect(throws: StoreError.self) { try store.updateInvoice(id: imported.id, draft: input, number: imported.number) }
            #expect(throws: StoreError.self) { try store.deleteInvoice(id: imported.id) }
            let native = try store.issue(draft: draft())
            // Preserve Decimal JSON tokens exactly while simulating a missing provenance field.
            let archive = try #require(String(data: store.exportBackup(), encoding: .utf8))
                .replacingOccurrences(of: "\"editableInvoiceIDs\"", with: "\"ignoredLegacyField\"")
            try store.restoreBackup(data: Data(archive.utf8))
            #expect(!store.canEditInvoice(id: native.id))
            #expect(throws: StoreError.self) { try store.deleteInvoice(id: native.id) }
            #expect(try store.pdfData(invoiceID: imported.id) == pdf)
        }
    }

    @Test func deleteRemovesOnlyNativeInvoicePaymentsAndPDFWithoutRewinding() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            let first = try store.issue(draft: draft())
            let second = try store.issue(draft: draft())
            try store.saveClient(party: first.customer)
            for invoice in [first, second] {
                try store.savePDF(data: InvoicePDFRenderer.render(invoice: invoice), invoiceID: invoice.id)
                try store.addPayment(Payment(invoiceID: invoice.id, date: nil, amount: 10))
            }
            let secondPDF = try store.pdfData(invoiceID: second.id)
            try store.deleteInvoice(id: first.id)
            #expect(store.invoices == [second])
            #expect(store.payments.count == 1 && store.payments[0].invoiceID == second.id)
            #expect(try store.pdfData(invoiceID: first.id) == nil)
            #expect(try store.pdfData(invoiceID: second.id) == secondPDF)
            #expect(store.clients.count == 1)
            #expect(store.nextNumber == 14)
            #expect(!store.canEditInvoice(id: first.id))
            let reopened = try AppStore(directory: directory)
            #expect(reopened.invoices == [second])
            #expect(reopened.nextNumber == 14)
        }
    }

    @Test func failedEditAndDeleteLeaveMetadataAndPDFUnchanged() throws {
        enum InjectedFailure: Error { case save }
        try withDirectory { directory in
            var shouldFail = false
            let store = try AppStore(directory: directory, saveContext: { context in
                if shouldFail { throw InjectedFailure.save }
                try context.save()
            })
            let original = try store.issue(draft: draft())
            let pdf = try InvoicePDFRenderer.render(invoice: original)
            try store.savePDF(data: pdf, invoiceID: original.id)
            var changed = original.editableDraft()
            changed.customer.name = "Změna"
            shouldFail = true
            #expect(throws: InjectedFailure.self) { try store.updateInvoice(id: original.id, draft: changed, number: "2026-20") }
            #expect(store.invoices == [original])
            #expect(try store.pdfData(invoiceID: original.id) == pdf)
            #expect(store.nextNumber == 13)
            #expect(throws: InjectedFailure.self) { try store.deleteInvoice(id: original.id) }
            #expect(store.invoices == [original])
            #expect(try store.pdfData(invoiceID: original.id) == pdf)
            let reopened = try AppStore(directory: directory)
            #expect(reopened.invoices == [original])
            #expect(reopened.canEditInvoice(id: original.id))
        }
    }

    @Test func invalidProvenanceInBackupIsRejectedBeforeMutation() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            let original = try store.issue(draft: draft())
            var archive = try #require(JSONSerialization.jsonObject(with: store.exportBackup()) as? [String: Any])
            var state = try #require(archive["state"] as? [String: Any])
            state["editableInvoiceIDs"] = [UUID().uuidString]
            archive["state"] = state
            #expect(throws: StoreError.self) { try store.restoreBackup(data: JSONSerialization.data(withJSONObject: archive)) }
            #expect(store.invoices == [original])
            #expect(store.canEditInvoice(id: original.id))
        }
    }

    @Test func deletingDraftPreservesInvoicesAndSequence() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            let invoice = try store.issue(draft: draft())
            let draft = try draft()
            try store.saveDraft(draft)
            try store.deleteDraft(id: draft.id)
            #expect(store.drafts.isEmpty)
            #expect(store.invoices == [invoice])
            #expect(store.nextNumber == 13)
            #expect(throws: StoreError.self) { try store.deleteDraft(id: invoice.id) }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.drafts.isEmpty)
        }
    }

    @Test func staleEditorCannotOverwriteNewerInvoiceChanges() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            let original = try store.issue(draft: draft())
            let expected = original.editableDraft()
            var changed = expected
            changed.note = "Změna v prvním okně"
            let updated = try store.updateInvoice(id: original.id, draft: changed, number: original.number, expectedDraft: expected)
            changed.note = "Zastaralá změna ve druhém okně"
            #expect(throws: StoreError.self) {
                try store.updateInvoice(id: original.id, draft: changed, number: original.number, expectedDraft: expected)
            }
            #expect(store.invoices == [updated])
        }
    }

    @Test func issuanceIsIdempotentAndSurvivesReopen() throws {
        try withDirectory { directory in
            let invoice: IssuedInvoice
            do {
                let store = try AppStore(directory: directory)
                let draft = try draft()
                try store.saveDraft(draft)
                invoice = try store.issue(draft: draft)
                #expect(invoice.number == "2026-12")
                #expect(try store.issue(draft: draft) == invoice)
                #expect(store.nextNumber == 13)
                #expect(store.drafts.isEmpty)
            }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.invoices == [invoice])
            #expect(reopened.nextNumber == 13)
            #expect(throws: StoreError.self) { try reopened.saveSettings(company: Party(), nextNumber: 12, year: 2026) }
        }
    }

    @Test func settingsIBANValidationAndIssuedSnapshotSurviveReopen() throws {
        try withDirectory { directory in
            do {
                let store = try AppStore(directory: directory)
                var input = try draft()
                input.supplier.iban = "cz65 0800 0000 1920 0014 5399"
                try store.saveSettings(company: input.supplier, nextNumber: 12, year: 2026)
                #expect(store.company.iban == "CZ6508000000192000145399")
                let invoice = try store.issue(draft: input)
                #expect(invoice.supplier.iban == store.company.iban)
                var invalidCompany = store.company
                invalidCompany.iban = "CZ6508000000192000145398"
                #expect(throws: BillingError.invalidIBAN) {
                    try store.saveSettings(company: invalidCompany, nextNumber: 13, year: 2026)
                }
                input.id = UUID()
                input.supplier = invalidCompany
                #expect(throws: BillingError.invalidIBAN) { try store.issue(draft: input) }
                #expect(store.nextNumber == 13)
                #expect(store.invoices.count == 1)
                var clearedCompany = store.company
                clearedCompany.iban = " "
                try store.saveSettings(company: clearedCompany, nextNumber: 13, year: 2026)
                #expect(store.company.iban == nil)
                #expect(store.invoices[0].supplier.iban == "CZ6508000000192000145399")
            }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.company.iban == nil)
            #expect(reopened.invoices[0].supplier.iban == "CZ6508000000192000145399")
        }
    }

    @Test func customNumberNormalizesAndAdvancesOnlyMatchingSeries() throws {
        try withDirectory { directory in
            do {
                let store = try AppStore(directory: directory)
                #expect(store.nextInvoiceNumber == "2026-12")
                let input = try draft()
                let invoice = try store.issue(draft: input, number: " 2026-013 ")
                #expect(invoice.number == "2026-013")
                #expect(store.nextInvoiceNumber == "2026-14")
                #expect(try store.issue(draft: input, number: "JINE/99") == invoice)
                #expect(throws: StoreError.self) { try store.issue(draft: draft(), number: "2026-13") }
                #expect(throws: StoreError.self) { try store.issue(draft: draft(), number: "2026-0013") }
                #expect(try store.issue(draft: draft(), number: "FV/2026/21").number == "FV/2026/21")
                #expect(store.nextNumber == 14)
                #expect(throws: StoreError.self) { try store.issue(draft: draft(), number: " FV/2026/21 ") }
                #expect(try store.issue(draft: draft()).number == "2026-14")
            }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.invoices.count == 3)
            #expect(reopened.nextInvoiceNumber == "2026-15")
        }
    }

    @Test func customNumberAllowsIndependentYearButDefaultProtectsYearMismatch() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            var input = try draft()
            input.issueDate = try CalendarDate(year: 2027, month: 1, day: 1)
            input.dueDate = try CalendarDate(year: 2027, month: 1, day: 15)
            #expect(throws: StoreError.self) { try store.issue(draft: input) }
            #expect(try store.issue(draft: input, number: "2027-01").number == "2027-01")
            #expect(store.nextInvoiceNumber == "2026-12")
            try store.saveSettings(company: store.company, nextNumber: 2, year: 2027)
            #expect(store.nextInvoiceNumber == "2027-02")
        }
    }

    @Test func unsafeCustomNumbersDoNotMutateStore() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            for number in ["", "   ", "---", "FV\n12", "FV\u{0}12", String(repeating: "1", count: 41), "2026-\(Int.max)"] {
                #expect(throws: StoreError.self) { try store.issue(draft: draft(), number: number) }
            }
            #expect(store.invoices.isEmpty)
            #expect(store.nextNumber == 12)
        }
    }

    @Test func historicalImportPreservesOriginalsAndExplicitPayment() throws {
        try withDirectory { directory in
            var input = try draft()
            input.adjustment = -10
            input.adjustmentDescription = "Sleva"
            let originalInvoice = try IssuedInvoice.issue(draft: input, number: "2026-0030")
            let originalPDF = try InvoicePDFRenderer.render(invoice: originalInvoice)
            let company = Party(name: "Současná firma")
            do {
                let store = try AppStore(directory: directory)
                try store.saveSettings(company: company, nextNumber: 12, year: 2026)
                let earlier = try store.issue(draft: draft())
                let earlierPDF = try InvoicePDFRenderer.render(invoice: earlier)
                try store.savePDF(data: earlierPDF, invoiceID: earlier.id)
                let imported = try store.importInvoice(draft: input, number: "2026-0030", originalPDF: originalPDF, paidOn: input.dueDate)
                #expect(imported == originalInvoice)
                #expect(store.nextInvoiceNumber == "2026-31")
                #expect(store.company == company)
                #expect(try store.pdfData(invoiceID: imported.id) == originalPDF)
                #expect(try store.pdfData(invoiceID: earlier.id) == earlierPDF)
                #expect(try imported.outstanding(payments: store.payments) == 0)
                #expect(store.payments.first?.date == input.dueDate)
                #expect(store.clients.count == 1)
                #expect(throws: StoreError.self) {
                    try store.importInvoice(draft: draft(), number: "2026-30", originalPDF: originalPDF, paidOn: nil)
                }
                #expect(throws: StoreError.self) {
                    try store.importInvoice(draft: draft(), number: "ODLISNE/31", originalPDF: originalPDF, paidOn: nil)
                }
                #expect(store.invoices.count == 2)
                #expect(try store.pdfData(invoiceID: imported.id) == originalPDF)
            }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.nextNumber == 31)
            #expect(reopened.invoices.last == originalInvoice)
            #expect(try reopened.pdfData(invoiceID: input.id) == originalPDF)
        }
    }

    @Test func confirmedPaidImportWithUnknownDateRemainsPaidAfterReopen() throws {
        try withDirectory { directory in
            let input = try draft()
            let pdf = try InvoicePDFRenderer.render(invoice: IssuedInvoice.issue(draft: input, number: "2026-01"))
            do {
                let store = try AppStore(directory: directory)
                let invoice = try store.importInvoice(draft: input, number: "2026-01", originalPDF: pdf, paidOn: nil, paidWithoutDate: true)
                #expect(store.payments.count == 1)
                #expect(store.payments[0].date == nil)
                #expect(store.payments[0].amount == invoice.total)
                #expect(try invoice.outstanding(payments: store.payments) == 0)
            }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.payments.first?.date == nil)
            #expect(try reopened.invoices[0].outstanding(payments: reopened.payments) == 0)
        }
    }

    @Test func importDeduplicatesClientsWithoutChangingTheirCurrentDetails() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            var input = try draft()
            input.customer.registrationNumber = "87654321"
            let known = Party(name: "Aktuální jméno", registrationNumber: "87654321", address: "Nová adresa")
            try store.saveClient(party: known)
            let pdf = try InvoicePDFRenderer.render(invoice: IssuedInvoice.issue(draft: input, number: "ARCHIV/1"))
            let imported = try store.importInvoice(draft: input, number: "ARCHIV/1", originalPDF: pdf, paidOn: nil)
            #expect(store.clients.count == 1)
            #expect(store.clients.first?.party == known)
            #expect(imported.customer == input.customer)
            #expect(try imported.outstanding(payments: store.payments) == imported.total)
            #expect(store.nextNumber == 12)
            input = try draft()
            let personalPDF = try InvoicePDFRenderer.render(invoice: IssuedInvoice.issue(draft: input, number: "ARCHIV/2"))
            _ = try store.importInvoice(draft: input, number: "ARCHIV/2", originalPDF: personalPDF, paidOn: nil)
            input.id = UUID()
            input.customer.name = "  ODBĚRATEL  "
            input.customer.address = "Brno   1"
            let thirdPDF = try InvoicePDFRenderer.render(invoice: IssuedInvoice.issue(draft: input, number: "ARCHIV/3"))
            _ = try store.importInvoice(draft: input, number: "ARCHIV/3", originalPDF: thirdPDF, paidOn: nil)
            #expect(store.clients.count == 2)
        }
    }

    @Test func failedImportRollsBackMetadataPaymentClientAndPDF() throws {
        enum InjectedFailure: Error { case save }
        try withDirectory { directory in
            let input = try draft()
            let pdf = try InvoicePDFRenderer.render(invoice: IssuedInvoice.issue(draft: input, number: "2026-30"))
            let store = try AppStore(directory: directory, saveContext: { _ in throw InjectedFailure.save })
            #expect(throws: InjectedFailure.self) {
                try store.importInvoice(draft: input, number: "2026-30", originalPDF: pdf, paidOn: input.dueDate)
            }
            #expect(store.invoices.isEmpty)
            #expect(store.payments.isEmpty)
            #expect(store.clients.isEmpty)
            #expect(store.nextNumber == 12)
            #expect(try store.pdfData(invoiceID: input.id) == nil)
            let reopened = try AppStore(directory: directory)
            #expect(reopened.invoices.isEmpty)
            #expect(try reopened.pdfData(invoiceID: input.id) == nil)
        }
    }

    @Test func paymentReversalAndBackupRoundtrip() throws {
        try withDirectory { directory in
            let source = try AppStore(directory: directory.appending(path: "source"))
            let invoice = try source.issue(draft: draft())
            let payment = Payment(invoiceID: invoice.id, date: invoice.issueDate, amount: 100)
            try source.addPayment(payment)
            #expect(try invoice.outstanding(payments: source.payments) == Decimal(string: "270.35"))
            try source.reversePayment(id: payment.id)
            #expect(try invoice.outstanding(payments: source.payments) == invoice.total)
            let pdf = Data("%PDF-1.4\nprobe".utf8)
            try source.savePDF(data: pdf, invoiceID: invoice.id)
            #expect(throws: StoreError.self) { try source.savePDF(data: Data("%PDF-1.4\nchanged".utf8), invoiceID: invoice.id) }
            let target = try AppStore(directory: directory.appending(path: "target"))
            try target.restoreBackup(data: source.exportBackup())
            #expect(target.invoices == [invoice])
            #expect(target.payments == source.payments)
            #expect(try target.pdfData(invoiceID: invoice.id) == pdf)
            #expect(target.needsSequenceConfirmation)
            #expect(throws: StoreError.self) { try target.issue(draft: draft()) }
            #expect(throws: StoreError.self) { try target.issue(draft: draft(), number: "VLASTNI/42") }
            try target.saveSettings(company: Party(name: "Firma"), nextNumber: 13, year: 2026)
            #expect(try target.issue(draft: draft()).number == "2026-13")
            let safetyFiles = try FileManager.default.contentsOfDirectory(at: directory.appending(path: "target"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "fakturabackup" }
            #expect(safetyFiles.count == 1)
        }
    }

    @Test func corruptBackupCannotReplaceActiveData() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            let invoice = try store.issue(draft: draft())
            #expect(throws: (any Error).self) { try store.restoreBackup(data: Data("broken".utf8)) }
            #expect(store.invoices == [invoice])
            #expect(store.nextNumber == 13)
        }
    }

    @Test func modifiedPDFChecksumRejectsWholeRestore() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            let invoice = try store.issue(draft: draft())
            try store.savePDF(data: Data("%PDF-1.4\nprobe".utf8), invoiceID: invoice.id)
            var archive = try #require(JSONSerialization.jsonObject(with: store.exportBackup()) as? [String: Any])
            var documents = try #require(archive["documents"] as? [[String: Any]])
            documents[0]["checksum"] = "tampered"
            archive["documents"] = documents
            let modified = try JSONSerialization.data(withJSONObject: archive)
            #expect(throws: StoreError.self) { try store.restoreBackup(data: modified) }
            #expect(store.invoices == [invoice])
            #expect(!store.needsSequenceConfirmation)
        }
    }

    @Test func restoredOldBackupRequiresExplicitSequenceReconciliationAfterRestart() throws {
        try withDirectory { directory in
            do {
                let store = try AppStore(directory: directory)
                _ = try store.issue(draft: draft())
                let oldBackup = try store.exportBackup()
                #expect(try store.issue(draft: draft()).number == "2026-13")
                try store.restoreBackup(data: oldBackup)
            }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.nextNumber == 13)
            #expect(reopened.needsSequenceConfirmation)
            #expect(throws: StoreError.self) { try reopened.issue(draft: draft()) }
            try reopened.saveSettings(company: reopened.company, nextNumber: 14, year: 2026)
            #expect(try reopened.issue(draft: draft()).number == "2026-14")
        }
    }

    @Test func failedSaveDoesNotPublishOrConsumeInvoiceNumber() throws {
        enum InjectedFailure: Error { case save }
        try withDirectory { directory in
            let input = try draft()
            do {
                var shouldFail = false
                let store = try AppStore(directory: directory, saveContext: { context in
                    if shouldFail { throw InjectedFailure.save }
                    try context.save()
                })
                try store.saveDraft(input)
                shouldFail = true
                #expect(throws: InjectedFailure.self) { try store.issue(draft: input) }
                #expect(store.invoices.isEmpty)
                #expect(store.drafts == [input])
                #expect(store.nextNumber == 12)
            }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.invoices.isEmpty)
            #expect(reopened.nextNumber == 12)
            #expect(try reopened.issue(draft: input).number == "2026-12")
        }
    }

    @Test func exhaustedSequenceFailsWithoutIntegerOverflow() throws {
        try withDirectory { directory in
            do {
                let store = try AppStore(directory: directory)
                try store.saveSettings(company: Party(), nextNumber: Int.max - 1, year: 2026)
                _ = try store.issue(draft: draft())
                #expect(store.nextNumber == Int.max)
                #expect(throws: StoreError.self) { try store.issue(draft: draft()) }
            }
            let reopened = try AppStore(directory: directory)
            #expect(reopened.nextNumber == Int.max)
            #expect(throws: StoreError.self) { try reopened.issue(draft: draft()) }
        }
    }

    @Test func backupWithDuplicateInvoiceNumbersCannotReplaceStore() throws {
        try withDirectory { directory in
            let store = try AppStore(directory: directory)
            _ = try store.issue(draft: draft())
            _ = try store.issue(draft: draft())
            let original = store.invoices
            var archive = try #require(JSONSerialization.jsonObject(with: store.exportBackup()) as? [String: Any])
            var state = try #require(archive["state"] as? [String: Any])
            var invoices = try #require(state["invoices"] as? [[String: Any]])
            invoices[1]["number"] = invoices[0]["number"]
            state["invoices"] = invoices
            archive["state"] = state
            let modified = try JSONSerialization.data(withJSONObject: archive)
            #expect(throws: StoreError.self) { try store.restoreBackup(data: modified) }
            #expect(store.invoices == original)
        }
    }
}
