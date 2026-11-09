import Foundation
import Testing
@testable import Faktura

struct ARESClientTests {
    private static func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test func lookupUsesOfficialEndpointAndMapsOnlyRegistryFields() async throws {
        let client = ARESClient { request in
            #expect(request.url?.absoluteString == "https://ares.gov.cz/ekonomicke-subjekty-v-be/rest/ekonomicke-subjekty/00006947")
            #expect(request.httpMethod == "GET")
            #expect(request.timeoutInterval == 15)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (Data(#"{"ico":"00006947","obchodniJmeno":"Ministerstvo financí","dic":"CZ00006947","sidlo":{"textovaAdresa":"Letenská 525/15, 11800 Praha"}}"#.utf8), Self.response(request))
        }
        let party = try await client.lookup(ico: " 00006947\n")
        #expect(party.name == "Ministerstvo financí")
        #expect(party.registrationNumber == "00006947")
        #expect(party.taxNumber == "CZ00006947")
        #expect(party.address == "Letenská 525/15, 11800 Praha")
        #expect(party.bankAccount.isEmpty && party.email.isEmpty)
    }

    @Test(arguments: ["123", "123456789", "１２３４５６７８", "1234 5678", "../12345", "abcdefgh"])
    func invalidICOIsRejectedBeforeNetworking(_ input: String) async {
        let client = ARESClient { _ in
            Issue.record("Invalid input must not reach the network")
            throw ARESError.unavailable
        }
        await #expect(throws: ARESError.invalidICO) { try await client.lookup(ico: input) }
    }

    @Test func optionalTaxNumberAndStructuredAddress() async throws {
        let client = ARESClient { request in
            (Data(#"{"ico":"12345678","obchodniJmeno":"Firma","sidlo":{"nazevUlice":"Dlouhá","cisloDomovni":12,"cisloOrientacni":3,"cisloOrientacniPismeno":"a","nazevObce":"Brno","psc":60200}}"#.utf8), Self.response(request))
        }
        let party = try await client.lookup(ico: "12345678")
        #expect(party.taxNumber.isEmpty)
        #expect(party.address == "Dlouhá 12/3a, 60200 Brno")
    }

    @Test(arguments: [404, 400, 429, 500])
    func HTTPFailuresAreActionable(_ status: Int) async {
        let client = ARESClient { request in (Data(), Self.response(request, status: status)) }
        let expected: ARESError = status == 404 ? .notFound : status == 400 ? .invalidICO : .unavailable
        await #expect(throws: expected) { try await client.lookup(ico: "12345678") }
    }

    @Test func mismatchedICOAndMalformedJSONAreRejected() async {
        for json in ["invalid", #"{"ico":"87654321","obchodniJmeno":"Jiný subjekt"}"#] {
            let client = ARESClient { request in (Data(json.utf8), Self.response(request)) }
            await #expect(throws: ARESError.invalidResponse) { try await client.lookup(ico: "12345678") }
        }
    }

    @Test func timeoutIsDistinctFromOfflineFailure() async {
        let timeout = ARESClient { _ in throw URLError(.timedOut) }
        await #expect(throws: ARESError.timedOut) { try await timeout.lookup(ico: "12345678") }
        let offline = ARESClient { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: ARESError.unavailable) { try await offline.lookup(ico: "12345678") }
    }

    @Test func cancellationRemainsCancellation() async {
        let client = ARESClient { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) { try await client.lookup(ico: "12345678") }
    }
}
