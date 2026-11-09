import SwiftUI
import FakturaCore

private struct LineInput: Identifiable {
    var id: UUID
    var title: String
    var quantity: String
    var unit: String
    var price: String
    init(_ line: InvoiceLine = InvoiceLine()) {
        id = line.id; title = line.description; quantity = decimalText(line.quantity); unit = line.unit; price = decimalText(line.unitPrice)
    }
    func value() throws -> InvoiceLine {
        InvoiceLine(id: id, description: title, quantity: try DecimalInput.parse(quantity), unit: unit, unitPrice: try DecimalInput.parse(price))
    }
    var total: String { (try? value().total()).map(money) ?? "—" }
}

struct InvoiceEditor: View {
    @ObservedObject var store: AppStore
    let existing: InvoiceDraft?
    var editingInvoiceID: UUID? = nil
    var onIssued: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var draftID = UUID()
    @State private var customer = Party()
    @State private var supplier = Party()
    @State private var selectedClient: UUID?
    @State private var lines = [LineInput()]
    @State private var issued = Date()
    @State private var due = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    @State private var note = ""
    @State private var symbol = ""
    @State private var constantSymbol = "0308"
    @State private var paymentTerms = InvoiceTextDefaults.paymentTerms
    @State private var number = ""
    @State private var discount = "0"
    @State private var error: String?
    @State private var confirmIssue = false
    @State private var confirmClose = false
    @State private var previewPDF: Data?
    @State private var initialized = false
    @State private var choosingCatalogItem = false
    @State private var catalogFeedback: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DeskHeading(title: editingInvoiceID != nil ? "Upravit fakturu" : (existing == nil ? "Nová faktura" : "Upravit koncept"), subtitle: editingInvoiceID != nil ? "Změny uložíme včetně aktualizovaného PDF. Předchozí stav zůstane v bezpečnostní kopii." : "Odběratel, položky a hotovo. Údaje dodavatele se doplní z nastavení.")
                Spacer(); StatusBadge(label: editingInvoiceID == nil ? "Koncept" : "Úprava dokladu", color: .secondary)
            }.padding(.horizontal, 30).padding(.vertical, 24)
            Divider()
            ScrollView {
              HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 20) {
                        DeskCard(title: "Odběratel") {
                            if !store.clients.filter({ !$0.archived }).isEmpty {
                                Picker("Z adresáře", selection: $selectedClient) {
                                    Text("Vybrat existujícího klienta…").tag(Optional<UUID>.none)
                                    ForEach(store.clients.filter { !$0.archived }) { client in Text(client.party.name).tag(Optional(client.id)) }
                                }.onChange(of: selectedClient) { if let client = store.clients.first(where: { $0.id == selectedClient }) { customer = client.party } }
                            }
                            PartyFields(party: $customer)
                        }
                        DeskCard(title: "Text nad položkami", subtitle: "Volitelný úvodní text na této faktuře.") {
                            TextField("Fakturuji Vám za…", text: $note, axis: .vertical).lineLimit(2...5).textFieldStyle(.plain).font(.system(size: 13))
                                .accessibilityLabel("Text nad položkami")
                        }
                        DeskCard(title: "Co fakturujete") {
                            HStack {
                                Button("Vybrat z ceníku", systemImage: "list.bullet.rectangle") { choosingCatalogItem = true }.buttonStyle(DeskSecondaryButton())
                                Spacer()
                                if let catalogFeedback { Text(catalogFeedback).font(.system(size: 11)).foregroundStyle(Desk.accent) }
                            }
                            HStack(spacing: 8) {
                                Text("POPIS").frame(maxWidth: .infinity, alignment: .leading)
                                Text("MNOŽ.").frame(width: 50)
                                Text("JEDN.").frame(width: 40)
                                Text("CENA / JEDN.").frame(width: 90, alignment: .trailing)
                                Spacer().frame(width: 24)
                            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            ForEach($lines) { $line in
                                VStack(spacing: 6) {
                                    HStack(alignment: .top, spacing: 8) {
                                        TextField("Popis služby nebo zboží", text: $line.title, axis: .vertical).lineLimit(1...4).frame(maxWidth: .infinity).accessibilityLabel("Popis položky")
                                        TextField("1", text: $line.quantity).frame(width: 50).accessibilityLabel("Množství")
                                        TextField("ks", text: $line.unit).frame(width: 40).accessibilityLabel("Jednotka")
                                        TextField("0,00", text: $line.price).multilineTextAlignment(.trailing).frame(width: 90).accessibilityLabel("Jednotková cena v CZK")
                                        Button(role: .destructive) { lines.removeAll { $0.id == line.id } } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }.buttonStyle(.plain).frame(width: 24).accessibilityLabel("Odebrat položku")
                                    }.textFieldStyle(.roundedBorder).font(.system(size: 13))
                                    HStack {
                                        Button("Uložit do ceníku") { saveToCatalog(line) }.buttonStyle(.link).font(.system(size: 11))
                                            .help("Uloží popis, jednotku a jednotkovou cenu pro příští faktury.")
                                        Spacer()
                                        Text(line.total).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().padding(.trailing, 32)
                                    }
                                }
                            }
                            Button("Přidat položku", systemImage: "plus") { lines.append(LineInput()) }.buttonStyle(.link).font(.system(size: 12))
                        }
                        if editingInvoiceID != nil {
                            DeskCard(title: "Dodavatel") {
                                DisclosureGroup("Upravit údaje na této faktuře") { PartyFields(party: $supplier, supplier: true).padding(.top, 12) }
                            }
                        }
                        DeskCard(title: "Stálá poznámka o prodlení") {
                            Text(paymentTerms).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }.padding(.bottom, 20)
                VStack(spacing: 18) {
                    DeskCard(title: "Doklad") {
                        DeskField(label: "Číslo faktury", text: $number, placeholder: store.nextInvoiceNumber)
                        Text("Můžete přepsat. Duplicity ohlídáme.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        DatePicker("Vystavení", selection: $issued, displayedComponents: .date).font(.system(size: 12))
                        DatePicker("Splatnost", selection: $due, displayedComponents: .date).font(.system(size: 12))
                        DeskField(label: "Variabilní symbol", text: $symbol, placeholder: number.filter(\.isNumber))
                        DeskField(label: "Konstantní symbol", text: $constantSymbol, placeholder: "0308")
                    }
                    DeskCard(title: "K úhradě") {
                        DeskField(label: "Sleva v Kč", text: $discount, placeholder: "0,00")
                        Text("Zadejte přesnou částku, kterou odečteme z faktury.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Text(previewTotal).font(.system(size: 27, weight: .semibold)).foregroundStyle(Desk.accent).monospacedDigit()
                        Text("CZK · Nejste plátce DPH").font(.system(size: 11)).foregroundStyle(.secondary)
                        if let adjustment = existing?.adjustment, adjustment != 0, existing?.discountAmount != nil || adjustment > 0 {
                            Text("\(existing?.adjustmentDescription ?? "Úprava částky"): \(money(adjustment))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if supplier.name.isEmpty {
                        Label("Nejprve vyplňte svou firmu v Nastavení. Koncept můžete uložit už teď.", systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 5) { Text("DODAVATEL").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); Text(supplier.name).font(.system(size: 12, weight: .medium)); Text("IČO \(supplier.registrationNumber)").font(.system(size: 11)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    }
                    }.frame(width: 270)
              }.padding(.horizontal, 30).padding(.vertical, 24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error { Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red) }
                HStack {
                    Button("Zavřít") { confirmClose = true }.buttonStyle(DeskSecondaryButton()).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Náhled PDF", systemImage: "doc.text.magnifyingglass", action: showPreview).buttonStyle(DeskSecondaryButton())
                    if editingInvoiceID == nil { Button("Uložit koncept") { save(issue: false) }.buttonStyle(DeskSecondaryButton()) }
                    Button(editingInvoiceID == nil ? "Vystavit fakturu" : "Uložit změny") {
                        do { _ = try validatedInvoice(); error = nil; confirmIssue = true } catch { self.error = error.localizedDescription }
                    }.buttonStyle(DeskPrimaryButton())
                }
            }.padding(.horizontal, 30).padding(.vertical, 18).background(Desk.surface)
        }.frame(width: 1040, height: min(720, (NSScreen.main?.visibleFrame.height ?? 900) - 100)).background(Desk.canvas)
        .interactiveDismissDisabled()
        .onAppear {
            guard !initialized else { return }
            initialized = true
            number = store.nextInvoiceNumber
            supplier = editingInvoiceID == nil ? store.company : (existing?.supplier ?? store.company)
            discount = decimalText(existing?.discountAmount ?? max(0, -(existing?.adjustment ?? 0)))
            paymentTerms = existing?.paymentTerms ?? InvoiceTextDefaults.paymentTerms
            constantSymbol = existing?.constantSymbol ?? "0308"
            if let existing {
                draftID = existing.id; customer = existing.customer; lines = existing.lines.map(LineInput.init)
                issued = existing.issueDate.date(); due = existing.dueDate.date(); note = existing.note; symbol = existing.variableSymbol
                if let requested = existing.requestedNumber { number = requested }
            }
        }
        .sheet(isPresented: Binding(get: { previewPDF != nil }, set: { if !$0 { previewPDF = nil } })) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Náhled faktury \(number)").font(.headline)
                        Text("Náhled nic neukládá ani nerezervuje číslo faktury.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Zavřít náhled") { previewPDF = nil }.buttonStyle(DeskSecondaryButton()).keyboardShortcut(.cancelAction)
                }.padding(20)
                Divider()
                if let previewPDF { PDFPreview(data: previewPDF) }
            }.frame(width: 800, height: min(760, (NSScreen.main?.visibleFrame.height ?? 900) - 100)).background(Desk.canvas)
        }
        .sheet(isPresented: $choosingCatalogItem) {
            CatalogPickerView(store: store, select: insertCatalogItem)
        }
        .confirmationDialog(editingInvoiceID == nil ? "Vystavit fakturu \(number)?" : "Uložit změny faktury \(number)?", isPresented: $confirmIssue) {
            Button(editingInvoiceID == nil ? "Vystavit fakturu" : "Uložit změny") { save(issue: true) }
        } message: { Text("\(customer.name) · \(previewTotal)\nDoklad bude uložený s tímto číslem a údaji.") }
        .confirmationDialog("Zavřít editor?", isPresented: $confirmClose) {
            if editingInvoiceID == nil { Button("Uložit koncept a zavřít") { save(issue: false) } }
            Button("Zahodit neuložené změny", role: .destructive) { dismiss() }
        } message: { Text("Neuložené změny se při zavření ztratí.") }
    }
    private var previewTotal: String { (try? makeDraft().total()).map(money) ?? "—" }
    private func insertCatalogItem(_ item: CatalogItem) {
        let input = LineInput(InvoiceLine(description: item.description, quantity: 1, unit: item.unit, unitPrice: item.unitPrice))
        if let index = lines.firstIndex(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (try? DecimalInput.parse($0.price)) == 0 && (try? DecimalInput.parse($0.quantity)) == 1
        }) { lines[index] = input }
        else { lines.append(input) }
        catalogFeedback = "Položka vložena do faktury."
    }
    private func saveToCatalog(_ line: LineInput) {
        do {
            let item = CatalogItem(description: line.title, unit: line.unit, unitPrice: try DecimalInput.parse(line.price))
            try store.saveCatalogItem(item)
            catalogFeedback = "Položka je uložená v ceníku."
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func validatedInvoice() throws -> IssuedInvoice {
        try IssuedInvoice.issue(draft: makeDraft(), number: number)
    }
    private func showPreview() {
        do {
            previewPDF = try InvoicePDFRenderer.render(invoice: validatedInvoice())
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func makeDraft() throws -> InvoiceDraft {
        var draft = try InvoiceDraft(id: draftID, supplier: supplier, customer: customer, lines: lines.map { try $0.value() }, issueDate: CalendarDate(date: issued), dueDate: CalendarDate(date: due), note: note, variableSymbol: symbol)
        draft.paymentTerms = paymentTerms
        draft.constantSymbol = constantSymbol
        let discountValue = try DecimalInput.parse(discount)
        guard discountValue >= 0, BillingMath.rounded(discountValue) == discountValue else { throw EditorError.invalidDiscount }
        let carriedAdjustment = existing?.discountAmount != nil ? (existing?.adjustment ?? 0) : max(0, existing?.adjustment ?? 0)
        draft.discountAmount = discountValue
        draft.adjustment = carriedAdjustment == 0 ? nil : carriedAdjustment
        draft.adjustmentDescription = carriedAdjustment == 0 ? nil : existing?.adjustmentDescription
        draft.requestedNumber = number == store.nextInvoiceNumber ? nil : number
        return draft
    }
    private func save(issue: Bool) {
        do {
            let draft = try makeDraft()
            if issue {
                let invoice: IssuedInvoice
                if let id = editingInvoiceID { invoice = try store.updateInvoice(id: id, draft: draft, number: number, expectedDraft: existing) }
                else { invoice = try store.issue(draft: draft, number: number) }
                onIssued(invoice.id); dismiss()
            }
            else { try store.saveDraft(draft); dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}

enum EditorError: LocalizedError {
    case invalidDiscount
    var errorDescription: String? { "Slevu zadejte jako kladnou částku v Kč s nejvýše dvěma desetinnými místy." }
}
