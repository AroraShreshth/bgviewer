import Foundation
import SwiftUI
import AppKit
import UserNotifications

@MainActor
final class ServiceStore: ObservableObject {
    @Published var groups: [ServiceGroup] = []
    @Published var isLoading = false
    @Published var lastUpdated = ""
    @Published var statusMessage: String?   // last action's error, shown in the footer
    @Published var alertsEnabled = false    // notify when a new dev server starts listening
    @Published var updateAvailable: String? // newer release tag, when one exists
    @Published var updateStatus: String?    // result line for manual update checks
    @Published var autoUpdate = false       // install new releases automatically
    @Published var updating = false         // self-update in flight
    @Published var bigFiles: [BigFile] = [] // storage pane contents

    private var pendingRelease: ReleaseInfo?
    private var forceAutoUpdate = false     // test hook: BGVIEWER_FORCE_UPDATE=1
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var diskScanning = false

    private var watchTask: Task<Void, Never>?

    /// True only inside the real app bundle — keeps test/preview harnesses from
    /// touching UserNotifications (which aborts outside an app) or the network.
    private static var isRealApp: Bool {
        Bundle.main.bundleIdentifier == "com.shreshth.bgviewer"
    }

    init() {
        alertsEnabled = UserDefaults.standard.bool(forKey: "alertsEnabled")
        autoUpdate = UserDefaults.standard.bool(forKey: "autoUpdate")
        forceAutoUpdate = ProcessInfo.processInfo.environment["BGVIEWER_FORCE_UPDATE"] == "1"
        if alertsEnabled && Self.isRealApp { startWatcher() }
        checkForUpdate(force: forceAutoUpdate)
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

    /// Refreshes the storage pane: big-file scan + volume capacity.
    func refreshDisk() {
        diskScanning = true
        Task.detached(priority: .userInitiated) {
            let files = DiskScanner.scanBigFiles()
            let space = DiskScanner.diskSpace()
            await MainActor.run {
                self.bigFiles = files
                if let space {
                    self.diskFree = space.free
                    self.diskTotal = space.total
                }
                self.diskScanning = false
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

    /// One lightweight GitHub API call, at most every 6 hours (or on demand
    /// from Settings). Update downloads aside, this is the app's only
    /// network access.
    func checkForUpdate(force: Bool = false) {
        guard Self.isRealApp else { return }
        let now = Date().timeIntervalSince1970
        if !force {
            let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
            guard now - last > 6 * 3600 else { return }
        }
        UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if force { updateStatus = "Checking…" }
        Task.detached { [weak self] in
            guard let info = await Updater.fetchLatest() else {
                if force { await MainActor.run { [weak self] in self?.updateStatus = "Couldn't reach GitHub" } }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if isNewerVersion(info.version, than: current) {
                    self.updateAvailable = info.version
                    self.pendingRelease = info
                    if force { self.updateStatus = "v\(info.version) is available" }
                    if self.autoUpdate || self.forceAutoUpdate { self.updateNow() }
                } else if force {
                    self.updateStatus = "Up to date — v\(current)"
                }
            }
        }
    }

    func setAutoUpdate(_ on: Bool) {
        autoUpdate = on
        UserDefaults.standard.set(on, forKey: "autoUpdate")
        // If an update is already known, flipping the toggle applies it.
        if on, pendingRelease != nil { updateNow() }
    }

    /// In-place self-update; falls back to the Releases page for copies that
    /// aren't in /Applications (dev builds etc.).
    func updateNow() {
        guard !updating else { return }
        guard let info = pendingRelease,
              Updater.isUpdatableInstallPath(Bundle.main.bundlePath) else {
            if let url = URL(string: "https://github.com/AroraShreshth/bgviewer/releases/latest") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        updating = true
        let bundlePath = Bundle.main.bundlePath
        Task.detached { [weak self] in
            let err = await Updater.performUpdate(info, bundlePath: bundlePath) { msg in
                Task { @MainActor [weak self] in self?.updateStatus = msg }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let err {
                    self.updateStatus = err
                    self.updating = false
                } else {
                    self.updateStatus = "Updated — relaunching…"
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
