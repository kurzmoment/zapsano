import FakturaCore
import Foundation

// Contract: https://ares.gov.cz/ekonomicke-subjekty-v-be/rest/v3/api-docs
// A lookup proposes public registry values; it does not determine VAT status.
struct ARESClient: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let load: DataLoader

    init(load: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }) {
        self.load = load
    }

    func lookup(ico: String) async throws -> Party {
        let normalized = ico.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count == 8,
              normalized.utf8.allSatisfy({ (48...57).contains($0) }) else { throw ARESError.invalidICO }
        try Task.checkCancellation()
        let url = URL(string: "https://ares.gov.cz/ekonomicke-subjekty-v-be/rest/ekonomicke-subjekty/")!.appending(path: normalized)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await load(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ARESError.invalidResponse }
            switch http.statusCode {
            case 200: break
            case 404: throw ARESError.notFound
            case 400: throw ARESError.invalidICO
            default: throw ARESError.unavailable
            }
            let subject: Subject
            do { subject = try JSONDecoder().decode(Subject.self, from: data) }
            catch { throw ARESError.invalidResponse }
            let name = subject.obchodniJmeno.trimmingCharacters(in: .whitespacesAndNewlines)
            guard subject.ico == normalized, !name.isEmpty else { throw ARESError.invalidResponse }
            return Party(name: name, registrationNumber: normalized, taxNumber: subject.dic ?? "", address: subject.sidlo?.formatted ?? "")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw ARESError.timedOut
            default: throw ARESError.unavailable
            }
        } catch let error as ARESError {
            throw error
        } catch {
            throw ARESError.unavailable
        }
    }

    private struct Subject: Decodable {
        let ico: String
        let obchodniJmeno: String
        let dic: String?
        let sidlo: Address?
    }

    private struct Address: Decodable {
        let textovaAdresa: String?
        let nazevUlice: String?
        let cisloDomovni: Int?
        let cisloOrientacni: Int?
        let cisloOrientacniPismeno: String?
        let nazevCastiObce: String?
        let nazevObce: String?
        let psc: Int?
        let pscTxt: String?
        let nazevStatu: String?

        var formatted: String {
            if let text = cleaned(textovaAdresa) { return text }
            var house = cisloDomovni.map(String.init) ?? ""
            if let orientation = cisloOrientacni {
                house += (house.isEmpty ? "" : "/") + String(orientation) + (cleaned(cisloOrientacniPismeno) ?? "")
            }
            let street = [cleaned(nazevUlice) ?? cleaned(nazevCastiObce), cleaned(house)].compactMap { $0 }.joined(separator: " ")
            let postal = cleaned(pscTxt) ?? psc.map(String.init)
            let city = [postal, cleaned(nazevObce)].compactMap { $0 }.joined(separator: " ")
            return [cleaned(street), cleaned(city), cleaned(nazevStatu)].compactMap { $0 }.joined(separator: ", ")
        }

        private func cleaned(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
    }
}

enum ARESError: LocalizedError, Equatable {
    case invalidICO, notFound, timedOut, unavailable, invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidICO: "Zadejte IČO jako osm číslic včetně případných počátečních nul."
        case .notFound: "V ARES nebyl nalezen subjekt s tímto IČO. Údaje můžete vyplnit ručně."
        case .timedOut: "ARES neodpověděl včas. Zkuste načtení znovu nebo údaje vyplňte ručně."
        case .unavailable: "ARES nyní není dostupný. Zkontrolujte připojení nebo údaje vyplňte ručně."
        case .invalidResponse: "ARES vrátil neúplnou nebo neočekávanou odpověď. Údaje můžete vyplnit ručně."
        }
    }
}
