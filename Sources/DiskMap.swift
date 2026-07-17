import Foundation

/// One item inside the directory currently shown in the disk map.
struct DiskEntry: Identifiable, Sendable {
    let url: URL
    let name: String
    let isDir: Bool
    var sizeBytes: Int64      // -1 while a directory is still being sized

    var id: String { url.path }
}

/// One wedge of the pie. Angles are degrees, 0° at 12 o'clock, clockwise.
struct PieSlice: Identifiable, Sendable {
    let name: String
    let url: URL?             // nil for the grouped "everything else" wedge
    let isDir: Bool
    let sizeBytes: Int64
    let fraction: Double
    let startDeg: Double
    let endDeg: Double
    let colorIndex: Int       // -1 = the gray "everything else" wedge

    var id: String { url?.path ?? "other:\(startDeg)" }
}

/// Engine for the disk-map window: directory listing, `du`-based sizing, and
/// the pure pie geometry (kept UI-free so it's unit-testable).
enum DiskMap {
    // MARK: Sizing

    /// Immediate children of a directory. Files get their size right away;
    /// directories start at -1 and are sized asynchronously by the caller.
    static func listChildren(of dir: URL) -> [DiskEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url in
            guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isDir = vals.isDirectory ?? false
            return DiskEntry(url: url, name: url.lastPathComponent, isDir: isDir,
                             sizeBytes: isDir ? -1 : Int64(vals.fileSize ?? 0))
        }
    }

    /// Total size of a directory tree in bytes, via `du -sk` (fast, skips what
    /// it can't read — system-protected folders just count as smaller).
    static func directorySize(_ path: String) -> Int64 {
        let r = Shell.run("/usr/bin/du", ["-sk", path], timeout: 1800)
        return parseDuKB(r.out) * 1024
    }

    /// Pure parser for `du -sk` output ("123456\t/some/path").
    static func parseDuKB(_ output: String) -> Int64 {
        guard let first = output.split(separator: "\n").first,
              let kb = Int64(first.split(separator: "\t").first ?? "") else { return 0 }
        return kb
    }

    // MARK: Pie geometry (pure)

    /// Turn sized entries into pie wedges: biggest first, tiny ones grouped
    /// into a single gray "everything else" wedge so the chart stays legible.
    static func slices(_ entries: [DiskEntry],
                       maxSlices: Int = 12,
                       minFraction: Double = 0.012) -> [PieSlice] {
        let sized = entries.filter { $0.sizeBytes > 0 }
        let total = sized.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard total > 0 else { return [] }

        let sorted = sized.sorted { $0.sizeBytes > $1.sizeBytes }
        var main: [DiskEntry] = []
        var otherBytes: Int64 = 0
        for e in sorted {
            let frac = Double(e.sizeBytes) / Double(total)
            if main.count < maxSlices && frac >= minFraction {
                main.append(e)
            } else {
                otherBytes += e.sizeBytes
            }
        }

        var out: [PieSlice] = []
        var angle = 0.0
        for (i, e) in main.enumerated() {
            let frac = Double(e.sizeBytes) / Double(total)
            let end = angle + frac * 360
            out.append(PieSlice(name: e.name, url: e.url, isDir: e.isDir,
                                sizeBytes: e.sizeBytes, fraction: frac,
                                startDeg: angle, endDeg: end, colorIndex: i))
            angle = end
        }
        if otherBytes > 0 {
            out.append(PieSlice(name: "everything else", url: nil, isDir: false,
                                sizeBytes: otherBytes,
                                fraction: Double(otherBytes) / Double(total),
                                startDeg: angle, endDeg: 360, colorIndex: -1))
        }
        return out
    }

    /// Point → (angle in degrees clockwise from 12 o'clock, distance from center).
    static func angleDeg(centerX: Double, centerY: Double, x: Double, y: Double) -> (deg: Double, radius: Double) {
        let dx = x - centerX
        let dy = y - centerY
        var deg = atan2(dx, -dy) * 180 / .pi
        if deg < 0 { deg += 360 }
        return (deg, (dx * dx + dy * dy).squareRoot())
    }

    /// Which slice sits under a point, given the donut's outer radius and the
    /// inner-hole fraction. nil in the hole or outside the ring.
    static func sliceIndex(atDeg deg: Double, radius: Double, outerRadius: Double,
                           innerFraction: Double, slices: [PieSlice]) -> Int? {
        guard radius <= outerRadius, radius >= outerRadius * innerFraction else { return nil }
        return slices.firstIndex { deg >= $0.startDeg && deg < $0.endDeg }
    }
}
