import SwiftUI
import FakturaCore

private func matchingCatalogItems(_ items: [CatalogItem], query: String) -> [CatalogItem] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return items.filter { query.isEmpty || "\($0.description) \($0.unit)".localizedStandardContains(query) }
        .sorted { $0.description.localizedStandardCompare($1.description) == .orderedAscending }
}

private struct CatalogItemLabel: View {
    let item: CatalogItem
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.description).font(.system(size: 14, weight: .medium)).lineLimit(2)
                Text(item.unit.isEmpty ? "Bez jednotky" : "Jednotka: \(item.unit)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(unitRate(item.unitPrice)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

struct CatalogView: View {
    @ObservedObject var store: AppStore
    @State private var search = ""
    @State private var editor: CatalogItem?
    @State private var deleting: CatalogItem?
    @State private var error: String?
    private var items: [CatalogItem] { matchingCatalogItems(store.catalogItems, query: search) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                DeskHeading(title: "Ceník", subtitle: "Popisy, jednotky a sazby připravené pro další fakturu.")
                Spacer()
                Button("Nová položka", systemImage: "plus") {
                    editor = CatalogItem(description: "", unit: "hod", unitPrice: 0)
                }.buttonStyle(DeskPrimaryButton())
            }
            HStack {
                DeskSearchField(placeholder: "Hledat v ceníku", text: $search).frame(width: 280)
                Spacer()
                Text("\(items.count) položek").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("Položku vložíte do faktury přes Vybrat z ceníku. Změny ceníku nemění dříve vystavené doklady.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
            if items.isEmpty {
                ContentUnavailableView(store.catalogItems.isEmpty ? "Ceník je zatím prázdný" : "Žádná odpovídající položka", systemImage: "list.bullet.rectangle", description: Text(store.catalogItems.isEmpty ? "Přidejte službu nebo zboží s jednotkou a sazbou. Položky můžete uložit také přímo při psaní faktury." : "Zkuste jiný název nebo jednotku."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            HStack(spacing: 16) {
                                Button { editor = item } label: { CatalogItemLabel(item: item) }.buttonStyle(.plain)
                                Button { editor = item } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("Upravit položku").accessibilityLabel("Upravit \(item.description)")
                                Button(role: .destructive) { deleting = item } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Smazat z ceníku").accessibilityLabel("Smazat \(item.description)")
                            }.padding(.horizontal, 16).padding(.vertical, 8)
                            Divider()
                        }
                    }
                }.background(Desk.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Desk.line))
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Desk.canvas)
        .sheet(item: $editor) { item in
            CatalogItemForm(item: item, isNew: !store.catalogItems.contains(where: { $0.id == item.id })) { try store.saveCatalogItem($0) }
        }
        .confirmationDialog("Smazat položku z ceníku?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Smazat položku", role: .destructive) {
                guard let item = deleting else { return }
                do { try store.deleteCatalogItem(id: item.id); error = nil } catch { self.error = error.localizedDescription }
                deleting = nil
            }
        } message: { Text("\(deleting?.description ?? "")\nPoložky na uložených fakturách zůstanou zachované.") }
    }
}

private struct CatalogItemForm: View {
    let item: CatalogItem
    let isNew: Bool
    let save: (CatalogItem) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var description: String
    @State private var unit: String
    @State private var unitPreset: String
    @State private var price: String
    @State private var error: String?

    init(item: CatalogItem, isNew: Bool, save: @escaping (CatalogItem) throws -> Void) {
        self.item = item; self.isNew = isNew; self.save = save
        _description = State(initialValue: item.description)
        _unit = State(initialValue: item.unit)
        _unitPreset = State(initialValue: ["hod", "den", "ks"].contains(item.unit) ? item.unit : "custom")
        _price = State(initialValue: decimalText(item.unitPrice))
    }
    private var presetUnit: Binding<String> {
        Binding(get: { unitPreset }, set: {
            unitPreset = $0
            unit = $0 == "custom" ? "" : $0
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DeskHeading(title: isNew ? "Nová položka ceníku" : "Upravit položku", subtitle: "Sazba se použije za jednu zvolenou jednotku.")
            DeskField(label: "Popis na faktuře", text: $description, placeholder: "Např. Vývoj aplikace", multiline: true)
            Picker("Jednotka", selection: presetUnit) {
                Text("Hodina · hod").tag("hod")
                Text("Den · den").tag("den")
                Text("Kus · ks").tag("ks")
                Text("Vlastní / bez jednotky").tag("custom")
            }
            if presetUnit.wrappedValue == "custom" {
                DeskField(label: "Vlastní jednotka · může zůstat prázdná", text: $unit, placeholder: "Např. měsíc")
            }
            DeskField(label: "Cena za jednotku v Kč", text: $price, placeholder: "1250,00")
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Zrušit") { dismiss() }.buttonStyle(DeskSecondaryButton()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Uložit položku") {
                    do {
                        let updated = CatalogItem(id: item.id, description: description, unit: unit, unitPrice: try DecimalInput.parse(price))
                        try save(updated); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(DeskPrimaryButton()).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 560).background(Desk.canvas)
    }
}

/// Searchable list shared by invoice editors; selecting a template never mutates the catalog.
struct CatalogPickerView: View {
    @ObservedObject var store: AppStore
    let select: (CatalogItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var items: [CatalogItem] { matchingCatalogItems(store.catalogItems, query: search) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                DeskHeading(title: "Vybrat z ceníku", subtitle: "Vložíme popis, jednotku a sazbu. Množství pak upravíte ve faktuře.")
                Spacer()
                Button("Zavřít") { dismiss() }.buttonStyle(DeskSecondaryButton()).keyboardShortcut(.cancelAction)
            }
            DeskSearchField(placeholder: "Hledat v ceníku", text: $search).frame(width: 280)
            if items.isEmpty {
                ContentUnavailableView(store.catalogItems.isEmpty ? "Ceník je zatím prázdný" : "Žádná odpovídající položka", systemImage: "list.bullet.rectangle", description: Text(store.catalogItems.isEmpty ? "Napište položku ve faktuře a zvolte Uložit do ceníku, nebo ji přidejte v sekci Ceník." : "Zkuste upravit hledání."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            Button { select(item); dismiss() } label: { CatalogItemLabel(item: item).padding(.horizontal, 16).padding(.vertical, 8) }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }.background(Desk.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(26).frame(width: 760, height: min(600, (NSScreen.main?.visibleFrame.height ?? 900) - 120)).background(Desk.canvas)
    }
}
