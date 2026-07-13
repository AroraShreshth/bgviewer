import SwiftUI
import AppKit

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
    @State private var showInactive = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 404)
        .onAppear { store.refresh() }
    }

    private var header: some View {
        HStack(spacing: 9) {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if displayGroups.isEmpty {
                    emptyState
                } else {
                    ForEach(displayGroups) { group in
                        GroupHeader(title: group.title, subtitle: group.subtitle, count: group.services.count)
                        ForEach(group.services) { s in
                            ServiceRow(s: s)
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
        let h = CGFloat(groupCount) * 30 + CGFloat(rowCount) * 43 + 14
        return min(max(h, 160), 480)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: store.isLoading ? "hourglass" : "checkmark.circle")
                .font(.system(size: 26)).foregroundStyle(.secondary)
            Text(store.isLoading ? "Scanning…" : "Nothing to show")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("Show inactive", isOn: $showInactive)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11))
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
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func visible(_ g: ServiceGroup) -> [BackgroundService] {
        g.services.filter {
            showInactive || $0.state == .running || $0.state == .paused || $0.state == .disabled
        }
    }

    private var footerInfo: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return "v\(v) · updated \(store.lastUpdated)"
        }
        return "updated \(store.lastUpdated)"
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

    var body: some View {
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
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .help(s.command ?? s.name)
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
                IconButton(system: "nosign", color: .purple, help: "Disable — stop and block auto-restart") { store.perform(.disable, on: s) }
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
}

// MARK: - Small icon button

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
