import Foundation

/// A large file worth the user's attention. bgviewer only ever *shows* these —
/// deletion is deliberately not offered anywhere.
struct BigFile: Identifiable, Sendable {
    let path: String
    let sizeBytes: Int64
    let modified: Date?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Finds the files quietly hogging disk space in the places people forget
/// about (Downloads, Desktop, …), plus overall volume capacity.
enum DiskScanner {
    static let minBytesDefault: Int64 = 100 * 1024 * 1024   // 100 MB

    static var defaultDirs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Downloads", "Desktop", "Documents", "Movies"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
    }

    static func scanBigFiles(in dirs: [URL] = defaultDirs,
                             minBytes: Int64 = minBytesDefault,
                             limit: Int = 15) -> [BigFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        var found: [BigFile] = []
        for dir in dirs {
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in en {
                guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                      vals.isRegularFile == true,
                      let size = vals.fileSize, Int64(size) >= minBytes else { continue }
                found.append(BigFile(path: url.path, sizeBytes: Int64(size),
                                     modified: vals.contentModificationDate))
            }
        }
        return top(found, limit: limit)
    }

    /// Pure: biggest first, capped.
    static func top(_ files: [BigFile], limit: Int) -> [BigFile] {
        Array(files.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(limit))
    }

    /// Free/total for the volume holding the user's home. "Free" is the
    /// Finder-style important-usage figure (counts purgeable space).
    static func diskSpace() -> (free: Int64, total: Int64)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage,
              let total = v.volumeTotalCapacity, total > 0 else { return nil }
        return (free, Int64(total))
    }

    static func humanSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    /// "/Users/x/Downloads/big.dmg" -> "~/Downloads"
    static func shortFolder(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }

    /// SF Symbol by file extension, for a scannable list.
    static func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "dmg", "iso", "pkg":                                   return "opticaldiscdrive"
        case "zip", "tar", "gz", "tgz", "7z", "rar", "xz":          return "doc.zipper"
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":             return "film"
        case "mp3", "wav", "flac", "aiff", "m4a":                   return "music.note"
        case "png", "jpg", "jpeg", "heic", "raw", "tiff", "psd":    return "photo"
        case "pdf":                                                 return "doc.richtext"
        case "pt", "ckpt", "safetensors", "gguf", "onnx", "mlmodel", "bin": return "cpu"
        default:                                                    return "doc"
        }
    }
}
