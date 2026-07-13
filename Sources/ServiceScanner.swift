import Foundation

/// Discovers background things from three sources: launch agents, Homebrew
/// services, and loose processes holding a listening TCP port.
enum ServiceScanner {
    static let uid = getuid()

    static let agentsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")

    /// Where we park plists that the user has "disabled" so launchd ignores
    /// them. launchd only scans the top level of LaunchAgents, never
    /// subdirectories, so anything in here is invisible to it.
    static let parkedDir = agentsDir.appendingPathComponent("Disabled by bgviewer", isDirectory: true)

    static var brewPath: String {
        let arm = "/opt/homebrew/bin/brew"
        return FileManager.default.isExecutableFile(atPath: arm) ? arm : "/usr/local/bin/brew"
    }

    // MARK: Top-level scan

    static func scan() -> [ServiceGroup] {
        let list = parseLaunchctlList()
        let agentFiles = readAgentPlists(in: agentsDir)
        let portsByPid = listeningPorts()

        // One ps snapshot covering every pid we might display, instead of
        // several ps round-trips per row.
        var interesting = Set(portsByPid.keys)
        for f in agentFiles {
            if let pid = list.pids[f.label] { interesting.insert(pid) }
        }
        let snap = psSnapshot(Array(interesting))

        let agentsAll = buildAgents(agentFiles, list: list, snap: snap)
        // `brew services start` copies its plists into ~/Library/LaunchAgents;
        // those belong in the Homebrew section, not duplicated here.
        let agents = agentsAll.filter { !isBrewManagedLabel($0.label ?? "") }
        let disabled = discoverDisabledAgents()
        let brew = discoverBrew()

        var skip = Set(agentsAll.compactMap { $0.pid })
        for (label, pid) in list.pids where isBrewManagedLabel(label) { skip.insert(pid) }
        skip.insert(Int(getpid()))
        let procs = buildProcesses(portsByPid, snap: snap, excludePids: skip)

        var groups: [ServiceGroup] = []
        groups.append(ServiceGroup(
            id: "agents", title: "Auto-start Agents",
            subtitle: "Launch agents in ~/Library/LaunchAgents — these can relaunch themselves",
            services: agents.sorted { $0.name.lowercased() < $1.name.lowercased() }))

        if !brew.isEmpty {
            groups.append(ServiceGroup(
                id: "brew", title: "Homebrew Services",
                subtitle: "Managed by `brew services`",
                services: brew.sorted { rank($0.state) != rank($1.state) ? rank($0.state) < rank($1.state) : $0.name < $1.name }))
        }

        groups.append(ServiceGroup(
            id: "proc", title: "Listening Processes",
            subtitle: "Processes holding a network port right now",
            services: procs.sorted { rank($0.state) != rank($1.state) ? rank($0.state) < rank($1.state) : $0.name.lowercased() < $1.name.lowercased() }))

        if !disabled.isEmpty {
            groups.append(ServiceGroup(
                id: "disabled", title: "Disabled (parked)",
                subtitle: "Stopped and moved aside so macOS won't auto-start them",
                services: disabled.sorted { $0.name.lowercased() < $1.name.lowercased() }))
        }
        return groups
    }

    private static func rank(_ s: RunState) -> Int {
        switch s { case .running: 0; case .paused: 1; case .loaded: 2; case .unloaded: 3; case .disabled: 4 }
    }

    /// Plists that `brew services` manages get shown under Homebrew, not Agents.
    static func isBrewManagedLabel(_ label: String) -> Bool {
        label.hasPrefix("homebrew.")
    }

    // MARK: launchctl list

    /// Returns the set of loaded labels and a map of label -> pid for running ones.
    static func parseLaunchctlList() -> (loaded: Set<String>, pids: [String: Int]) {
        parseLaunchctl(Shell.run("/bin/launchctl", ["list"]).out)
    }

    /// Pure parser split out so it can be unit-tested without launchctl.
    static func parseLaunchctl(_ output: String) -> (loaded: Set<String>, pids: [String: Int]) {
        var loaded = Set<String>()
        var pids = [String: Int]()
        for line in output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard cols.count == 3 else { continue }
            loaded.insert(cols[2])
            if let pid = Int(cols[0]) { pids[cols[2]] = pid }
        }
        return (loaded, pids)
    }

    // MARK: ps snapshot

    struct ProcInfo {
        var state: String    // ps state flags, e.g. "SN", "T" (T = stopped/paused)
        var comm: String     // executable path, no arguments
        var command: String  // full command line
    }

    /// One batched ps invocation pair for all pids of interest.
    static func psSnapshot(_ pids: [Int]) -> [Int: ProcInfo] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let stateComm = Shell.run("/bin/ps", ["-o", "pid=,state=,comm=", "-p", list]).out
        let command = Shell.run("/bin/ps", ["-o", "pid=,command=", "-p", list]).out
        return mergePsOutputs(stateComm: stateComm, command: command)
    }

    /// Pure merge of the two ps outputs, split out for unit testing.
    /// comm and command may themselves contain spaces, so each line is split
    /// a bounded number of times and the tail kept intact.
    static func mergePsOutputs(stateComm: String, command: String) -> [Int: ProcInfo] {
        var out: [Int: ProcInfo] = [:]
        for line in stateComm.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            let parts = t.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]) else { continue }
            // ps pads columns, so the tail can carry leading spaces — trim it.
            out[pid] = ProcInfo(state: String(parts[1]),
                                comm: String(parts[2]).trimmingCharacters(in: .whitespaces),
                                command: "")
        }
        for line in command.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            let parts = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let cmd = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if out[pid] != nil {
                out[pid]?.command = cmd
            } else {
                out[pid] = ProcInfo(state: "?", comm: "", command: cmd)
            }
        }
        return out
    }

    // MARK: Launch agents

    struct AgentPlist {
        let url: URL
        let dict: [String: Any]
        let label: String
    }

    static func readAgentPlists(in dir: URL) -> [AgentPlist] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [AgentPlist] = []
        for f in files where f.pathExtension == "plist" {
            guard let dict = NSDictionary(contentsOf: f) as? [String: Any] else { continue }
            let label = (dict["Label"] as? String) ?? f.deletingPathExtension().lastPathComponent
            out.append(AgentPlist(url: f, dict: dict, label: label))
        }
        return out
    }

    static func buildAgents(_ files: [AgentPlist],
                            list: (loaded: Set<String>, pids: [String: Int]),
                            snap: [Int: ProcInfo]) -> [BackgroundService] {
        var out: [BackgroundService] = []
        for f in files {
            let pid = list.pids[f.label]
            let isLoaded = list.loaded.contains(f.label)

            var state: RunState
            if let pid {
                state = (snap[pid]?.state.hasPrefix("T") ?? false) ? .paused : .running
            } else if isLoaded {
                state = .loaded
            } else {
                state = .unloaded
            }

            let cmd = programSummary(f.dict)
            let keepAlive = hasKeepAlive(f.dict)

            var parts: [String] = []
            if let pid { parts.append("pid \(pid)") }
            if keepAlive { parts.append("↻ auto-restart") }
            parts.append(shorten(cmd, 44))

            out.append(BackgroundService(
                id: "agent:" + f.label, name: f.label, subtitle: parts.joined(separator: " · "),
                kind: .launchAgent, state: state, pid: pid,
                label: f.label, plistPath: f.url.path, command: cmd,
                protected: isAppleLabel(f.label)))
        }
        return out
    }

    static func discoverDisabledAgents() -> [BackgroundService] {
        readAgentPlists(in: parkedDir).map { f in
            let cmd = programSummary(f.dict)
            return BackgroundService(
                id: "disabled:" + f.label, name: f.label, subtitle: shorten(cmd, 52),
                kind: .launchAgent, state: .disabled, pid: nil,
                label: f.label, plistPath: f.url.path, command: cmd)
        }
    }

    // MARK: Homebrew

    static func discoverBrew() -> [BackgroundService] {
        parseBrew(Shell.run(brewPath, ["services", "list", "--json"]).out)
    }

    /// Pure parser split out so it can be unit-tested without Homebrew.
    static func parseBrew(_ jsonString: String) -> [BackgroundService] {
        guard let data = jsonString.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [BackgroundService] = []
        for item in arr {
            guard let name = item["name"] as? String else { continue }
            let status = (item["status"] as? String) ?? "unknown"
            let state: RunState
            let desc: String
            switch status {
            case "started":   state = .running;  desc = "running"
            case "scheduled": state = .loaded;   desc = "scheduled"
            case "error":     state = .unloaded; desc = "error — check logs"
            case "stopped":   state = .unloaded; desc = "stopped"
            default:          state = .unloaded; desc = "off"
            }
            out.append(BackgroundService(
                id: "brew:" + name, name: name, subtitle: desc,
                kind: .brewService, state: state, brewName: name))
        }
        return out
    }

    // MARK: Listening processes

    /// pid -> set of listening TCP ports, via one lsof call.
    static func listeningPorts() -> [Int: Set<Int>] {
        let r = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
        var byPid: [Int: Set<Int>] = [:]
        var cur = -1
        for raw in r.out.split(separator: "\n") {
            let line = String(raw)
            guard let tag = line.first else { continue }
            let val = String(line.dropFirst())
            switch tag {
            case "p":
                cur = Int(val) ?? -1
                if cur != -1, byPid[cur] == nil { byPid[cur] = [] }
            case "n":
                if cur != -1, let port = portFrom(val) { byPid[cur]?.insert(port) }
            default:
                break
            }
        }
        return byPid
    }

    static func buildProcesses(_ portsByPid: [Int: Set<Int>],
                               snap: [Int: ProcInfo],
                               excludePids: Set<Int>) -> [BackgroundService] {
        var out: [BackgroundService] = []
        for (pid, ports) in portsByPid where !excludePids.contains(pid) {
            // A pid can vanish between lsof and ps; just drop it this scan.
            guard let info = snap[pid], !info.comm.isEmpty else { continue }
            let (type, protected) = classify(comm: info.comm, cmd: info.command)
            let paused = info.state.hasPrefix("T")
            let portList = ports.sorted()
            let portStr = portList.map(String.init).joined(separator: ", ")
            var sub = "port \(portStr) · pid \(pid)"
            if type == "dev" { sub += " · dev server" }
            else if type == "app" { sub += " · app" }
            else if type == "system" { sub += " · system" }
            out.append(BackgroundService(
                id: "proc:\(pid)", name: processName(comm: info.comm, cmd: info.command), subtitle: sub,
                kind: .process, state: paused ? .paused : .running, pid: pid,
                command: info.command, ports: portList, protected: protected, procType: type))
        }
        return out
    }

    static func cwd(of pid: Int) -> String? {
        let r = Shell.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", "\(pid)"])
        for line in r.out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    // MARK: Helpers

    static func isPaused(_ pid: Int) -> Bool {
        let r = Shell.run("/bin/ps", ["-o", "state=", "-p", "\(pid)"])
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("T")
    }

    static func programSummary(_ dict: [String: Any]) -> String {
        if let args = dict["ProgramArguments"] as? [String], !args.isEmpty {
            return args.joined(separator: " ")
        }
        if let prog = dict["Program"] as? String { return prog }
        return "—"
    }

    static func hasKeepAlive(_ dict: [String: Any]) -> Bool {
        if let b = dict["KeepAlive"] as? Bool { return b }
        return dict["KeepAlive"] != nil   // a dict form of KeepAlive also implies relaunch
    }

    static func isAppleLabel(_ label: String) -> Bool {
        label.hasPrefix("com.apple.")
    }

    static func classify(comm: String, cmd: String) -> (type: String, protected: Bool) {
        let c = comm.lowercased()
        let both = (comm + " " + cmd).lowercased()
        if comm.hasPrefix("/System/") || comm.hasPrefix("/usr/libexec")
            || comm.hasPrefix("/usr/sbin") || comm.hasPrefix("/usr/bin") {
            return ("system", true)
        }
        for name in ["rapportd", "controlce", "controlcenter", "sharingd", "identityservices"] where c.contains(name) {
            return ("system", true)
        }
        let dev = ["python", "node", "http.server", "flask", "uvicorn", "gunicorn",
                   "ruby", "rails", "puma", "deno", "bun", "vite", "webpack", "next", "php", "-jar"]
        if dev.contains(where: { both.contains($0) }) { return ("dev", false) }
        if comm.contains(".app/Contents/MacOS/") { return ("app", false) }
        return ("other", false)
    }

    static func processName(comm: String, cmd: String) -> String {
        if let m = cmd.range(of: #"[^\s]+\.py"#, options: .regularExpression) {
            return String(cmd[m]).split(separator: "/").last.map(String.init) ?? "python"
        }
        if cmd.contains("http.server") { return "http.server" }
        if let r = comm.range(of: ".app/Contents/MacOS/") {
            return comm[..<r.lowerBound].split(separator: "/").last.map(String.init) ?? comm
        }
        return comm.split(separator: "/").last.map(String.init) ?? comm
    }

    static func portFrom(_ addr: String) -> Int? {
        // addr like "*:8787", "127.0.0.1:8787", "[::1]:8080"
        guard let colon = addr.lastIndex(of: ":") else { return nil }
        return Int(addr[addr.index(after: colon)...])
    }

    static func shorten(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }
}
