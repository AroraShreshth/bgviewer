import Foundation

/// Executes start/stop/pause/restart/disable operations and *verifies* they
/// took effect. Every entry point returns nil on success or a short error
/// string, so the UI can tell the user when something didn't work.
enum ServiceControl {
    static let uid = getuid()
    static var brewPath: String { ServiceScanner.brewPath }

    @discardableResult
    static func perform(_ action: ControlAction, on s: BackgroundService) -> String? {
        switch action {
        case .startStop:   return (s.isActive || s.state == .loaded) ? stop(s) : start(s)
        case .pauseResume: return signal(s.pid, s.state == .paused ? "CONT" : "STOP")
        case .restart:     return restart(s)
        case .disable:     return disableAgent(s)
        case .enable:      return enableAgent(s)
        }
    }

    // MARK: Process liveness

    static func isAlive(_ pid: Int) -> Bool {
        Shell.run("/bin/kill", ["-0", "\(pid)"]).ok
    }

    @discardableResult
    static func waitForExit(_ pid: Int, timeout: Double) -> Bool {
        let steps = max(1, Int(timeout / 0.1))
        for _ in 0..<steps {
            if !isAlive(pid) { return true }
            usleep(100_000)
        }
        return !isAlive(pid)
    }

    private static func signal(_ pid: Int?, _ sig: String) -> String? {
        guard let pid else { return "No process to signal" }
        let r = Shell.run("/bin/kill", ["-\(sig)", "\(pid)"])
        return r.ok ? nil : "kill -\(sig) failed: \(short(r.err))"
    }

    // MARK: Start / Stop

    private static func start(_ s: BackgroundService) -> String? {
        switch s.kind {
        case .launchAgent:
            guard let p = s.plistPath else { return "No plist path" }
            let r = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", p])
            // bootstrap exits non-zero if already loaded — treat that as success.
            if r.ok || ServiceScanner.parseLaunchctlList().loaded.contains(s.label ?? "") { return nil }
            return "Couldn't start: \(short(r.err))"
        case .brewService:
            guard let n = s.brewName else { return "No formula" }
            let r = Shell.run(brewPath, ["services", "start", n])
            return r.ok ? nil : "brew start failed: \(short(r.err))"
        case .process:
            return "Can't start a stopped process"
        }
    }

    private static func stop(_ s: BackgroundService) -> String? {
        switch s.kind {
        case .launchAgent:
            guard let l = s.label else { return "No label" }
            Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(l)"])
            // bootout can return non-zero even on success; verify by re-listing.
            usleep(300_000)
            if ServiceScanner.parseLaunchctlList().loaded.contains(l) {
                return "\(l) is still loaded"
            }
            return nil
        case .brewService:
            guard let n = s.brewName else { return "No formula" }
            let r = Shell.run(brewPath, ["services", "stop", n])
            return r.ok ? nil : "brew stop failed: \(short(r.err))"
        case .process:
            guard let pid = s.pid else { return "No pid" }
            return stopProcess(pid)
        }
    }

    /// Ask nicely (SIGTERM); if it's still there, insist (SIGKILL).
    private static func stopProcess(_ pid: Int) -> String? {
        Shell.run("/bin/kill", ["-TERM", "\(pid)"])
        if waitForExit(pid, timeout: 1.5) { return nil }
        Shell.run("/bin/kill", ["-KILL", "\(pid)"])
        if waitForExit(pid, timeout: 1.0) { return nil }
        return "Process \(pid) wouldn't quit"
    }

    // MARK: Restart

    private static func restart(_ s: BackgroundService) -> String? {
        switch s.kind {
        case .launchAgent:
            guard let l = s.label, let p = s.plistPath else { return "Missing label/plist" }
            Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(l)"])
            usleep(400_000)
            let r = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", p])
            return r.ok ? nil : "Restart failed: \(short(r.err))"
        case .brewService:
            guard let n = s.brewName else { return "No formula" }
            let r = Shell.run(brewPath, ["services", "restart", n])
            return r.ok ? nil : "brew restart failed: \(short(r.err))"
        case .process:
            guard let pid = s.pid, let cmd = s.command, !cmd.isEmpty else { return "Nothing to restart" }
            let dir = ServiceScanner.cwd(of: pid)
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            _ = stopProcess(pid)
            let safeDir = dir.replacingOccurrences(of: "'", with: "'\\''")
            Shell.sh("cd '\(safeDir)' && nohup \(cmd) >/dev/null 2>&1 &")
            return nil
        }
    }

    // MARK: Disable / Enable (launch agents)

    /// Stop now AND move the plist out of LaunchAgents so macOS can't relaunch it.
    private static func disableAgent(_ s: BackgroundService) -> String? {
        guard s.kind == .launchAgent, let label = s.label, let plist = s.plistPath else { return "Not a launch agent" }
        Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        Shell.run("/bin/launchctl", ["disable", "gui/\(uid)/\(label)"])
        let fm = FileManager.default
        try? fm.createDirectory(at: ServiceScanner.parkedDir, withIntermediateDirectories: true)
        let dest = ServiceScanner.parkedDir.appendingPathComponent((plist as NSString).lastPathComponent)
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(atPath: plist, toPath: dest.path) }
        catch { return "Couldn't park plist: \(error.localizedDescription)" }
        return nil
    }

    /// Reverse of disable: restore the plist, re-enable and load it.
    private static func enableAgent(_ s: BackgroundService) -> String? {
        guard s.kind == .launchAgent, let label = s.label, let parked = s.plistPath else { return "Not a launch agent" }
        let fm = FileManager.default
        try? fm.createDirectory(at: ServiceScanner.agentsDir, withIntermediateDirectories: true)
        let dest = ServiceScanner.agentsDir.appendingPathComponent((parked as NSString).lastPathComponent)
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(atPath: parked, toPath: dest.path) }
        catch { return "Couldn't restore plist: \(error.localizedDescription)" }
        Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])
        let r = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", dest.path])
        return r.ok ? nil : "Couldn't re-enable: \(short(r.err))"
    }

    private static func short(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 80 ? String(t.prefix(79)) + "…" : t
    }
}
