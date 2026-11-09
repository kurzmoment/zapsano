import SwiftUI

@main
struct FakturaApp: App {
    private let result: Result<AppStore, Error>

    init() { result = Result { try AppStore() } }

    var body: some Scene {
        WindowGroup(Brand.name) {
            switch result {
            case .success(let store): RootView(store: store)
            case .failure(let error):
                ContentUnavailableView {
                    Label("Data se nepodařilo otevřít", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(error.localizedDescription)
                    Text("Aplikace nevytvořila náhradní prázdnou databázi. Zachovejte původní data a zkuste aplikaci spustit znovu.")
                }.padding().frame(minWidth: 600, minHeight: 400)
            }
        }
        .defaultSize(width: 1320, height: 840)
    }
}
