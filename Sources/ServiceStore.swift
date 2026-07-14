import Foundation
import SwiftUI

@MainActor
final class ServiceStore: ObservableObject {
    @Published var groups: [ServiceGroup] = []
    @Published var isLoading = false
    @Published var lastUpdated = ""
    @Published var statusMessage: String?   // last action's error, shown in the footer

    init() {
        refresh()
    }

    var runningCount: Int {
        var n = 0
        for g in groups {
            for s in g.services where s.state == .running || s.state == .paused { n += 1 }
        }
        return n
    }

    /// Manual refreshes rescan everything; auto ticks (the 6s timer while the
    /// dropdown is open) reuse the short-lived brew cache and keep any error
    /// message on screen.
    func refresh(auto: Bool = false) {
        if auto && isLoading { return }
        isLoading = true
        if !auto { statusMessage = nil }
        Task.detached(priority: .userInitiated) {
            let g = ServiceScanner.scan(freshBrew: !auto)
            await MainActor.run {
                self.groups = g
                self.isLoading = false
                self.lastUpdated = Self.timeString()
            }
        }
    }

    func perform(_ action: ControlAction, on service: BackgroundService) {
        isLoading = true
        statusMessage = nil
        Task.detached(priority: .userInitiated) {
            let err = ServiceControl.perform(action, on: service)
            let g = ServiceScanner.scan()
            await MainActor.run {
                self.groups = g
                self.isLoading = false
                self.lastUpdated = Self.timeString()
                self.statusMessage = err
            }
        }
    }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
