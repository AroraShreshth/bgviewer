import SwiftUI
import AppKit
import ServiceManagement

func dotColor(_ s: RunState) -> Color {
    switch s {
    case .running:  return .green
    case .paused:   return .orange
    case .loaded:   return .blue
    case .unloaded: return Color(nsColor: .systemGray)
    case .disabled: return .purple
    }
}

// MARK: - Root dropdown

struct RootView: View {
    @EnvironmentObject var store: ServiceStore
    @AppStorage("showInactive") private var showInactive = false
    @State private var search = ""
    @State private var expandedId: String?
    @State private var isOpen = false
    @State private var showInfo: Bool
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled

    private let ticker = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    init(showInfoInitially: Bool = false) {
        _showInfo = State(initialValue: showInfoInitially)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 404)
        .onAppear {
            isOpen = true
            loginEnabled = SMAppService.mainApp.status == .enabled
            store.refresh()
        }
        .onDisappear { isOpen = false }
        .onReceive(ticker) { _ in
            if isOpen { store.refresh(auto: true) }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                IconButton(system: showInfo ? "info.circle.fill" : "info.circle",
                           color: showInfo ? .blue : .gray,
                           help: "What everything here means") {
                    withAnimation(.easeInOut(duration: 0.15)) { showInfo.toggle() }
                }
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Background Services").font(.system(size: 13, weight: .semibold))
                    Text("\(store.runningCount) running").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small).scaleEffect(0.8) }
                IconButton(system: "arrow.clockwise", color: .blue, help: "Rescan") { store.refresh() }
                IconButton(system: "power", color: .red, help: "Quit bgviewer") { NSApp.terminate(nil) }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filter by name, port, command…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if showInfo {
            InfoPanel()
        } else {
            listContent
        }
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if displayGroups.isEmpty {
                    emptyState
                } else {
                    ForEach(displayGroups) { group in
                        GroupHeader(title: group.title, subtitle: group.subtitle, count: group.services.count)
                        ForEach(group.services) { s in
                            ServiceRow(s: s, expandedId: $expandedId)
                            Divider().padding(.leading, 30)
                        }
                    }
                }
            }
            .padding(.bottom, 6)
        }
        // A ScrollView has a flexible ideal height, so inside a size-to-fit
        // menu-bar window it must be given a definite height or it collapses.
        .frame(height: contentHeight)
    }

    /// Groups with only their currently-visible services, empties dropped.
    private var displayGroups: [ServiceGroup] {
        store.groups.compactMap { g in
            let items = visible(g)
            return items.isEmpty ? nil : ServiceGroup(id: g.id, title: g.title, subtitle: g.subtitle, services: items)
        }
    }

    /// Grow the list with its content, capped so the window never runs off-screen.
    private var contentHeight: CGFloat {
        if displayGroups.isEmpty { return 150 }
        let groupCount = displayGroups.count
        let rowCount = displayGroups.reduce(0) { $0 + $1.services.count }
        let expandedExtra: CGFloat = displayGroups.contains { g in g.services.contains { $0.id == expandedId } } ? 96 : 0
        let h = CGFloat(groupCount) * 30 + CGFloat(rowCount) * 43 + expandedExtra + 14
        return min(max(h, 160), 500)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: store.isLoading ? "hourglass" : "checkmark.circle")
                .font(.system(size: 26)).foregroundStyle(.secondary)
            Text(store.isLoading ? "Scanning…" : (search.isEmpty ? "Nothing to show" : "No matches for “\(search)”"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Show all", isOn: $showInactive)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11))
                .help("Include stopped and idle services")
            Toggle("At login", isOn: $loginEnabled)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11))
                .help("Start bgviewer automatically when you log in")
                .onChange(of: loginEnabled) { on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        store.statusMessage = "Login item: \(error.localizedDescription)"
                        loginEnabled = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            if let msg = store.statusMessage {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.tail).help(msg)
            } else if !store.lastUpdated.isEmpty {
                Text(footerInfo)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func visible(_ g: ServiceGroup) -> [BackgroundService] {
        g.services.filter { s in
            let stateOK = showInactive || s.state == .running || s.state == .paused || s.state == .disabled
            guard stateOK else { return false }
            guard !search.isEmpty else { return true }
            let q = search.lowercased()
            return s.name.lowercased().contains(q)
                || s.subtitle.lowercased().contains(q)
                || (s.command?.lowercased().contains(q) ?? false)
        }
    }

    private var footerInfo: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return "v\(v) · updated \(store.lastUpdated)"
        }
        return "updated \(store.lastUpdated)"
    }
}

// MARK: - Info / help panel

struct InfoPanel: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("What bgviewer sees")
                InfoRow(icon: "folder.badge.gearshape", color: .blue, title: "Auto-start Agents",
                        text: "Your ~/Library/LaunchAgents. ↻ means launchd relaunches it whenever it's killed — the classic \"it keeps coming back\".")
                InfoRow(icon: "building.2", color: .teal, title: "Machine-wide Agents",
                        text: "/Library/LaunchAgents — installed for all users (Zoom, Logitech, AV tools). Disabling blocks them for your user only.")
                InfoRow(icon: "cup.and.saucer", color: .brown, title: "Homebrew Services",
                        text: "Everything managed by `brew services` — postgres, redis, kafka…")
                InfoRow(icon: "network", color: .green, title: "Listening Processes",
                        text: "Anything holding a TCP port right now — forgotten dev servers live here.")
                InfoRow(icon: "flame", color: .orange, title: "Resource Hogs",
                        text: "No port, but quietly burning ≥15% CPU or ≥1 GB RAM in the background.")
                InfoRow(icon: "nosign", color: .purple, title: "Disabled (parked)",
                        text: "Blocked from auto-starting. Nothing is ever deleted — plists are parked in \"Disabled by bgviewer\" and restored on re-enable.")

                sectionTitle("Buttons")
                InfoRow(icon: "stop.fill", color: .red, title: "Stop",
                        text: "Quit now. Defeats KeepAlive so it stays stopped; stubborn processes get TERM, then KILL.")
                InfoRow(icon: "pause.fill", color: .orange, title: "Pause / Resume",
                        text: "Freeze it in place — RAM kept, CPU freed.")
                InfoRow(icon: "arrow.clockwise", color: .blue, title: "Restart",
                        text: "Stop and start again in place.")
                InfoRow(icon: "nosign", color: .purple, title: "Disable / Re-enable",
                        text: "Stop and block every future auto-start — until you flip it back.")
                InfoRow(icon: "lock.fill", color: .gray, title: "Locked",
                        text: "Apple system process — bgviewer never touches these.")

                sectionTitle("Tips")
                InfoRow(icon: "hand.tap", color: .secondaryInfo, title: "Click any row",
                        text: "Full command, Copy, Reveal plist, View log — and one-click localhost links for dev servers.")
                InfoRow(icon: "clock.arrow.circlepath", color: .secondaryInfo, title: "Always current",
                        text: "The list re-scans every few seconds while open.")

                HStack(spacing: 8) {
                    Chip(label: "GitHub — docs & issues", system: "arrow.up.right.square") {
                        if let url = URL(string: "https://github.com/AroraShreshth/bgviewer") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                    Text("Free · MIT · no telemetry")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(height: 440)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
    }
}

private extension Color {
    static let secondaryInfo = Color(nsColor: .secondaryLabelColor)
}

struct InfoRow: View {
    let icon: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Section header

struct GroupHeader: View {
    let title: String
    let subtitle: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 11).padding(.bottom, 4)
        .help(subtitle)
    }
}

// MARK: - One service row

struct ServiceRow: View {
    @EnvironmentObject var store: ServiceStore
    let s: BackgroundService
    @Binding var expandedId: String?

    private var expanded: Bool { expandedId == s.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(dotColor(s.state)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(s.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 1) { buttons }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedId = expanded ? nil : s.id
                }
            }
            if expanded { detail }
        }
        .padding(.horizontal, 12)
        .help(s.command ?? s.name)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cmd = s.command, !cmd.isEmpty {
                Text(cmd)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if let cmd = s.command, !cmd.isEmpty {
                    Chip(label: "Copy command", system: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                    }
                }
                if let plist = s.plistPath {
                    Chip(label: "Reveal plist", system: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)])
                    }
                }
                if let log = s.logPath, FileManager.default.fileExists(atPath: log) {
                    Chip(label: "View log", system: "doc.text") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: log))
                    }
                }
                if s.procType == "dev" {
                    ForEach(s.ports.prefix(2), id: \.self) { port in
                        Chip(label: ":\(port)", system: "safari") {
                            if let url = URL(string: "http://localhost:\(port)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Spacer()
            }
        }
        .padding(.leading, 18)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var buttons: some View {
        if s.protected {
            Image(systemName: "lock.fill")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(width: 26, height: 24)
                .help("System process — protected from changes")
        } else {
            if s.showStop {
                IconButton(system: "stop.fill", color: .red, help: stopHelp) { store.perform(.startStop, on: s) }
            }
            if s.showStart {
                IconButton(system: "play.fill", color: .green, help: "Start") { store.perform(.startStop, on: s) }
            }
            if s.canPause {
                if s.state == .paused {
                    IconButton(system: "playpause.fill", color: .orange, help: "Resume") { store.perform(.pauseResume, on: s) }
                } else {
                    IconButton(system: "pause.fill", color: .orange, help: "Pause (freeze)") { store.perform(.pauseResume, on: s) }
                }
            }
            if s.canRestart {
                IconButton(system: "arrow.clockwise", color: .blue, help: "Restart") { store.perform(.restart, on: s) }
            }
            if s.canDisable {
                IconButton(system: "nosign", color: .purple, help: disableHelp) { store.perform(.disable, on: s) }
            }
            if s.canEnable {
                IconButton(system: "arrow.uturn.left", color: .green, help: "Re-enable auto-start") { store.perform(.enable, on: s) }
            }
        }
    }

    private var stopHelp: String {
        switch s.kind {
        case .process:     return "Stop (quit process)"
        case .brewService: return "Stop service"
        case .launchAgent: return "Stop (unload now)"
        }
    }

    private var disableHelp: String {
        s.domain == "machine"
            ? "Disable — blocks auto-start for your user"
            : "Disable — stop and block auto-restart"
    }
}

// MARK: - Small controls

struct Chip: View {
    let label: String
    let system: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: system)
                .font(.system(size: 10.5))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(hover ? Color.secondary.opacity(0.22) : Color.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct IconButton: View {
    let system: String
    let color: Color
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 24)
                .background(hover ? color.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
