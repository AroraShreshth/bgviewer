import SwiftUI

@main
struct BgviewerApp: App {
    @StateObject private var store = ServiceStore()

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(store)
        } label: {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        }
        .menuBarExtraStyle(.window)
    }
}
