import SwiftUI
import FakturaCore

struct PartyFields: View {
    @Binding var party: Party
    var supplier = false
    @State private var loading = false
    @State private var lookupError: String?
    @State private var proposed: Party?
    @State private var lookupTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 12) {
                DeskField(label: "IČO", text: $party.registrationNumber, placeholder: "8 číslic")
                Button { lookup() } label: {
                    HStack(spacing: 7) { if loading { ProgressView().controlSize(.small) }; Text(loading ? "Hledám…" : "Doplnit z ARES") }
                }.buttonStyle(DeskSecondaryButton()).disabled(loading || party.registrationNumber.trimmingCharacters(in: .whitespacesAndNewlines).count != 8)
            }
            if let lookupError { Text(lookupError).font(.system(size: 12)).foregroundStyle(.red) }
            DeskField(label: "Název firmy / jméno", text: $party.name, placeholder: "Např. Jan Novák")
            DeskField(label: "Fakturační adresa", text: $party.address, placeholder: "Ulice a číslo, PSČ, město", multiline: true)
            HStack(alignment: .top, spacing: 14) {
                DeskField(label: "DIČ · nepovinné", text: $party.taxNumber, placeholder: "CZ…")
                DeskField(label: "E-mail · nepovinný", text: $party.email, placeholder: "email@firma.cz")
            }
            if supplier {
                HStack(alignment: .top, spacing: 14) {
                    DeskField(label: "Telefon · nepovinný", text: optionalText(\.phone), placeholder: "+420…")
                    DeskField(label: "Web · nepovinný", text: optionalText(\.website), placeholder: "www.example.cz")
                }
                DeskField(label: "Bankovní účet", text: $party.bankAccount, placeholder: "Číslo účtu / kód banky")
                DeskField(label: "IBAN · nepovinný", text: optionalText(\.iban), placeholder: "CZ…")
                DeskField(label: "BIC / SWIFT · nepovinný", text: optionalText(\.bic), placeholder: "Kód banky pro zahraniční platby")
                Text("IBAN najdete v internetovém bankovnictví. Zobrazí se na nových fakturách.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $proposed) { result in
            VStack(alignment: .leading, spacing: 18) {
                DeskHeading(title: "Údaje z ARES", subtitle: "Zkontrolujte údaje před doplněním do formuláře.")
                DeskCard(title: result.name) {
                    Text("IČO \(result.registrationNumber)")
                    Text(result.address)
                    if !result.taxNumber.isEmpty { Text("DIČ \(result.taxNumber)") }
                }
                Text("Kontaktní a bankovní údaje zůstanou zachované.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Zrušit") { proposed = nil }.buttonStyle(DeskSecondaryButton())
                    Spacer()
                    Button("Použít údaje") {
                        var merged = result; merged.email = party.email; merged.bankAccount = party.bankAccount; merged.iban = party.iban
                        merged.phone = party.phone; merged.website = party.website; merged.bic = party.bic
                        party = merged; proposed = nil
                    }.buttonStyle(DeskPrimaryButton())
                }
            }.padding(28).frame(width: 500)
        }
        .onChange(of: party.registrationNumber) { lookupTask?.cancel(); loading = false; lookupError = nil; proposed = nil }
        .onDisappear { lookupTask?.cancel(); loading = false }
    }
    private func optionalText(_ keyPath: WritableKeyPath<Party, String?>) -> Binding<String> {
        Binding(get: { party[keyPath: keyPath] ?? "" }, set: { party[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
    private func lookup() {
        lookupTask?.cancel(); loading = true; lookupError = nil
        let requested = party.registrationNumber
        lookupTask = Task { @MainActor in
            do {
                let result = try await ARESClient().lookup(ico: requested)
                guard !Task.isCancelled, requested == party.registrationNumber else { return }
                proposed = result
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { lookupError = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
}

// The registry identity is stable while a proposal sheet is visible.
extension Party: @retroactive Identifiable {
    public var id: String { registrationNumber + name }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    let backup: () -> Void
    let restore: () -> Void
    @State private var party = Party()
    @State private var year = ""
    @State private var next = ""
    @State private var feedback = ""
    @State private var saved = false
    @State private var tab = "Firma"
    @AppStorage("appearance") private var appearance = "light"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                DeskHeading(title: "Nastavení", subtitle: "Dodavatel, číselná řada a vaše data")
                Spacer()
                if tab != "Vzhled a data" {
                    Button("Uložit údaje", action: save).buttonStyle(DeskPrimaryButton())
                }
            }
            Picker("Oblast nastavení", selection: $tab) {
                Text("Firma").tag("Firma")
                Text("Číslování").tag("Číslování")
                Text("Vzhled a data").tag("Vzhled a data")
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Oblast nastavení").frame(width: 350)
            if !feedback.isEmpty {
                Label(feedback, systemImage: saved ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(saved ? Desk.muted : .red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if tab == "Firma" {
                        settingsSection("Údaje dodavatele", description: "Použijí se na nových fakturách. Již vystavené doklady si ponechají původní údaje.") {
                            PartyFields(party: $party, supplier: true)
                        }
                    } else if tab == "Číslování" {
                        settingsSection("Číselná řada", description: "Navazuje na poslední skutečně vydaný doklad, i když vznikl v jiné aplikaci.") {
                            VStack(alignment: .leading, spacing: 20) {
                                HStack(spacing: 16) { DeskField(label: "Rok řady", text: $year); DeskField(label: "Další pořadové číslo", text: $next) }
                                Divider()
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Příští faktura").font(.system(size: 12)).foregroundStyle(Desk.muted)
                                        Text(sequencePreview).font(.system(size: 24, weight: .medium)).monospacedDigit()
                                    }
                                    Spacer()
                                    Image(systemName: "doc.text").font(.system(size: 24, weight: .light)).foregroundStyle(Desk.muted)
                                }
                                Text("Číslo lze změnit při vystavení. Už použité číslo nelze přidělit znovu.").font(.system(size: 12)).foregroundStyle(Desk.muted)
                                if store.needsSequenceConfirmation {
                                    Label("Po obnově potvrďte další číslo podle poslední skutečně vydané faktury.", systemImage: "exclamationmark.triangle")
                                        .font(.system(size: 12)).foregroundStyle(Desk.warning)
                                }
                            }
                        }
                    } else {
                        settingsSection("Vzhled", description: "Přizpůsobte aplikaci prostředí, ve kterém pracujete. Změna se projeví ihned.") {
                            Picker("Režim", selection: $appearance) {
                                Text("Světlý").tag("light"); Text("Tmavý").tag("dark"); Text("Podle systému").tag("system")
                            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Režim vzhledu")
                        }
                        Divider()
                        settingsSection("Záloha dat", description: "Faktury, úhrady a originální PDF uložíte společně. Kopii můžete mít i na externím disku.") {
                            VStack(alignment: .leading, spacing: 16) {
                                Label("Data zůstávají na vašem Macu", systemImage: "internaldrive").font(.system(size: 13, weight: .medium))
                                Button("Exportovat zálohu…", systemImage: "square.and.arrow.up", action: backup).buttonStyle(DeskSecondaryButton())
                            }
                        }
                        Divider()
                        settingsSection("Obnova", description: "Nahradí současnou evidenci obsahem zálohy. Nejprve se uloží bezpečnostní kopie stávajících dat.") {
                            Button("Obnovit ze zálohy…", action: restore).buttonStyle(DeskSecondaryButton())
                        }
                    }
                }.padding(.bottom, 24)
            }
        }.padding(24).background(Desk.canvas)
            .onAppear { party = store.company; year = String(store.sequenceYear); next = String(store.nextNumber) }
            .onChange(of: store.needsSequenceConfirmation) { party = store.company; year = String(store.sequenceYear); next = String(store.nextNumber) }
    }
    private func settingsSection<Content: View>(_ title: String, description: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(description).font(.system(size: 12)).foregroundStyle(Desk.muted).fixedSize(horizontal: false, vertical: true)
            }.frame(width: 200, alignment: .leading).padding(.top, 12)
            VStack(alignment: .leading, spacing: 16, content: content)
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(Desk.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private var sequencePreview: String {
        guard let n = Int(next), n > 0 else { return "—" }
        return year + "-" + (n < 10 ? "0" : "") + String(n)
    }
    private func save() {
        do {
            guard let y = Int(year), let n = Int(next), (2000...9999).contains(y), n > 0 else { throw SettingsError.invalidSequence }
            try store.saveSettings(company: party, nextNumber: n, year: y)
            feedback = "Změny jsou uložené."; saved = true
        } catch { feedback = error.localizedDescription; saved = false }
    }
}
enum SettingsError: LocalizedError {
    case invalidSequence
    var errorDescription: String? { "Zadejte platný rok a kladné další pořadové číslo." }
}

struct ClientsView: View {
    @ObservedObject var store: AppStore
    @State private var search = ""
    @State private var editingID: UUID?
    @State private var party = Party()
    @State private var showingForm = false
    @State private var error: String?
    @State private var includeArchived = false
    private var clients: [ClientRecord] { store.clients.filter { (includeArchived || !$0.archived) && (search.isEmpty || "\($0.party.name) \($0.party.registrationNumber)".localizedStandardContains(search)) }.sorted { $0.party.name.localizedStandardCompare($1.party.name) == .orderedAscending } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                DeskHeading(title: "Klienti", subtitle: "\(store.clients.filter { !$0.archived }.count) aktivních kontaktů v adresáři")
                Spacer()
                Button("Nový klient", systemImage: "plus") { editingID = nil; party = Party(); error = nil; showingForm = true }.buttonStyle(DeskPrimaryButton())
            }
            HStack {
                DeskSearchField(placeholder: "Jméno nebo IČO", text: $search).frame(width: 280)
                Spacer()
                Toggle("Včetně archivovaných", isOn: $includeArchived).toggleStyle(.checkbox).font(.system(size: 12))
            }
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Klient").frame(maxWidth: .infinity, alignment: .leading)
                    Text("IČO").frame(width: 85, alignment: .leading)
                    Text("Kontakt").frame(width: 170, alignment: .leading)
                    Spacer().frame(width: 98)
                }.font(.system(size: 11)).foregroundStyle(Desk.muted).padding(.horizontal, 16).frame(height: 36)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(clients) { client in
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(client.party.name).font(.system(size: 13, weight: .medium)).lineLimit(1).help(client.party.name)
                                        if client.archived { StatusBadge(label: "Archiv", color: Desk.muted) }
                                    }
                                    Text(client.party.address.replacingOccurrences(of: "\n", with: ", "))
                                        .font(.system(size: 11)).foregroundStyle(Desk.muted).lineLimit(1).help(client.party.address)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(client.party.registrationNumber.isEmpty ? "—" : client.party.registrationNumber)
                                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Desk.muted).frame(width: 85, alignment: .leading)
                                Text(client.party.email.isEmpty ? "—" : client.party.email)
                                    .font(.system(size: 12)).foregroundStyle(Desk.muted).lineLimit(1).help(client.party.email).frame(width: 170, alignment: .leading)
                                Button("Upravit") { editingID = client.id; party = client.party; error = nil; showingForm = true }
                                    .buttonStyle(.plain).font(.system(size: 12)).frame(width: 60)
                                Menu {
                                    Button("Upravit údaje") { editingID = client.id; party = client.party; error = nil; showingForm = true }
                                    if !client.archived {
                                        Button("Archivovat") { do { try store.archiveClient(id: client.id) } catch { self.error = error.localizedDescription } }
                                    }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22).accessibilityLabel("Další akce klienta \(client.party.name)")
                            }.padding(.horizontal, 16).frame(minHeight: 60)
                            Divider()
                        }
                    }
                }.overlay {
                    if clients.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "Zatím žádní klienti" : "Žádný odpovídající klient", systemImage: "person.2",
                                               description: Text(search.isEmpty ? "Přidejte kontakt ručně nebo podle IČO z ARES." : "Zkuste jiné jméno nebo IČO."))
                    }
                }
                Divider()
                HStack { Text("\(clients.count) kontaktů").font(.system(size: 11)).foregroundStyle(Desk.muted); Spacer() }.padding(.horizontal, 16).frame(height: 40)
            }.background(Desk.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Desk.line))
        }.padding(24).background(Desk.canvas)
        .sheet(isPresented: $showingForm) {
            VStack(alignment: .leading, spacing: 24) {
                DeskHeading(title: editingID == nil ? "Nový klient" : "Upravit klienta", subtitle: "Zadejte IČO a načtěte fakturační údaje z ARES.")
                PartyFields(party: $party)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Zrušit") { showingForm = false }.buttonStyle(DeskSecondaryButton()).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Uložit klienta") { do { try store.saveClient(party: party, id: editingID); showingForm = false } catch { self.error = error.localizedDescription } }.buttonStyle(DeskPrimaryButton()).disabled(party.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 540).background(Desk.surface)
        }
        .alert("Operaci se nepodařilo dokončit", isPresented: Binding(get: { error != nil && !showingForm }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}
