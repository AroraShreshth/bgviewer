import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class ServiceStore: ObservableObject {
    @Published var groups: [ServiceGroup] = []
    @Published var isLoading = false
    @Published var lastUpdated = ""
    @Published var statusMessage: String?   // last action's error, shown in the footer
    @Published var alertsEnabled = false    // notify when a new dev server starts listening
    @Published var updateAvailable: String? // newer release tag, when one exists

    private var watchTask: Task<Void, Never>?

    /// True only inside the real app bundle — keeps test/preview harnesses from
    /// touching UserNotifications (which aborts outside an app) or the network.
    private static var isRealApp: Bool {
        Bundle.main.bundleIdentifier == "com.shreshth.bgviewer"
    }

    init() {
        alertsEnabled = UserDefaults.standard.bool(forKey: "alertsEnabled")
        if alertsEnabled && Self.isRealApp { startWatcher() }
        checkForUpdate()
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

    // MARK: New-listener alerts

    func setAlerts(_ on: Bool) {
        alertsEnabled = on
        UserDefaults.standard.set(on, forKey: "alertsEnabled")
        guard Self.isRealApp else { return }
        if on {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Task { @MainActor in
                    if granted {
                        self.startWatcher()
                    } else {
                        self.alertsEnabled = false
                        UserDefaults.standard.set(false, forKey: "alertsEnabled")
                        self.statusMessage = "Notifications are off for bgviewer in System Settings"
                    }
                }
            }
        } else {
            stopWatcher()
        }
    }

    /// Polls listeners once a minute even while the dropdown is closed; posts a
    /// notification when a dev server appears that wasn't there before. The
    /// first tick only records a baseline so enabling never floods.
    private func startWatcher() {
        stopWatcher()
        watchTask = Task.detached(priority: .utility) {
            var baseline: Set<String>?
            while !Task.isCancelled {
                let ports = ServiceScanner.listeningPorts()
                let snap = ServiceScanner.psSnapshot(Array(ports.keys))
                let procs = ServiceScanner.buildProcesses(ports, snap: snap, excludePids: [Int(getpid())])
                let (keys, fresh) = ServiceScanner.newDevListeners(previous: baseline ?? [], current: procs)
                if baseline != nil {
                    for s in fresh.prefix(3) { Self.postListenerNote(s) }
                }
                baseline = keys
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func stopWatcher() {
        watchTask?.cancel()
        watchTask = nil
    }

    nonisolated private static func postListenerNote(_ s: BackgroundService) {
        let content = UNMutableNotificationContent()
        content.title = "New dev server running"
        content.body = "\(s.name) — \(s.subtitle)"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: Update check

    /// One lightweight GitHub API call, at most every 6 hours. This is the
    /// app's only network access.
    private func checkForUpdate() {
        guard Self.isRealApp else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard now - last > 6 * 3600 else { return }
        UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        Task.detached { [weak self] in
            guard let url = URL(string: "https://api.github.com/repos/AroraShreshth/bgviewer/releases/latest"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if isNewerVersion(remote, than: current) {
                await MainActor.run { [weak self] in self?.updateAvailable = remote }
            }
        }
    }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
