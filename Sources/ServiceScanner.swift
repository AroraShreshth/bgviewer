import Foundation

/// Discovers background things from five sources: user launch agents,
/// machine-wide launch agents, Homebrew services, processes holding a
/// listening TCP port, and background resource hogs.
enum ServiceScanner {
    static let uid = getuid()

    static let agentsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")

    /// Machine-wide agents (all users). They load into each user's gui session,
    /// so launchctl bootout/bootstrap work on them without root — only their
    /// plist files are admin-owned.
    static let machineAgentsDir = URL(fileURLWithPath: "/Library/LaunchAgents")

    /// Where we park plists that the user has "disabled" so launchd ignores
    /// them. launchd only scans the top level of LaunchAgents, never
    /// subdirectories, so anything in here is invisible to it.
    static let parkedDir = agentsDir.appendingPathComponent("Disabled by bgviewer", isDirectory: true)

    static var brewPath: String {
        let arm = "/opt/homebrew/bin/brew"
        return FileManager.default.isExecutableFile(atPath: arm) ? arm : "/usr/local/bin/brew"
    }

    // MARK: Top-level scan

    static func scan(freshBrew: Bool = true) -> [ServiceGroup] {
        let list = parseLaunchctlList()
        let disabledSet = parseDisabledLabels(Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).out)
        let userFiles = readAgentPlists(in: agentsDir)
        let machineFiles = readAgentPlists(in: machineAgentsDir)
        let portsByPid = listeningPorts()

        // One ps snapshot covering every pid we might display, instead of
        // several ps round-trips per row.
        var interesting = Set(portsByPid.keys)
        for f in userFiles + machineFiles {
            if let pid = list.pids[f.label] { interesting.insert(pid) }
        }
        let snap = psSnapshot(Array(interesting))

        let userAgentsAll = buildAgents(userFiles, list: list, snap: snap, domain: "user", disabled: disabledSet)
        // `brew services start` copies its plists into ~/Library/LaunchAgents;
        // those belong in the Homebrew section, not duplicated here.
        let userAgents = userAgentsAll.filter { !isBrewManagedLabel($0.label ?? "") }
        let machineAgents = buildAgents(machineFiles, list: list, snap: snap, domain: "machine", disabled: disabledSet)
        let parked = discoverDisabledAgents()
        let brew = discoverBrew(fresh: freshBrew)

        var skip = Set(userAgentsAll.compactMap { $0.pid })
        skip.formUnion(machineAgents.compactMap { $0.pid })
        for (label, pid) in list.pids where isBrewManagedLabel(label) { skip.insert(pid) }
        skip.insert(Int(getpid()))
        let procs = buildProcesses(portsByPid, snap: snap, excludePids: skip)

        // Hogs: heavy background processes that hold no port and aren't agents.
        var hogExclude = skip
        hogExclude.formUnion(portsByPid.keys)
        let hogRows = parseHogsPs(Shell.run("/bin/ps", ["axo", "pid=,pcpu=,rss=,etime=,comm="]).out)
        let hogs = buildHogs(hogRows, excludePids: hogExclude)

        var groups: [ServiceGroup] = []
        groups.append(ServiceGroup(
            id: "agents", title: "Auto-start Agents",
            subtitle: "Launch agents in ~/Library/LaunchAgents — these can relaunch themselves",
            services: userAgents.sorted { $0.name.lowercased() < $1.name.lowercased() }))

        if !machineAgents.isEmpty {
            groups.append(ServiceGroup(
                id: "machine", title: "Machine-wide Agents",
                subtitle: "Installed for all users in /Library/LaunchAgents — disabling blocks them for your user",
                services: machineAgents.sorted { $0.name.lowercased() < $1.name.lowercased() }))
        }

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

        if !hogs.isEmpty {
            groups.append(ServiceGroup(
                id: "hogs", title: "Resource Hogs",
                subtitle: "Background processes using significant CPU or memory",
                services: hogs))
        }

        let cron = discoverCron()
        if !cron.isEmpty {
            groups.append(ServiceGroup(
                id: "cron", title: "Scheduled (cron)",
                subtitle: "Read-only — entries from `crontab -l`",
                services: cron))
        }

        if !parked.isEmpty {
            groups.append(ServiceGroup(
                id: "disabled", title: "Disabled (parked)",
                subtitle: "Stopped and moved aside so macOS won't auto-start them",
                services: parked.sorted { $0.name.lowercased() < $1.name.lowercased() }))
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

    // MARK: launchctl list / print-disabled

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

    /// Parses `launchctl print-disabled gui/<uid>`: lines like
    ///   "com.foo.bar" => disabled
    static func parseDisabledLabels(_ output: String) -> Set<String> {
        var out = Set<String>()
        for line in output.split(separator: "\n") where line.contains("=> disabled") {
            if let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b {
                out.insert(String(line[line.index(after: a)..<b]))
            }
        }
        return out
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
                            snap: [Int: ProcInfo],
                            domain: String,
                            disabled: Set<String>) -> [BackgroundService] {
        var out: [BackgroundService] = []
        for f in files {
            let pid = list.pids[f.label]
            let isLoaded = list.loaded.contains(f.label)

            var state: RunState
            if let pid {
                state = (snap[pid]?.state.hasPrefix("T") ?? false) ? .paused : .running
            } else if isLoaded {
                state = .loaded
            } else if disabled.contains(f.label) {
                state = .disabled
            } else {
                state = .unloaded
            }

            let cmd = programSummary(f.dict)
            let keepAlive = hasKeepAlive(f.dict)

            var parts: [String] = []
            if let pid { parts.append("pid \(pid)") }
            if keepAlive { parts.append("↻ auto-restart") }
            if domain == "machine" { parts.append("all users") }
            parts.append(middleShorten(cmd, domain == "machine" ? 34 : 42))

            out.append(BackgroundService(
                id: "agent:\(domain):" + f.label, name: f.label, subtitle: parts.joined(separator: " · "),
                kind: .launchAgent, state: state, pid: pid,
                label: f.label, plistPath: f.url.path, command: cmd,
                protected: isAppleLabel(f.label), domain: domain,
                logPath: f.dict["StandardOutPath"] as? String))
        }
        return out
    }

    static func discoverDisabledAgents() -> [BackgroundService] {
        readAgentPlists(in: parkedDir).map { f in
            let cmd = programSummary(f.dict)
            return BackgroundService(
                id: "disabled:" + f.label, name: f.label, subtitle: middleShorten(cmd, 52),
                kind: .launchAgent, state: .disabled, pid: nil,
                label: f.label, plistPath: f.url.path, command: cmd)
        }
    }

    // MARK: Homebrew

    private static let brewCacheLock = NSLock()
    private static var brewCache: (services: [BackgroundService], at: Date)?

    /// `brew services list` boots ruby (~1s+), so auto-refresh ticks reuse a
    /// short-lived cache; manual refreshes and post-action rescans go fresh.
    static func discoverBrew(fresh: Bool = true) -> [BackgroundService] {
        brewCacheLock.lock()
        let cached = brewCache
        brewCacheLock.unlock()
        if !fresh, let cached, Date().timeIntervalSince(cached.at) < 30 {
            return cached.services
        }
        let services = parseBrew(Shell.run(brewPath, ["services", "list", "--json"]).out)
        brewCacheLock.lock()
        brewCache = (services, Date())
        brewCacheLock.unlock()
        return services
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

    // MARK: Resource hogs

    struct HogRow {
        let pid: Int
        let cpu: Double
        let rssKB: Int
        let etime: String
        let comm: String
    }

    /// Pure parser for `ps axo pid=,pcpu=,rss=,etime=,comm=` output.
    static func parseHogsPs(_ output: String) -> [HogRow] {
        var rows: [HogRow] = []
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            let p = t.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard p.count == 5, let pid = Int(p[0]), let cpu = Double(p[1]), let rss = Int(p[2]) else { continue }
            rows.append(HogRow(pid: pid, cpu: cpu, rssKB: rss, etime: String(p[3]),
                               comm: String(p[4]).trimmingCharacters(in: .whitespaces)))
        }
        return rows
    }

    /// Background processes burning real CPU (>= cpuFloor %) or memory
    /// (>= memFloorKB) that aren't already shown elsewhere. System processes
    /// are dropped — they'd be noise the user can't act on anyway.
    static func buildHogs(_ rows: [HogRow], excludePids: Set<Int>,
                          cpuFloor: Double = 15, memFloorKB: Int = 1_048_576,
                          limit: Int = 8) -> [BackgroundService] {
        let picked = rows
            .filter { !excludePids.contains($0.pid) && ($0.cpu >= cpuFloor || $0.rssKB >= memFloorKB) }
            .sorted { $0.cpu > $1.cpu }
        var out: [BackgroundService] = []
        for r in picked {
            let (type, protected) = classify(comm: r.comm, cmd: r.comm)
            if protected { continue }
            let mem = r.rssKB >= 1_048_576
                ? String(format: "%.1f GB", Double(r.rssKB) / 1_048_576)
                : "\(r.rssKB / 1024) MB"
            out.append(BackgroundService(
                id: "hog:\(r.pid)",
                name: processName(comm: r.comm, cmd: r.comm),
                subtitle: String(format: "%.0f%% CPU · %@ · up %@", r.cpu, mem, prettyEtime(r.etime)),
                kind: .process, state: .running, pid: r.pid,
                command: r.comm,
                // "hog-" prefix keeps Restart off: we only know the executable
                // path here, not the original arguments.
                procType: "hog-\(type)"))
            if out.count == limit { break }
        }
        return out
    }

    // MARK: Cron (read-only)

    static func discoverCron() -> [BackgroundService] {
        parseCrontab(Shell.run("/usr/bin/crontab", ["-l"]).out)
    }

    /// Pure parser for `crontab -l` output. Read-only by design — bgviewer
    /// displays cron entries but never edits the crontab.
    static func parseCrontab(_ output: String) -> [BackgroundService] {
        var out: [BackgroundService] = []
        for (i, raw) in output.split(separator: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // environment assignments like MAILTO=""
            if line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil { continue }

            var schedule: String
            var command: String
            if line.hasPrefix("@") {
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { continue }
                schedule = String(parts[0])
                command = String(parts[1])
            } else {
                let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
                guard parts.count == 6 else { continue }
                schedule = parts[0..<5].joined(separator: " ")
                command = String(parts[5])
            }
            out.append(BackgroundService(
                id: "cron:\(i)", name: prettyCron(schedule),
                subtitle: middleShorten(command, 52),
                kind: .cron, state: .loaded, command: command))
        }
        return out
    }

    /// Humanize the common cron shapes; fall back to the raw field string.
    static func prettyCron(_ schedule: String) -> String {
        switch schedule {
        case "@reboot":  return "at boot"
        case "@daily", "@midnight": return "daily at 0:00"
        case "@hourly":  return "hourly"
        case "@weekly":  return "weekly"
        case "@monthly": return "monthly"
        default: break
        }
        let f = schedule.split(separator: " ").map(String.init)
        guard f.count == 5 else { return schedule }
        if let m = Int(f[0]), let h = Int(f[1]), f[2] == "*", f[3] == "*", f[4] == "*" {
            return String(format: "daily at %d:%02d", h, m)
        }
        if let m = Int(f[0]), f[1] == "*", f[2] == "*", f[3] == "*", f[4] == "*" {
            return String(format: "hourly at :%02d", m)
        }
        return schedule
    }

    // MARK: Listener watch (notifications)

    /// Diff helper for the background watcher: which dev-server listeners are
    /// new since the previous tick? Keyed by port+name so a restart of the
    /// same server doesn't re-alert.
    static func newDevListeners(previous: Set<String>,
                                current: [BackgroundService]) -> (keys: Set<String>, fresh: [BackgroundService]) {
        var keys = Set<String>()
        var fresh: [BackgroundService] = []
        for s in current where s.kind == .process && s.procType == "dev" {
            var isNew = false
            for p in s.ports {
                let k = "\(p)|\(s.name)"
                keys.insert(k)
                if !previous.contains(k) { isNew = true }
            }
            if isNew { fresh.append(s) }
        }
        return (keys, fresh)
    }

    /// "02-23:00:54" -> "2d 23h", "23:13:12" -> "23h 13m", "17:55" -> "17m"
    static func prettyEtime(_ e: String) -> String {
        var days = 0
        var clock = e
        let dp = e.split(separator: "-", maxSplits: 1)
        if dp.count == 2, let d = Int(dp[0]) { days = d; clock = String(dp[1]) }
        let c = clock.split(separator: ":").compactMap { Int($0) }
        if days > 0 { return "\(days)d \(c.first ?? 0)h" }
        if c.count == 3 { return c[0] > 0 ? "\(c[0])h \(c[1])m" : "\(c[1])m" }
        if c.count == 2 { return "\(c[0])m" }
        return e
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
            || comm.hasPrefix("/usr/sbin") || comm.hasPrefix("/usr/bin")
            || comm.hasPrefix("/sbin") || comm.hasPrefix("/bin") {
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
        // Lookahead keeps ".pyenv"-style interpreter paths from matching.
        if let m = cmd.range(of: #"[^\s]+\.py(?=\s|$)"#, options: .regularExpression) {
            return String(cmd[m]).split(separator: "/").last.map(String.init) ?? "python"
        }
        if cmd.contains("http.server") { return "http.server" }
        if let m = cmd.range(of: #"-m ([\w\.]+)"#, options: .regularExpression) {
            return String(cmd[m].dropFirst(3))   // `python -m orion.server` -> orion.server
        }
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

    /// Ellipsize the middle so the informative tail (script name, args) survives.
    static func middleShorten(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        let keep = n - 1
        let head = keep * 2 / 3
        let tail = keep - head
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }
}
