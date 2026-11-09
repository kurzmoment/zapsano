import SwiftUI
import AppKit
import FakturaCore

private struct InvoiceEditorContext: Identifiable {
    var id: UUID { draft.id }
    let draft: InvoiceDraft
    var issuedID: UUID? = nil
}

struct RootView: View {
    @ObservedObject var store: AppStore
    @State private var section = "Faktury"
    @State private var selectedInvoice: IssuedInvoice?
    @State private var editor: InvoiceEditorContext?
    @State private var pendingInvoiceID: UUID?
    @State private var pendingDraft: InvoiceEditorContext?
    @State private var pendingDraftDeletion: UUID?
    @State private var newInvoice = false
    @State private var importing = false
    @State private var error: String?
    @State private var filter = "Všechny"
    @State private var search = ""
    @State private var page = 0
    @State private var pendingRestore: Data?
    @AppStorage("appearance") private var appearance = "light"
    private let pageSize = 50

    private var balances: [UUID: Decimal] {
        let paid = store.payments.filter { $0.reversedAt == nil }.reduce(into: [UUID: Decimal]()) { $0[$1.invoiceID, default: 0] += $1.amount }
        return Dictionary(uniqueKeysWithValues: store.invoices.map { ($0.id, $0.total - paid[$0.id, default: 0]) })
    }
    private var filtered: [IssuedInvoice] {
        let balances = balances
        return store.invoices.filter { invoice in
            let remaining = balances[invoice.id, default: invoice.total]
            let matchesStatus = filter == "Všechny" || (filter == "Neuhrazené" && remaining > 0)
                || (filter == "Uhrazené" && remaining == 0) || (filter == "Po splatnosti" && remaining > 0 && overdue(invoice))
            return matchesStatus && (search.isEmpty || "\(invoice.number) \(invoice.customer.name)".localizedStandardContains(search))
        }.sorted { $0.issueDate == $1.issueDate ? $0.number.localizedStandardCompare($1.number) == .orderedDescending : $0.issueDate > $1.issueDate }
    }
    private func overdue(_ invoice: IssuedInvoice) -> Bool { invoice.dueDate.date() < Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch section {
                case "Přehled": overview
                case "Klienti": ClientsView(store: store)
                case "Ceník": CatalogView(store: store)
                case "Nastavení": SettingsView(store: store, backup: exportBackup, restore: chooseRestore)
                default: invoicesView
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Desk.canvas).tint(Desk.accent)
        .onChange(of: store.invoices) {
            if let id = selectedInvoice?.id {
                selectedInvoice = store.invoices.first { $0.id == id }
            }
        }
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
        .sheet(isPresented: $newInvoice, onDismiss: presentIssued) { InvoiceEditor(store: store, existing: nil, onIssued: showIssued) }
        .sheet(item: $editor, onDismiss: presentIssued) { context in InvoiceEditor(store: store, existing: context.draft, editingInvoiceID: context.issuedID, onIssued: showIssued) }
        .sheet(item: $selectedInvoice, onDismiss: { if let draft = pendingDraft { pendingDraft = nil; editor = draft } }) { invoice in
            VStack(spacing: 0) {
                HStack { Text("Detail faktury").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary); Spacer(); Button("Zavřít", systemImage: "xmark") { selectedInvoice = nil }.buttonStyle(DeskSecondaryButton()).keyboardShortcut(.cancelAction) }.padding(.horizontal, 24).padding(.vertical, 12)
                Divider()
                InvoiceDetail(store: store, invoice: invoice, duplicate: { draft in
                    pendingDraft = InvoiceEditorContext(draft: draft); selectedInvoice = nil
                }, edit: { invoice in
                    pendingDraft = InvoiceEditorContext(draft: invoice.editableDraft(), issuedID: invoice.id); selectedInvoice = nil
                }, onDeleted: { selectedInvoice = nil })
            }.frame(width: 1040, height: min(720, (NSScreen.main?.visibleFrame.height ?? 900) - 100)).background(Desk.canvas)
        }
        .sheet(isPresented: $importing) { ImportInvoicesView(store: store) }
        .alert("Operaci se nepodařilo dokončit", isPresented: errorPresented) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .confirmationDialog("Nahradit současná data zálohou?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button("Obnovit zálohu", role: .destructive) {
                guard let data = pendingRestore else { return }
                perform { try store.restoreBackup(data: data); selectedInvoice = nil; page = 0; section = "Nastavení" }
                pendingRestore = nil
            }
        } message: { Text("Nejdříve se vytvoří bezpečnostní kopie. Po obnově zkontrolujte číslování podle poslední skutečně vydané faktury.") }
        .confirmationDialog("Smazat koncept?", isPresented: Binding(get: { pendingDraftDeletion != nil }, set: { if !$0 { pendingDraftDeletion = nil } })) {
            Button("Smazat koncept", role: .destructive) { if let id = pendingDraftDeletion { perform { try store.deleteDraft(id: id) } }; pendingDraftDeletion = nil }
        } message: { Text("Koncept se odstraní. Před smazáním se uloží bezpečnostní kopie dat.") }
        .frame(minWidth: 1120, minHeight: 680)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark().frame(width: 28, height: 28)
                Text(Brand.name).font(.system(size: 21, weight: .semibold))
            }.padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(store.company.name.isEmpty ? "Vaše podnikání" : store.company.name)
                    .font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text(store.company.registrationNumber.isEmpty ? "Nastavte údaje dodavatele" : "IČO \(store.company.registrationNumber)")
                    .font(.system(size: 11)).foregroundStyle(Desk.muted)
            }.padding(.horizontal, 22).padding(.bottom, 24)
            nav("Přehled", icon: "chart.bar.xaxis")
            nav("Faktury", icon: "doc.text")
            nav("Klienti", icon: "person.2")
            nav("Ceník", icon: "list.bullet.rectangle")
            Spacer()
            Button { importing = true } label: {
                Label("Import faktur", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 36)
            }.buttonStyle(.plain).foregroundStyle(Desk.muted).padding(.horizontal, 12).padding(.bottom, 4)
            nav("Nastavení", icon: "slider.horizontal.3")
            Divider().padding(.horizontal, 22).padding(.vertical, 16)
            Label("Uloženo na tomto Macu", systemImage: "internaldrive")
                .font(.system(size: 11)).foregroundStyle(Desk.muted).padding(.horizontal, 22).padding(.bottom, 22)
        }.frame(width: 230).background(Desk.canvas)
    }
    private func nav(_ title: String, icon: String) -> some View {
        Button { section = title } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                Text(title).font(.system(size: 13, weight: section == title ? .medium : .regular))
                Spacer()
            }.padding(.horizontal, 12).frame(height: 36)
                .foregroundStyle(section == title ? Color.primary : Desk.muted)
                .background(section == title ? Desk.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
            .accessibilityAddTraits(section == title ? .isSelected : [])
    }
    private var overview: some View {
        let currentBalances = balances
        let pending = store.invoices.filter { currentBalances[$0.id, default: $0.total] > 0 }.sorted { $0.dueDate < $1.dueDate }
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { DeskHeading(title: "Přehled", subtitle: "Vystavené faktury a pohledávky k dnešnímu dni"); Spacer(); newButton }
                metrics
                if store.company.name.isEmpty {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Doplňte údaje dodavatele").font(.system(size: 14, weight: .medium))
                            Text("Načtěte firmu podle IČO a nastavte účet pro první fakturu.").font(.system(size: 12)).foregroundStyle(Desk.muted)
                        }
                        Spacer()
                        Button("Nastavit firmu") { section = "Nastavení" }.buttonStyle(DeskSecondaryButton())
                    }.padding(20).background(Desk.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Čeká na úhradu").font(.system(size: 15, weight: .semibold))
                        Text("\(pending.count)").font(.system(size: 12)).foregroundStyle(Desk.muted)
                        Spacer()
                        if !pending.isEmpty { Button("Všechny pohledávky") { filter = "Neuhrazené"; section = "Faktury" }.buttonStyle(.link) }
                    }
                    if pending.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle").foregroundStyle(Desk.muted)
                            Text(store.invoices.isEmpty ? "Pohledávky se objeví po vystavení první faktury." : "Všechny vystavené faktury jsou uhrazené.")
                                .font(.system(size: 13)).foregroundStyle(Desk.muted)
                            Spacer()
                        }.padding(20).background(Desk.surface, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        VStack(spacing: 0) { tableHeader; invoiceRows(Array(pending.prefix(5))) }
                            .background(Desk.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Poslední doklady").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button("Všechny faktury") { filter = "Všechny"; section = "Faktury" }.buttonStyle(.link)
                    }
                    VStack(spacing: 0) {
                        if store.invoices.isEmpty { emptyInvoices }
                        else { invoiceRows(Array(store.invoices.sorted { $0.issueDate > $1.issueDate }.prefix(4))) }
                    }.background(Desk.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(24)
        }.background(Desk.canvas)
    }
    private var newButton: some View {
        Button("Nová faktura", systemImage: "plus") { newInvoice = true }
            .buttonStyle(DeskPrimaryButton()).keyboardShortcut("n", modifiers: .command)
    }
    private var metrics: some View {
        let balances = balances
        let unpaid = store.invoices.reduce(Decimal.zero) { $0 + balances[$1.id, default: $1.total] }
        let late = store.invoices.filter(overdue).reduce(Decimal.zero) { $0 + balances[$1.id, default: $1.total] }
        return HStack(spacing: 0) {
            metric("Zbývá uhradit", value: unpaid, detail: "Ze všech vystavených faktur", color: unpaid > 0 ? Desk.accent : Desk.muted, prominent: true)
            Divider().padding(.vertical, 20)
            metric("Po splatnosti", value: late, detail: "K dnešnímu dni", color: late > 0 ? Desk.warning : Desk.muted)
            Divider().padding(.vertical, 20)
            metric("Celkem vystaveno", value: store.invoices.reduce(0) { $0 + $1.total }, detail: "\(store.invoices.count) dokladů v evidenci", color: .primary)
        }.frame(height: 112).background(Desk.surface, in: RoundedRectangle(cornerRadius: 8))
    }
    private func metric(_ title: String, value: Decimal, detail: String, color: Color, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12)).foregroundStyle(Desk.muted)
            Text(money(value)).font(.system(size: prominent ? 29 : 22, weight: .semibold))
                .monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.75)
            Text(detail).font(.system(size: 11)).foregroundStyle(Desk.muted)
        }.padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var invoicesView: some View {
        let rows = filtered
        let currentBalances = balances
        let remaining = rows.reduce(Decimal.zero) { $0 + currentBalances[$1.id, default: $1.total] }
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                DeskHeading(title: "Faktury", subtitle: "\(store.invoices.count) vystavených dokladů · \(store.drafts.count) konceptů")
                Spacer()
                Button("Import PDF", systemImage: "square.and.arrow.down") { importing = true }.buttonStyle(DeskSecondaryButton())
                newButton
            }
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    HStack(spacing: 0) {
                        ForEach(["Všechny", "Neuhrazené", "Po splatnosti", "Uhrazené", "Koncepty"], id: \.self) { value in
                            Button { filter = value } label: {
                                VStack(spacing: 10) {
                                    Text(value).font(.system(size: 12, weight: filter == value ? .medium : .regular))
                                        .foregroundStyle(filter == value ? Color.primary : Desk.muted)
                                    Rectangle().fill(filter == value ? Desk.primary : .clear).frame(height: 2)
                                }.padding(.horizontal, 10).padding(.top, 10)
                            }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
                        }
                    }
                    Spacer(minLength: 0)
                    DeskSearchField(placeholder: "Číslo nebo odběratel", text: $search).frame(width: 215).padding(.bottom, 5)
                }
                Divider()
            }
            if filter == "Koncepty" { draftsView }
            else {
                HStack(spacing: 10) {
                    Text("\(rows.count) dokladů").foregroundStyle(Desk.muted)
                    Text("·").foregroundStyle(Desk.muted)
                    Text("Zbývá uhradit \(money(remaining))").monospacedDigit()
                    Spacer()
                }.font(.system(size: 12))
                VStack(spacing: 0) {
                    tableHeader
                    Divider()
                    ScrollView { LazyVStack(spacing: 0) { invoiceRows(Array(rows.dropFirst(page * pageSize).prefix(pageSize))) } }
                        .overlay { if rows.isEmpty { emptyInvoices } }
                    Divider()
                    HStack {
                        Text(rows.isEmpty ? "0 dokladů" : "\(page * pageSize + 1)–\(min((page + 1) * pageSize, rows.count)) z \(rows.count) dokladů").foregroundStyle(Desk.muted)
                        Spacer()
                        if rows.count > pageSize {
                            Button("Předchozí") { page -= 1 }.disabled(page == 0)
                            Text("\(page + 1)").monospacedDigit()
                            Button("Další") { page += 1 }.disabled((page + 1) * pageSize >= rows.count)
                        }
                    }.font(.system(size: 11)).padding(.horizontal, 16).frame(height: 40)
                }.background(Desk.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Desk.line))
            }
        }.padding(24).background(Desk.canvas)
            .onChange(of: search) { page = 0 }.onChange(of: filter) { page = 0 }
            .onChange(of: rows.map(\.id)) { page = min(page, max(0, (rows.count - 1) / pageSize)) }
    }
    private var draftsView: some View {
        let drafts = store.drafts.filter { search.isEmpty || $0.customer.name.localizedStandardContains(search) || ($0.requestedNumber ?? "").localizedStandardContains(search) }
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(drafts) { draft in
                    Button { editor = InvoiceEditorContext(draft: draft) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "pencil").foregroundStyle(Desk.muted)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.customer.name.isEmpty ? "Rozpracovaná faktura" : draft.customer.name).font(.system(size: 13, weight: .medium))
                                Text("Koncept · \(dayText(draft.issueDate))").font(.system(size: 11)).foregroundStyle(Desk.muted)
                            }
                            Spacer()
                            Text(draft.requestedNumber ?? "Bez čísla").font(.system(size: 12)).foregroundStyle(Desk.muted)
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Desk.muted)
                        }.padding(16).contentShape(Rectangle())
                    }.buttonStyle(.plain).contextMenu { Button("Smazat koncept", role: .destructive) { pendingDraftDeletion = draft.id } }
                    Divider()
                }
                if drafts.isEmpty { ContentUnavailableView("Žádné odpovídající koncepty", systemImage: "pencil", description: Text("Rozpracovanou fakturu můžete kdykoliv uložit jako koncept.")) }
            }.background(Desk.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("Číslo").frame(width: 94, alignment: .leading)
            Text("Odběratel").frame(maxWidth: .infinity, alignment: .leading)
            Text("Splatnost").frame(width: 85, alignment: .trailing)
            Text("Stav").frame(width: 112, alignment: .leading)
            Text("Celkem").frame(width: 124, alignment: .trailing)
            Spacer().frame(width: 10)
        }.font(.system(size: 11)).foregroundStyle(Desk.muted).padding(.horizontal, 16).frame(height: 36)
    }
    private func invoiceRows(_ invoices: [IssuedInvoice]) -> some View {
        let balances = balances
        return ForEach(invoices) { invoice in
            let remaining = balances[invoice.id, default: invoice.total]
            Button { selectedInvoice = invoice } label: {
                HStack(spacing: 12) {
                    Text(invoice.number).font(.system(size: 13, weight: .medium)).lineLimit(1).help(invoice.number).frame(width: 94, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(invoice.customer.name).font(.system(size: 13)).lineLimit(1).help(invoice.customer.name)
                        Text("Vystaveno \(dayText(invoice.issueDate))").font(.system(size: 11)).foregroundStyle(Desk.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(dayText(invoice.dueDate)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Desk.muted).frame(width: 85, alignment: .trailing)
                    StatusBadge(label: remaining == 0 ? "Uhrazeno" : (overdue(invoice) ? "Po splatnosti" : (remaining < invoice.total ? "Část uhrazena" : "Neuhrazeno")),
                                color: remaining > 0 && overdue(invoice) ? Desk.warning : Desk.muted).frame(width: 112, alignment: .leading)
                    Text(money(invoice.total)).font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(width: 124, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Desk.muted).frame(width: 10)
                }.padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider()
        }
    }
    private var emptyInvoices: some View {
        let firstRun = store.invoices.isEmpty
        return VStack(spacing: 12) {
            Text(firstRun ? "Zatím žádné faktury" : "Žádné odpovídající faktury").font(.system(size: 16, weight: .medium))
            Text(firstRun ? "Vystavte první doklad nebo importujte dosavadní PDF." : "Změňte hledání nebo vyberte jiný stav úhrady.")
                .font(.system(size: 12)).foregroundStyle(Desk.muted)
            if firstRun {
                HStack { Button("Nová faktura") { newInvoice = true }.buttonStyle(DeskSecondaryButton()); Button("Importovat PDF") { importing = true }.buttonStyle(DeskSecondaryButton()) }
            } else { Button("Zrušit filtry") { search = ""; filter = "Všechny" }.buttonStyle(DeskSecondaryButton()) }
        }.padding(32).frame(maxWidth: .infinity)
    }
    private var errorPresented: Binding<Bool> { Binding(get: { error != nil }, set: { if !$0 { error = nil } }) }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    private func showIssued(_ id: UUID) { section = "Faktury"; pendingInvoiceID = id }
    private func presentIssued() { if let id = pendingInvoiceID { pendingInvoiceID = nil; selectedInvoice = store.invoices.first { $0.id == id } } }
    private func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = Brand.name + "-zaloha.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }; perform { try store.exportBackup().write(to: url, options: .atomic) }
    }
    private func chooseRestore() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }; perform { pendingRestore = try Data(contentsOf: url) }
    }
}
