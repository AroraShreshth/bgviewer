import Foundation

/// A regenerable folder: a dev build artifact (node_modules & friends) or an
/// application cache (Adobe media cache & friends).
struct JunkDir: Identifiable, Sendable {
    let url: URL
    let kind: String          // display label, e.g. "node_modules" / "cache"
    let regenerate: String    // how it comes back, e.g. "npm install"
    let project: String       // the project/app it belongs to
    var sizeBytes: Int64      // -1 while sizing
    var category: String = "build"   // "build" | "cache"

    var id: String { url.path }
}

/// Finds — and, uniquely in bgviewer, can delete — build artifacts that are
/// 100% regenerable. This is the only place in the app that deletes anything,
/// and every candidate must pass a guard check proving it really is a build
/// artifact (a folder merely *named* node_modules is refused):
///
///   node_modules   requires a sibling package.json
///   .venv / venv   requires pyvenv.cfg inside it
///   target         requires a sibling Cargo.toml
///   Pods           requires a sibling Podfile
///   .next / .turbo requires a sibling package.json
///   DerivedData    the well-known Xcode path only
enum DevJunk {
    enum GuardRule {
        case siblingAny([String])   // one of these files next to the folder
        case selfContains(String)   // this file inside the folder
    }

    static let rules: [String: (label: String, regen: String, rule: GuardRule)] = [
        "node_modules": ("node_modules", "npm / pnpm / yarn install", .siblingAny(["package.json"])),
        ".venv":        ("Python venv", "python -m venv · uv sync", .selfContains("pyvenv.cfg")),
        "venv":         ("Python venv", "python -m venv", .selfContains("pyvenv.cfg")),
        "target":       ("Rust target", "cargo build", .siblingAny(["Cargo.toml"])),
        "Pods":         ("CocoaPods", "pod install", .siblingAny(["Podfile"])),
        ".next":        ("Next.js cache", "next build", .siblingAny(["package.json"])),
        ".turbo":       ("Turborepo cache", "rebuilt on next turbo run", .siblingAny(["package.json"])),
    ]

    static var derivedDataURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    /// nil unless the folder provably is a regenerable artifact.
    static func validates(_ url: URL) -> (label: String, regen: String)? {
        if url.path == derivedDataURL.path {
            return ("Xcode DerivedData", "rebuilt automatically by Xcode")
        }
        guard let r = rules[url.lastPathComponent] else { return nil }
        let fm = FileManager.default
        switch r.rule {
        case .siblingAny(let names):
            let parent = url.deletingLastPathComponent()
            guard names.contains(where: { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }) else { return nil }
        case .selfContains(let name):
            guard fm.fileExists(atPath: url.appendingPathComponent(name).path) else { return nil }
        }
        return (r.label, r.regen)
    }

    /// Candidate folders via `find`, pruned so we never descend into a match
    /// (no nested node_modules noise), nor into Library/.Trash/.git.
    static func findCandidates(under root: URL, maxDepth: Int = 6) -> [URL] {
        var args = [root.path, "-maxdepth", "\(maxDepth)", "("]
        args += ["-path", root.appendingPathComponent("Library").path, "-o",
                 "-path", root.appendingPathComponent(".Trash").path, "-o",
                 "-name", ".git", ")", "-prune", "-o", "-type", "d", "("]
        for (i, name) in rules.keys.sorted().enumerated() {
            if i > 0 { args.append("-o") }
            args += ["-name", name]
        }
        args += [")", "-print", "-prune"]
        let out = Shell.run("/usr/bin/find", args, timeout: 300).out
        return out.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// All validated junk dirs under the roots (sizes still pending).
    static func discover(under roots: [URL]) -> [JunkDir] {
        var out: [JunkDir] = []
        for root in roots {
            for url in findCandidates(under: root) {
                if let v = validates(url) {
                    out.append(JunkDir(url: url, kind: v.label, regenerate: v.regen,
                                       project: url.deletingLastPathComponent().lastPathComponent,
                                       sizeBytes: -1))
                }
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if roots.contains(where: { $0.path == home }),
           FileManager.default.fileExists(atPath: derivedDataURL.path),
           let v = validates(derivedDataURL) {
            out.append(JunkDir(url: derivedDataURL, kind: v.label, regenerate: v.regen,
                               project: "Xcode", sizeBytes: -1))
        }
        return out
    }

    // MARK: App caches

    /// Caches below this size aren't worth showing.
    static let cacheMinBytes: Int64 = 100 * 1024 * 1024

    /// Curated cache locations — the classic disk eaters. All regenerate; the
    /// app rebuilds them the next time it needs them.
    static func curatedCaches(home: URL) -> [(url: URL, label: String, regen: String)] {
        [
            (home.appendingPathComponent("Library/Application Support/Adobe/Common/Media Cache Files"),
             "Adobe media cache", "rebuilt by Premiere/After Effects on open"),
            (home.appendingPathComponent("Library/Application Support/Adobe/Common/Media Cache"),
             "Adobe media cache DB", "rebuilt by Premiere/After Effects on open"),
            (home.appendingPathComponent("Library/Caches/Adobe Camera Raw"),
             "Adobe Camera Raw cache", "rebuilt on next open"),
            (home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"),
             "Xcode device support", "re-copied from the device on next connect"),
            (home.appendingPathComponent("Library/Caches/CocoaPods"),
             "CocoaPods cache", "re-downloaded by pod install"),
            (home.appendingPathComponent(".npm/_cacache"),
             "npm cache", "re-downloaded by npm install"),
            (home.appendingPathComponent("Library/Caches/Yarn"),
             "Yarn cache", "re-downloaded by yarn install"),
            (home.appendingPathComponent("Library/Caches/pip"),
             "pip cache", "re-downloaded by pip install"),
            (home.appendingPathComponent("Library/Caches/Homebrew"),
             "Homebrew downloads", "re-downloaded by brew as needed"),
            (home.appendingPathComponent("Library/Caches/ms-playwright"),
             "Playwright browsers", "re-downloaded by playwright install"),
        ]
    }

    /// nil unless the folder is a known-safe cache: either curated, or a
    /// direct child of ~/Library/Caches that is NOT Apple's (macOS's own
    /// caches stay untouchable, same as everywhere else in bgviewer).
    static func validatesCache(_ url: URL,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (label: String, regen: String)? {
        let path = url.standardizedFileURL.path
        for c in curatedCaches(home: home) where c.url.standardizedFileURL.path == path {
            return (c.label, c.regen)
        }
        let cachesRoot = home.appendingPathComponent("Library/Caches").standardizedFileURL.path
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        if parent == cachesRoot {
            let name = url.lastPathComponent
            guard !name.isEmpty, !name.hasPrefix("com.apple.") else { return nil }
            return ("app cache", "rebuilt by the app as needed")
        }
        return nil
    }

    /// All existing cache dirs worth sizing: curated + generic ~/Library/Caches
    /// children (deduped, Apple's excluded).
    static func discoverCaches(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [JunkDir] {
        let fm = FileManager.default
        var out: [JunkDir] = []
        var seen = Set<String>()

        for c in curatedCaches(home: home) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: c.url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            seen.insert(c.url.standardizedFileURL.path)
            out.append(JunkDir(url: c.url, kind: "cache", regenerate: c.regen,
                               project: c.label, sizeBytes: -1, category: "cache"))
        }

        let cachesRoot = home.appendingPathComponent("Library/Caches")
        if let kids = try? fm.contentsOfDirectory(at: cachesRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
            for kid in kids {
                guard (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let std = kid.standardizedFileURL.path
                guard !seen.contains(std), validatesCache(kid, home: home) != nil else { continue }
                seen.insert(std)
                out.append(JunkDir(url: kid, kind: "cache", regenerate: "rebuilt by the app as needed",
                                   project: kid.lastPathComponent, sizeBytes: -1, category: "cache"))
            }
        }
        return out
    }

    /// Drop caches that turned out to be too small to matter. Build artifacts
    /// always stay; caches still being sized stay until their size is known.
    static func filterSizedCaches(_ items: [JunkDir], minCacheBytes: Int64 = cacheMinBytes) -> [JunkDir] {
        items.filter { !($0.category == "cache" && $0.sizeBytes >= 0 && $0.sizeBytes < minCacheBytes) }
    }

    /// Biggest first, always — the whole point of the view is "what should I
    /// delete first". Entries still being sized sink to the bottom.
    static func bySize(_ items: [JunkDir]) -> [JunkDir] {
        items.sorted {
            if ($0.sizeBytes >= 0) != ($1.sizeBytes >= 0) { return $0.sizeBytes >= 0 }
            return $0.sizeBytes > $1.sizeBytes
        }
    }

    /// Delete a junk folder — but re-verify the guard first, so this can never
    /// remove anything that isn't a provable build artifact or known-safe cache.
    static func delete(_ url: URL,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard validates(url) != nil || validatesCache(url, home: home) != nil else {
            return "Refusing — \(url.lastPathComponent) doesn't look like a regenerable folder"
        }
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            return "Couldn't delete: \(error.localizedDescription)"
        }
    }
}
