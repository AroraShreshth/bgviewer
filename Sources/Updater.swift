import Foundation
import CryptoKit

/// Everything needed for in-place self-update from GitHub Releases:
/// fetch latest → download zip + checksums.txt → verify SHA-256 → verify
/// signature → swap the bundle (with rollback) → relaunch.
struct ReleaseInfo: Sendable {
    let version: String
    let zipURL: URL
    let checksumsURL: URL?
}

enum Updater {
    static let apiURL = URL(string: "https://api.github.com/repos/AroraShreshth/bgviewer/releases/latest")!

    // MARK: Pure, testable pieces

    /// Parse the GitHub releases/latest JSON into what we need.
    static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        var zip: URL?
        var checksums: URL?
        for asset in obj["assets"] as? [[String: Any]] ?? [] {
            guard let name = asset["name"] as? String,
                  let urlStr = asset["browser_download_url"] as? String,
                  let url = URL(string: urlStr) else { continue }
            if name.hasSuffix(".zip") && zip == nil { zip = url }
            if name == "checksums.txt" { checksums = url }
        }
        guard let zip else { return nil }
        return ReleaseInfo(version: version, zipURL: zip, checksumsURL: checksums)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// checksums.txt lines look like "abc123…  bgviewer-1.8.0.zip".
    static func verifyChecksum(zipData: Data, checksums: String, assetName: String) -> Bool {
        for line in checksums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let file = String(parts.last!).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if file == assetName {
                return String(parts[0]).lowercased() == sha256Hex(zipData)
            }
        }
        return false
    }

    /// Self-update only replaces a real install — /Applications or
    /// ~/Applications — never a dev checkout or a stray copy.
    static func isUpdatableInstallPath(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard path.hasSuffix("/bgviewer.app") else { return false }
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    // MARK: Network + swap

    static func fetchLatest() async -> ReleaseInfo? {
        guard let (data, _) = try? await URLSession.shared.data(from: apiURL) else { return nil }
        return parseRelease(data)
    }

    /// Download, verify, swap, prepare relaunch. Returns nil on success —
    /// after which the caller should terminate the app (a detached relaunch
    /// is already scheduled).
    static func performUpdate(_ info: ReleaseInfo,
                              bundlePath: String,
                              status: @escaping @Sendable (String) -> Void) async -> String? {
        guard isUpdatableInstallPath(bundlePath) else {
            return "This copy isn't in /Applications — update it from the Releases page"
        }

        status("Downloading v\(info.version)…")
        guard let (zipData, _) = try? await URLSession.shared.data(from: info.zipURL) else {
            return "Download failed — check your connection"
        }

        if let cURL = info.checksumsURL {
            status("Verifying checksum…")
            guard let (cData, _) = try? await URLSession.shared.data(from: cURL),
                  let cText = String(data: cData, encoding: .utf8),
                  verifyChecksum(zipData: zipData, checksums: cText, assetName: info.zipURL.lastPathComponent) else {
                return "Checksum verification failed — update aborted"
            }
        }

        status("Installing v\(info.version)…")
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("bgviewer-update-\(info.version)")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let zipPath = work.appendingPathComponent("update.zip")
        do { try zipData.write(to: zipPath) } catch { return "Couldn't write the download" }
        let extract = work.appendingPathComponent("extract")
        guard Shell.run("/usr/bin/ditto", ["-xk", zipPath.path, extract.path]).ok else {
            return "Couldn't extract the update"
        }
        let newApp = extract.appendingPathComponent("bgviewer.app")
        guard fm.fileExists(atPath: newApp.path) else { return "Archive didn't contain bgviewer.app" }

        // Sanity: the download must be the version we expect, with a valid signature.
        let ver = Shell.run("/usr/libexec/PlistBuddy",
                            ["-c", "Print :CFBundleShortVersionString",
                             newApp.appendingPathComponent("Contents/Info.plist").path])
            .out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ver == info.version else { return "Downloaded app reports wrong version (\(ver))" }
        guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path]).ok else {
            return "Downloaded app failed the signature check"
        }

        // Swap: stage the old bundle aside, copy the new one in, roll back on failure.
        let aside = bundlePath + ".old"
        try? fm.removeItem(atPath: aside)
        do { try fm.moveItem(atPath: bundlePath, toPath: aside) } catch {
            return "Couldn't stage the old app: \(error.localizedDescription)"
        }
        guard Shell.run("/usr/bin/ditto", [newApp.path, bundlePath]).ok else {
            try? fm.removeItem(atPath: bundlePath)
            try? fm.moveItem(atPath: aside, toPath: bundlePath)
            return "Install failed — previous version restored"
        }
        Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundlePath])
        try? fm.removeItem(atPath: aside)

        status("Relaunching…")
        relaunch(bundlePath)
        return nil
    }

    /// Fire-and-forget: reopens the app just after we exit.
    static func relaunch(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? p.run()
    }
}
