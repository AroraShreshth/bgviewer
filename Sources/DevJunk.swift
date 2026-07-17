import Foundation

/// A regenerable dev artifact folder (node_modules & friends).
struct JunkDir: Identifiable, Sendable {
    let url: URL
    let kind: String          // display label, e.g. "node_modules"
    let regenerate: String    // how it comes back, e.g. "npm install"
    let project: String       // the project folder it belongs to
    var sizeBytes: Int64      // -1 while sizing

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

    /// Delete a junk folder — but re-verify the guard first, so this can never
    /// remove anything that isn't a provable build artifact.
    static func delete(_ url: URL) -> String? {
        guard validates(url) != nil else {
            return "Refusing — \(url.lastPathComponent) doesn't look like a regenerable build folder"
        }
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            return "Couldn't delete: \(error.localizedDescription)"
        }
    }
}
