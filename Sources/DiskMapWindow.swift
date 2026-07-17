import SwiftUI
import AppKit

/// State for the disk-map window: a breadcrumb stack of directories, the
/// current directory's children, and lazy `du` sizing with a small cache.
@MainActor
final class DiskMapModel: ObservableObject {
    @Published var stack: [URL]
    @Published var entries: [DiskEntry] = []
    @Published var scanning = false
    @Published var sizedCount = 0
    @Published var dirCount = 0

    private var cache: [String: Int64] = [:]
    private var loadTask: Task<Void, Never>?

    var current: URL { stack.last! }

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser) {
        stack = [root]
        load()
    }

    func open(_ dir: URL) {
        stack.append(dir)
        load()
    }

    func pop(to index: Int) {
        guard index < stack.count else { return }
        stack = Array(stack.prefix(index + 1))
        load()
    }

    func rescan() {
        cache = [:]
        load()
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = current
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            stack = [url]
            load()
        }
    }

    func load() {
        loadTask?.cancel()
        let dir = current
        var list = DiskMap.listChildren(of: dir)
        for i in list.indices where list[i].isDir {
            if let hit = cache[list[i].url.path] { list[i].sizeBytes = hit }
        }
        entries = list.sorted { max($0.sizeBytes, 0) > max($1.sizeBytes, 0) }
        let pending = list.filter { $0.isDir && $0.sizeBytes < 0 }.map { $0.url.path }
        dirCount = pending.count
        sizedCount = 0
        scanning = !pending.isEmpty
        guard !pending.isEmpty else { return }

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: (String, Int64)?.self) { group in
                var iterator = pending.makeIterator()
                for _ in 0..<3 {
                    if let p = iterator.next() {
                        group.addTask { Task.isCancelled ? nil : (p, DiskMap.directorySize(p)) }
                    }
                }
                while let result = await group.next() {
                    if Task.isCancelled { return }
                    if let (path, size) = result {
                        await MainActor.run { [weak self] in self?.apply(path, size) }
                    }
                    if let p = iterator.next() {
                        group.addTask { Task.isCancelled ? nil : (p, DiskMap.directorySize(p)) }
                    }
                }
            }
            await MainActor.run { [weak self] in self?.finish() }
        }
    }

    private func apply(_ path: String, _ size: Int64) {
        cache[path] = size
        sizedCount += 1
        if let i = entries.firstIndex(where: { $0.url.path == path }) {
            entries[i].sizeBytes = size
        }
    }

    private func finish() {
        entries.sort { max($0.sizeBytes, 0) > max($1.sizeBytes, 0) }
        scanning = false
    }
}

/// State for the Dev Junk view: regenerable build folders, sized lazily,
/// deletable after a guard re-check.
@MainActor
final class DevJunkModel: ObservableObject {
    @Published var items: [JunkDir] = []
    @Published var scanning = false
    @Published var freedBytes: Int64 = 0
    @Published var lastError: String?

    private var task: Task<Void, Never>?
    private var started = false
    let roots: [URL]

    init(roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser]) {
        self.roots = roots
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + max(0, $1.sizeBytes) } }

    func scanIfNeeded() {
        guard !started else { return }
        started = true
        scan()
    }

    func scan() {
        task?.cancel()
        scanning = true
        items = []
        lastError = nil
        let roots = roots
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let found = DevJunk.discover(under: roots)
            await MainActor.run { [weak self] in self?.items = found }
            let pending = found.map { $0.url.path }
            await withTaskGroup(of: (String, Int64)?.self) { group in
                var iterator = pending.makeIterator()
                for _ in 0..<3 {
                    if let p = iterator.next() {
                        group.addTask { Task.isCancelled ? nil : (p, DiskMap.directorySize(p)) }
                    }
                }
                while let result = await group.next() {
                    if Task.isCancelled { return }
                    if let (path, size) = result {
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            if let i = self.items.firstIndex(where: { $0.url.path == path }) {
                                self.items[i].sizeBytes = size
                            }
                            // Keep the list biggest-first the whole time sizes
                            // stream in, not just at the end.
                            self.items = DevJunk.bySize(self.items)
                        }
                    }
                    if let p = iterator.next() {
                        group.addTask { Task.isCancelled ? nil : (p, DiskMap.directorySize(p)) }
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.items = DevJunk.bySize(self.items)
                self.scanning = false
            }
        }
    }

    func delete(_ item: JunkDir) {
        Task.detached { [weak self] in
            let err = DevJunk.delete(item.url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let err {
                    self.lastError = err
                } else {
                    self.freedBytes += max(0, item.sizeBytes)
                    self.items.removeAll { $0.id == item.id }
                }
            }
        }
    }
}

// MARK: - Window content

struct DiskMapView: View {
    @AppStorage("diskmapMode") private var mode = "map"
    @StateObject private var model: DiskMapModel
    @StateObject private var junk: DevJunkModel
    @State private var hovered: Int?

    init(model: DiskMapModel? = nil, junkModel: DevJunkModel? = nil) {
        _model = StateObject(wrappedValue: model ?? DiskMapModel())
        _junk = StateObject(wrappedValue: junkModel ?? DevJunkModel())
    }

    static let palette: [Color] = [.blue, .cyan, .teal, .green, .yellow, .orange,
                                   .red, .pink, .purple, .indigo, .brown, .mint]

    static func color(_ index: Int) -> Color {
        index < 0 ? Color(nsColor: .systemGray) : palette[index % palette.count]
    }

    private var slices: [PieSlice] { DiskMap.slices(model.entries) }
    private var totalBytes: Int64 { model.entries.reduce(0) { $0 + max(0, $1.sizeBytes) } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if mode == "junk" {
                DevJunkList(model: junk)
            } else {
                mapContent
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 540)
    }

    private var mapContent: some View {
        HStack(spacing: 0) {
            DonutChart(slices: slices,
                       hovered: $hovered,
                       centerTitle: hoverName,
                       centerDetail: hoverSize) { slice in
                if let url = slice.url {
                    if slice.isDir { model.open(url) }
                    else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            .frame(minWidth: 380)
            .padding(18)
            Divider()
            legend
                .frame(minWidth: 330)
        }
    }

    private var hoverName: String {
        if let h = hovered, h < slices.count { return slices[h].name }
        return model.current.lastPathComponent
    }

    private var hoverSize: String {
        if let h = hovered, h < slices.count {
            let s = slices[h]
            return "\(DiskScanner.humanSize(s.sizeBytes)) · \(Int((s.fraction * 100).rounded()))%"
        }
        return model.scanning
            ? "sizing \(model.sizedCount)/\(model.dirCount)…"
            : DiskScanner.humanSize(totalBytes)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                Text("Folder map").tag("map")
                Text("Dev junk").tag("junk")
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .labelsHidden()

            if mode == "junk" {
                if junk.scanning { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Spacer()
                if junk.freedBytes > 0 {
                    Text("freed \(DiskScanner.humanSize(junk.freedBytes)) 🎉")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                }
                Chip(label: "Rescan", system: "arrow.clockwise") { junk.scan() }
            } else {
                ForEach(Array(model.stack.enumerated()), id: \.offset) { i, url in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    Button(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent) {
                        model.pop(to: i)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: i == model.stack.count - 1 ? .semibold : .regular))
                    .foregroundStyle(i == model.stack.count - 1 ? .primary : .secondary)
                }
                if model.scanning { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Spacer()
                Chip(label: "Choose folder…", system: "folder.badge.plus") { model.choose() }
                Chip(label: "Rescan", system: "arrow.clockwise") { model.rescan() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .onChange(of: mode) { m in
            if m == "junk" { junk.scanIfNeeded() }
        }
        .onAppear {
            if mode == "junk" { junk.scanIfNeeded() }
        }
    }

    private var legend: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(slices.enumerated()), id: \.element.id) { i, s in
                    LegendRow(slice: s, color: Self.color(s.colorIndex),
                              highlighted: hovered == i) {
                        if let url = s.url {
                            if s.isDir { model.open(url) }
                            else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    } onReveal: {
                        if let url = s.url {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .onHover { inside in hovered = inside ? i : (hovered == i ? nil : hovered) }
                    Divider().padding(.leading, 26)
                }
                if model.entries.isEmpty && !model.scanning {
                    Text("Empty folder")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.vertical, 40)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: mode == "junk" ? "arrow.3.trianglepath" : "hand.raised")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(mode == "junk"
                 ? "These folders fully regenerate on the next install/build — deleting frees space immediately. Don't delete the junk of an app that's running right now. Tip: pnpm stores every package once and links it into all projects."
                 : "Click a wedge or row to drill in · files reveal in Finder · bgviewer never deletes anything here. System-protected folders may be undercounted.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

// MARK: - Dev junk list

struct DevJunkList: View {
    @ObservedObject var model: DevJunkModel
    @State private var confirmingId: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(model.items.count) regenerable build folders")
                    .font(.system(size: 12, weight: .semibold))
                Text("· \(DiskScanner.humanSize(model.totalBytes)) reclaimable")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if let err = model.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5)).foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.items.isEmpty && !model.scanning {
                        VStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 26)).foregroundStyle(.secondary)
                            Text("No regenerable junk found — clean machine!")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    }
                    ForEach(model.items) { item in
                        JunkRow(item: item,
                                confirming: confirmingId == item.id,
                                onReveal: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) },
                                onDelete: {
                            if confirmingId == item.id {
                                confirmingId = nil
                                model.delete(item)
                            } else {
                                confirmingId = item.id
                                let id = item.id
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                                    if confirmingId == id { confirmingId = nil }
                                }
                            }
                        })
                        Divider().padding(.leading, 40)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct JunkRow: View {
    let item: JunkDir
    let confirming: Bool
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 13)).foregroundStyle(.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.project).font(.system(size: 12.5, weight: .semibold))
                    Text(item.kind)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                }
                Text("\(DiskScanner.shortFolder(item.url.path))/\(item.url.lastPathComponent) · regenerates via \(item.regenerate)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(item.sizeBytes >= 0 ? DiskScanner.humanSize(item.sizeBytes) : "sizing…")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(item.sizeBytes >= 0 ? .primary : .secondary)
            IconButton(system: "folder", color: .blue, help: "Reveal in Finder") { onReveal() }
            if confirming {
                Button(action: onDelete) {
                    Text("Delete \(item.sizeBytes >= 0 ? DiskScanner.humanSize(item.sizeBytes) : "")?")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            } else {
                IconButton(system: "trash", color: .red,
                           help: "Delete — frees the space now; \(item.regenerate) brings it back") { onDelete() }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .help(item.url.path)
    }
}

// MARK: - Donut chart

struct DonutChart: View {
    let slices: [PieSlice]
    @Binding var hovered: Int?
    let centerTitle: String
    let centerDetail: String
    let onSelect: (PieSlice) -> Void

    private let innerFraction = 0.58

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let outer = side / 2 - 6
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                Canvas { ctx, _ in
                    for (i, s) in slices.enumerated() {
                        var path = Path()
                        let a0 = Angle.degrees(s.startDeg - 90)
                        let a1 = Angle.degrees(s.endDeg - 90)
                        path.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
                        path.addArc(center: center, radius: outer * innerFraction, startAngle: a1, endAngle: a0, clockwise: true)
                        path.closeSubpath()
                        let base = DiskMapView.color(s.colorIndex)
                        ctx.fill(path, with: .color(base.opacity(hovered == i ? 1.0 : 0.82)))
                        ctx.stroke(path, with: .color(.black.opacity(0.25)), lineWidth: 1)
                    }
                }
                VStack(spacing: 3) {
                    Text(centerTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: outer * innerFraction * 1.6)
                    Text(centerDetail)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let (deg, r) = DiskMap.angleDeg(centerX: center.x, centerY: center.y, x: p.x, y: p.y)
                    hovered = DiskMap.sliceIndex(atDeg: deg, radius: r, outerRadius: outer,
                                                 innerFraction: innerFraction, slices: slices)
                case .ended:
                    hovered = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                let (deg, r) = DiskMap.angleDeg(centerX: center.x, centerY: center.y,
                                                x: value.location.x, y: value.location.y)
                if let i = DiskMap.sliceIndex(atDeg: deg, radius: r, outerRadius: outer,
                                              innerFraction: innerFraction, slices: slices) {
                    onSelect(slices[i])
                }
            })
        }
    }
}

// MARK: - Legend row

struct LegendRow: View {
    let slice: PieSlice
    let color: Color
    let highlighted: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Image(systemName: slice.isDir ? "folder.fill" : DiskScanner.icon(for: slice.name))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 15)
            Text(slice.name)
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(Int((slice.fraction * 100).rounded()))%")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            Text(DiskScanner.humanSize(slice.sizeBytes))
                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
            if slice.url != nil {
                if slice.isDir {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    IconButton(system: "folder", color: .blue, help: "Reveal in Finder") { onReveal() }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(highlighted ? color.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .help(slice.url?.path ?? "Files too small to chart individually")
    }
}
