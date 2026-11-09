import SwiftUI
import AppKit
import PDFKit
import FakturaCore

struct InvoiceDetail: View {
    @ObservedObject var store: AppStore
    let invoice: IssuedInvoice
    let duplicate: (InvoiceDraft) -> Void
    var edit: (IssuedInvoice) -> Void = { _ in }
    var onDeleted: () -> Void = {}
    @State private var pdf: Data?
    @State private var error: String?
    @State private var paymentAmount = ""
    @State private var paymentDate = Date()
    @State private var paymentNote = ""
    @State private var reversal: UUID?
    @State private var confirmDelete = false

    private var payments: [Payment] {
        store.payments.filter { $0.invoiceID == invoice.id }.sorted {
            switch ($0.date, $1.date) {
            case let (left?, right?): left == right ? $0.id.uuidString < $1.id.uuidString : left > right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): $0.id.uuidString < $1.id.uuidString
            }
        }
    }
    private var remaining: Decimal { (try? invoice.outstanding(payments: store.payments)) ?? invoice.total }

    private var overdue: Bool {
        guard let today = try? CalendarDate(date: Date()) else { return false }
        return remaining > 0 && invoice.dueDate < today
    }
    private var status: String {
        if remaining == 0 { return "Uhrazeno" }
        if overdue { return "Po splatnosti" }
        return remaining < invoice.total ? "Částečně uhrazeno" : "Čeká na úhradu"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Dokument", systemImage: "doc.richtext").font(.system(size: 12, weight: .medium)).foregroundStyle(Desk.muted)
                    Spacer()
                    Text("Archivní PDF").font(.system(size: 11)).foregroundStyle(Desk.muted)
                }
                if let pdf {
                    PDFPreview(data: pdf)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Desk.line))
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.badge.arrow.up").font(.system(size: 34)).foregroundStyle(Desk.muted)
                        Text("Dokument čeká na vytvoření").font(.headline)
                        Text("Faktura je bezpečně uložená. Vytvoření PDF můžete zopakovat.")
                            .font(.system(size: 13)).foregroundStyle(Desk.muted).multilineTextAlignment(.center)
                        Button("Vytvořit PDF", action: loadPDF).buttonStyle(DeskPrimaryButton())
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Desk.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Desk.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summary
                    HStack(spacing: 8) {
                        Button(action: exportPDF) { Label("Export PDF", systemImage: "square.and.arrow.up") }
                            .buttonStyle(DeskSecondaryButton()).disabled(pdf == nil)
                        Button(action: printPDF) { Image(systemName: "printer").font(.system(size: 15)) }
                            .buttonStyle(DeskSecondaryButton()).disabled(pdf == nil)
                            .help("Vytisknout fakturu").accessibilityLabel("Vytisknout fakturu")
                    }
                    Divider()
                    paymentHistory
                    if remaining > 0 {
                        Divider()
                        paymentForm
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Divider()
                    Button(action: duplicateInvoice) { Label("Duplikovat do konceptu", systemImage: "doc.on.doc") }
                        .buttonStyle(DeskSecondaryButton())
                    if store.canEditInvoice(id: invoice.id) {
                        Button("Upravit fakturu", systemImage: "pencil") { edit(invoice) }.buttonStyle(DeskSecondaryButton())
                        Button("Smazat fakturu", role: .destructive) { confirmDelete = true }.buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 12))
                    } else {
                        Label("Původní doklad je uzamčený. Pro novou fakturu použijte duplikaci.", systemImage: "lock").font(.system(size: 11)).foregroundStyle(Desk.muted)
                    }
                }.padding(24)
            }.frame(width: 336).background(Desk.surface)
        }.background(Desk.raised)
        .onAppear { loadPDF() }
        .onChange(of: invoice) {
            confirmDelete = false
            pdf = nil
            loadPDF()
        }
        .confirmationDialog("Smazat fakturu \(invoice.number)?", isPresented: $confirmDelete) {
            Button("Smazat fakturu i její úhrady", role: .destructive) {
                do { try store.deleteInvoice(id: invoice.id); onDeleted() }
                catch { self.error = error.localizedDescription }
            }
        } message: { Text("Odstraní se faktura, její PDF i zapsané úhrady. Před smazáním vznikne bezpečnostní kopie. Číselná řada se nevrátí zpět.") }
        .confirmationDialog("Stornovat chybnou úhradu?", isPresented: Binding(get: { reversal != nil }, set: { if !$0 { reversal = nil } })) {
            Button("Stornovat úhradu", role: .destructive) {
                if let id = reversal { perform { try store.reversePayment(id: id) } }
                reversal = nil
            }
        } message: { Text("Původní záznam zůstane zachovaný a částka se vrátí mezi neuhrazené.") }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 6) {
                Text(invoice.number).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                StatusBadge(label: status, color: overdue ? Desk.warning : Desk.muted)
                Text(invoice.customer.name).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(invoice.customer.address).font(.system(size: 12)).foregroundStyle(Desk.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Celková částka").font(.system(size: 12)).foregroundStyle(Desk.muted)
                Text(money(invoice.total)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    .minimumScaleFactor(0.65).lineLimit(1)
            }.padding(.vertical, 3)
            VStack(spacing: 9) {
                infoRow("Zbývá uhradit", value: money(remaining))
                infoRow("Vystaveno", value: dayText(invoice.issueDate))
                infoRow("Splatnost", value: dayText(invoice.dueDate))
                if !invoice.variableSymbol.isEmpty { infoRow("Variabilní symbol", value: invoice.variableSymbol) }
            }
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Desk.muted)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 12))
    }

    private var paymentHistory: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Úhrady").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(payments.filter { $0.reversedAt == nil }.count)").font(.system(size: 12)).foregroundStyle(Desk.muted)
            }
            if payments.isEmpty {
                Text("Zatím žádná zapsaná úhrada.").font(.system(size: 12)).foregroundStyle(Desk.muted)
            } else {
                ForEach(payments) { payment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(money(payment.amount)).font(.system(size: 13, weight: .semibold)).strikethrough(payment.reversedAt != nil)
                            Spacer()
                            Text(payment.date.map(dayText) ?? "Datum neuvedeno").font(.system(size: 11)).foregroundStyle(Desk.muted)
                        }
                        if !payment.note.isEmpty { Text(payment.note).font(.system(size: 11)).foregroundStyle(Desk.muted) }
                        if payment.reversedAt != nil {
                            Text("Stornováno").font(.system(size: 11)).foregroundStyle(Desk.muted)
                        } else {
                            Button("Stornovat úhradu", role: .destructive) { reversal = payment.id }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Desk.muted)
                        }
                    }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
            }
        }
    }

    private var paymentForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Zapsat úhradu").font(.system(size: 14, weight: .semibold))
            DeskField(label: "Částka v Kč", text: $paymentAmount, placeholder: decimalText(remaining))
            DatePicker("Datum úhrady", selection: $paymentDate, displayedComponents: .date)
                .font(.system(size: 12)).datePickerStyle(.field)
            DeskField(label: "Poznámka", text: $paymentNote, placeholder: "Nepovinné")
            Button(action: addPayment) { Label("Potvrdit úhradu", systemImage: "checkmark") }
                .buttonStyle(DeskPrimaryButton())
                .disabled(paymentAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func addPayment() {
        perform {
            let payment = Payment(invoiceID: invoice.id, date: try CalendarDate(date: paymentDate),
                                  amount: try DecimalInput.parse(paymentAmount), note: paymentNote)
            try store.addPayment(payment)
            paymentAmount = ""
            paymentNote = ""
        }
    }

    private func duplicateInvoice() {
        perform {
            let today = try CalendarDate(date: Date())
            let due = try CalendarDate(date: Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date())
            duplicate(InvoiceDraft(supplier: store.company, customer: invoice.customer, lines: invoice.lines,
                                   issueDate: today, dueDate: due, note: invoice.note,
                                   adjustment: invoice.adjustment, adjustmentDescription: invoice.adjustmentDescription,
                                   discountAmount: invoice.discountAmount))
        }
    }
    private func perform(_ action: () throws -> Void) { do { try action(); error = nil } catch { self.error = error.localizedDescription } }
    private func loadPDF() {
        perform {
            if let saved = try store.pdfData(invoiceID: invoice.id) { pdf = saved }
            else {
                let rendered = try InvoicePDFRenderer.render(invoice: invoice)
                try store.savePDF(data: rendered, invoiceID: invoice.id)
                pdf = rendered
            }
        }
    }
    private func exportPDF() {
        guard let pdf else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Faktura-\(invoice.number.replacingOccurrences(of: "/", with: "-" )).pdf"; panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try pdf.write(to: url, options: .atomic) }
    }
    private func printPDF() {
        guard let pdf, let document = PDFDocument(data: pdf), let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else { error = "PDF se nepodařilo připravit k tisku."; return }
        operation.run()
    }
}

struct PDFPreview: NSViewRepresentable {
    let data: Data

    final class Coordinator {
        var data: Data?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
    }
}
