import Foundation
import Testing
@testable import PersistenceProbe

@MainActor
struct StoreTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func decimalSurvivesReopen() throws {
        try withDirectory { directory in
            let url = directory.appending(path: "store.sqlite")
            let values = ["0.1", "123456789012345678.123456789", "-0.00000001", "999999999999.99"]
            do {
                let store = try ProbeStore(url: url)
                for value in values { _ = try store.create(amount: #require(Decimal(string: value))) }
            }
            let reopened = try ProbeStore(url: url)
            #expect(Set(try reopened.invoices().map(\.amount)) == Set(values))
        }
    }

    @Test func issueAndSequenceSurviveTogether() throws {
        try withDirectory { directory in
            let url = directory.appending(path: "store.sqlite")
            let id: UUID
            do {
                let store = try ProbeStore(url: url)
                id = try store.create(amount: 100)
                #expect(try store.issue(id: id) == 1)
                #expect(throws: ProbeError.self) { try store.issue(id: id) }
                #expect(try store.nextNumber() == 2)
            }
            let reopened = try ProbeStore(url: url)
            #expect(try reopened.invoices().first?.number == 1)
            #expect(try reopened.nextNumber() == 2)
            #expect(throws: ProbeError.self) { try reopened.issue(id: id) }
        }
    }

    @Test func failureRollsBackBothMutations() throws {
        try withDirectory { directory in
            let url = directory.appending(path: "store.sqlite")
            let id: UUID
            do {
                let store = try ProbeStore(url: url)
                id = try store.create(amount: 100)
                #expect(throws: ProbeError.self) { try store.issue(id: id, failBeforeSave: true) }
                #expect(try store.invoices().first?.number == nil)
                #expect(try store.nextNumber() == 1)
            }
            let reopened = try ProbeStore(url: url)
            #expect(try reopened.invoices().first?.number == nil)
            #expect(try reopened.nextNumber() == 1)
            #expect(try reopened.issue(id: id) == 1)
        }
    }

    @Test func backupRestoresIntoCleanStore() throws {
        try withDirectory { directory in
            let source = try ProbeStore(url: directory.appending(path: "source.sqlite"))
            let id = try source.create(amount: #require(Decimal(string: "123.45")))
            _ = try source.issue(id: id)
            _ = try source.create(amount: 7)
            let data = try source.backup()
            let target = try ProbeStore(url: directory.appending(path: "target.sqlite"))
            try target.restore(data)
            #expect(try target.invoices().count == 2)
            #expect(try target.invoices().first(where: { $0.id == id })?.amount == "123.45")
            #expect(try target.nextNumber() == 2)
            #expect(throws: ProbeError.self) { try target.restore(data) }
        }
    }

    @Test func invalidBackupLeavesStagingStoreEmpty() throws {
        try withDirectory { directory in
            let row = ProbeBackup.Invoice(id: UUID(), number: 1, amount: "10")
            let data = try JSONEncoder().encode(ProbeBackup(version: 1, nextNumber: 1, invoices: [row]))
            let target = try ProbeStore(url: directory.appending(path: "target.sqlite"))
            #expect(throws: ProbeError.self) { try target.restore(data) }
            #expect(try target.invoices().isEmpty)
        }
    }
}
