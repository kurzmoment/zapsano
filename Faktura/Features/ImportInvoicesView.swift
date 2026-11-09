import SwiftUI
import AppKit
import FakturaCore

private struct ImportRow: Identifiable {
    var id: UUID { candidate.id }
    let candidate: ImportedInvoiceCandidate
    var reviewed = false
    var payment = ""
    var paidOn = Date()
    var imported = false
    var error: String?
}

struct ImportInvoicesView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ImportRow] = []
    @State private var selectedID: UUID?
    @State private var loading = false
    @State private var message: String?
    @State private var fileErrors: [String] = []
    @State private var importTask: Task<Void, Never>?
    private var eligible: [ImportRow] { rows.filter { !$0.imported && $0.reviewed && !$0.payment.isEmpty && $0.candidate.draft != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                DeskHeading(title: "Import faktur", subtitle: "Zkontrolujte doklady a úhrady. Původní čísla i PDF zůstanou zachované.")
                Spacer()
                Button("Vybrat PDF…") { choose(folder: false) }.buttonStyle(DeskSecondaryButton()).disabled(loading)
                Button("Vybrat složku…") { choose(folder: true) }.buttonStyle(DeskSecondaryButton()).disabled(loading)
            }.padding(24)
            Divider()
            if loading { HStack { ProgressView().controlSize(.small); Text("Čtu PDF a kontroluji částky…").font(.system(size: 13)) }.padding(24) }
            if rows.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 28, weight: .light)).foregroundStyle(Desk.muted)
                    Text("Vyberte původní PDF").font(.system(size: 17, weight: .medium))
                    Text("Vyberte PDF nebo celou složku. Podporujeme ověřený formát iDokladu pro neplátce DPH. Nerozpoznané doklady se neuloží bez kontroly.").font(.system(size: 13)).foregroundStyle(Desk.muted).multilineTextAlignment(.center).frame(maxWidth: 460)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach($rows) { $row in
                                VStack(alignment: .leading, spacing: 12) {
                                    Button { selectedID = row.id } label: {
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(row.candidate.number ?? row.candidate.filename).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.primary)
                                                Text(row.candidate.customer?.name ?? "Odběratel nerozpoznán").font(.system(size: 12))
                                                Text(row.candidate.filename).font(.system(size: 11)).foregroundStyle(Desk.muted).lineLimit(1)
                                            }
                                            Spacer()
                                            if let total = row.candidate.declaredTotal { Text(money(total)).font(.system(size: 14, weight: .semibold)) }
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    if row.imported { StatusBadge(label: "Importováno") }
                                    else if row.candidate.draft != nil {
                                        Picker("Úhrada", selection: $row.payment) {
                                            Text("Vyberte stav úhrady…").tag("")
                                            Text("Neuhrazeno").tag("unpaid")
                                            Text("Uhrazeno · znám datum").tag("paid")
                                            Text("Uhrazeno · datum neznám").tag("paidUnknown")
                                        }.font(.system(size: 12))
                                        if row.payment == "paid" { DatePicker("Skutečné datum úhrady", selection: $row.paidOn, displayedComponents: .date).font(.system(size: 12)) }
                                        Text("Částečnou úhradu zapište po importu jako neuhrazené faktury.").font(.system(size: 11)).foregroundStyle(Desk.muted)
                                        Toggle("Údaje a stav úhrady jsem zkontroloval/a", isOn: $row.reviewed).font(.system(size: 11)).disabled(row.payment.isEmpty)
                                    }
                                    ForEach(row.candidate.warnings, id: \.self) { warning in Label(warning, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Desk.muted) }
                                    if let error = row.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                                }.padding(16).background(selectedID == row.id ? Desk.raised : Desk.surface, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedID == row.id ? Desk.controlLine : Desk.line))
                                    .onChange(of: row.payment) { row.reviewed = false }
                                    .onChange(of: row.paidOn) { row.reviewed = false }
                            }
                        }.padding(16)
                    }.frame(minWidth: 420, idealWidth: 460)
                    VStack(alignment: .leading, spacing: 10) {
                        if let row = rows.first(where: { $0.id == selectedID }) {
                            HStack { Text("Původní doklad").font(.system(size: 12, weight: .medium)).foregroundStyle(Desk.muted); Spacer(); if let date = row.candidate.issueDate { Text("Vystaveno \(dayText(date))").font(.system(size: 11)).foregroundStyle(Desk.muted) } }
                            PDFPreview(data: row.candidate.pdfData)
                        } else { ContentUnavailableView("Vyberte doklad", systemImage: "doc.text") }
                    }.padding(16).frame(minWidth: 400)
                }
            }
            if !fileErrors.isEmpty { Text(fileErrors.joined(separator: "\n")).font(.system(size: 11)).foregroundStyle(.red).lineLimit(4).padding(.horizontal, 24) }
            Divider()
            HStack {
                Button("Zavřít") { importTask?.cancel(); dismiss() }.buttonStyle(DeskSecondaryButton()).keyboardShortcut(.cancelAction)
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Color.primary) }
                Spacer()
                Text("\(eligible.count) dokladů připraveno").font(.system(size: 12)).foregroundStyle(Desk.muted)
                Button("Importovat zkontrolované", action: importReviewed).buttonStyle(DeskPrimaryButton()).disabled(eligible.isEmpty || loading)
            }.padding(20).background(Desk.surface)
        }.frame(width: 1100, height: min(720, (NSScreen.main?.visibleFrame.height ?? 900) - 100)).background(Desk.canvas)
            .onDisappear { importTask?.cancel() }
    }
    private func choose(folder: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = !folder; if !folder { panel.allowedContentTypes = [.pdf] }
        guard panel.runModal() == .OK else { return }
        do {
            let urls: [URL]
            if folder, let directory = panel.url {
                urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).filter { $0.pathExtension.lowercased() == "pdf" }
            } else { urls = panel.urls }
            guard !urls.isEmpty else { message = "Ve vybrané složce nejsou žádná PDF."; return }
            guard urls.count <= 200 else { message = "Vyberte nejvýše 200 PDF najednou."; return }
            let bytes = try urls.reduce(0) { total, url in total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            guard bytes <= 120_000_000 else { message = "Vybraná PDF jsou příliš velká. Importujte nejvýše 120 MB najednou."; return }
            rows = []; selectedID = nil; loading = true; message = nil; fileErrors = []
            importTask = Task { @MainActor in
                var candidates: [ImportRow] = []
                for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    if Task.isCancelled { break }
                    do { candidates.append(ImportRow(candidate: try InvoicePDFImport.inspect(url: url))) }
                    catch { fileErrors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    await Task.yield()
                }
                if !Task.isCancelled { rows = candidates; selectedID = candidates.first?.id }
                loading = false
            }
        } catch { message = error.localizedDescription }
    }
    private func importReviewed() {
        var count = 0
        for index in rows.indices where rows[index].reviewed && !rows[index].payment.isEmpty && !rows[index].imported {
            guard let draft = rows[index].candidate.draft, let number = rows[index].candidate.number else { continue }
            do {
                let paid = rows[index].payment == "paid" ? try CalendarDate(date: rows[index].paidOn) : nil
                _ = try store.importInvoice(draft: draft, number: number, originalPDF: rows[index].candidate.pdfData, paidOn: paid, paidWithoutDate: rows[index].payment == "paidUnknown")
                rows[index].imported = true; rows[index].error = nil; count += 1
            } catch { rows[index].error = error.localizedDescription }
        }
        message = "Importováno \(count) dokladů. Původní soubory zůstaly beze změny."
    }
}
