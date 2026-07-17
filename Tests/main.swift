import Foundation

// Lightweight test runner (no XCTest needed): compiles against the real app
// sources and exits non-zero if any check fails.
//
//   ./test.sh          run everything (unit + integration)
//   ./test.sh --unit   unit tests only — no launchctl / no processes spawned,
//                      safe for headless CI runners

let unitOnly = CommandLine.arguments.contains("--unit")

var passed = 0, failed = 0
var failures: [String] = []

func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("  ✓ \(name)") }
    else { failed += 1; failures.append(name); print("  ✗ FAIL: \(name)") }
}

func svc(kind: ServiceKind, state: RunState, pid: Int? = nil,
         label: String? = nil, plist: String? = nil, brew: String? = nil,
         command: String? = nil, procType: String = "") -> BackgroundService {
    BackgroundService(id: "t", name: "t", subtitle: "", kind: kind, state: state,
                      pid: pid, label: label, plistPath: plist, brewName: brew,
                      command: command, procType: procType)
}

/// Spawn a process *detached* (reparented to launchd) so — like the real
/// services the app manages — it is not our child. That keeps `kill -0`
/// honest: a killed non-child is reaped by launchd, whereas a killed child
/// would linger as a zombie and still report "alive".
func spawnDetached(_ cmd: String) -> Int? {
    let r = Shell.sh("nohup \(cmd) >/dev/null 2>&1 & echo $!")
    return Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
}

// ───────────────────────── Unit: shell runner ─────────────────────────

func testShell() {
    print("\n• Unit — shell runner")

    let r = Shell.run("/bin/echo", ["hello"])
    check("echo captured", r.ok && r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")

    let bad = Shell.run("/no/such/tool", [])
    check("missing binary -> error, no crash", !bad.ok)

    // A child that floods stderr past the 64KB pipe buffer used to deadlock
    // the sequential reader. Both pipes are drained concurrently now.
    let flood = Shell.sh("i=0; while [ $i -lt 4000 ]; do echo 0123456789012345678901234567890123456789 1>&2; i=$((i+1)); done; echo done", timeout: 15)
    check("stderr flood: no deadlock, stdout intact", flood.ok && flood.out.contains("done"))
    check("stderr flood: all stderr captured", flood.err.count > 100_000)

    let t0 = Date()
    let slow = Shell.run("/bin/sleep", ["30"], timeout: 1)
    check("watchdog kills runaway command", slow.timedOut && !slow.ok)
    check("watchdog returns promptly", Date().timeIntervalSince(t0) < 5)
}

// ───────────────────────── Unit: parsing ─────────────────────────

func testParsing() {
    print("\n• Unit — parsing")

    check("portFrom *:8787 == 8787", ServiceScanner.portFrom("*:8787") == 8787)
    check("portFrom 127.0.0.1:8091 == 8091", ServiceScanner.portFrom("127.0.0.1:8091") == 8091)
    check("portFrom [::1]:8080 == 8080", ServiceScanner.portFrom("[::1]:8080") == 8080)
    check("portFrom junk == nil", ServiceScanner.portFrom("nope") == nil)

    check("classify pyenv python -> dev", ServiceScanner.classify(comm: "/Users/x/.pyenv/versions/3.12.3/bin/python3", cmd: "python3 live_receiver.py").type == "dev")
    check("classify dev not protected", ServiceScanner.classify(comm: "/Users/x/.venv/bin/python", cmd: "python demo.py").protected == false)
    check("classify /usr/sbin -> system+protected", ServiceScanner.classify(comm: "/usr/sbin/foo", cmd: "foo") == ("system", true))
    check("classify rapportd -> system", ServiceScanner.classify(comm: "/opt/x/rapportd", cmd: "rapportd").type == "system")
    check("classify .app bundle -> app", ServiceScanner.classify(comm: "/Applications/Spotify.app/Contents/MacOS/Spotify", cmd: "Spotify").type == "app")

    check("processName picks .py script", ServiceScanner.processName(comm: "/x/python3", cmd: "/x/python3 /a/live_receiver.py --port 8787") == "live_receiver.py")
    check("processName http.server", ServiceScanner.processName(comm: "/x/python", cmd: "python -m http.server 8092") == "http.server")
    check("processName ignores .pyenv interpreter path", ServiceScanner.processName(comm: "/u/.pyenv/versions/3.12.3/bin/python3", cmd: "/u/.pyenv/versions/3.12.3/bin/python3 -m orion.server") == "orion.server")
    check("processName names -m module runs", ServiceScanner.processName(comm: "/x/python3", cmd: "/x/python3 -m mypkg.web --port 1") == "mypkg.web")
    check("processName app name from bundle", ServiceScanner.processName(comm: "/Applications/Zed.app/Contents/MacOS/zed", cmd: "zed") == "Zed")

    let lc = "PID\tStatus\tLabel\n837\t0\tcom.healthtop.livereceiver\n-\t0\tcom.orion.fetch\n-\t78\tcom.healthtop.refresh"
    let p = ServiceScanner.parseLaunchctl(lc)
    check("launchctl parse: running pid", p.pids["com.healthtop.livereceiver"] == 837)
    check("launchctl parse: loaded no pid", p.loaded.contains("com.orion.fetch") && p.pids["com.orion.fetch"] == nil)
    check("launchctl parse: interval job loaded", p.loaded.contains("com.healthtop.refresh"))

    let brew = ServiceScanner.parseBrew("[{\"name\":\"redis\",\"status\":\"started\"},{\"name\":\"postgresql@16\",\"status\":\"none\"}]")
    check("brew parse count", brew.count == 2)
    check("brew started -> running", brew.first { $0.name == "redis" }?.state == .running)
    check("brew none -> off/unloaded", brew.first { $0.name == "postgresql@16" }?.state == .unloaded)
    let brewErr = ServiceScanner.parseBrew("[{\"name\":\"kafka\",\"status\":\"error\",\"exit_code\":78}]")
    check("brew error -> off + hint", brewErr.first?.state == .unloaded && (brewErr.first?.subtitle.contains("error") ?? false))
    check("brew scheduled -> idle", ServiceScanner.parseBrew("[{\"name\":\"x\",\"status\":\"scheduled\"}]").first?.state == .loaded)
    check("brew garbage json -> empty, no crash", ServiceScanner.parseBrew("not json at all").isEmpty)

    check("brew-managed label filtered from agents", ServiceScanner.isBrewManagedLabel("homebrew.mxcl.postgresql@16"))
    check("normal label not brew-managed", !ServiceScanner.isBrewManagedLabel("com.healthtop.livereceiver"))
}

// ───────────────────────── Unit: ps snapshot merge ─────────────────────────

func testPsMerge() {
    print("\n• Unit — batched ps snapshot")

    let stateComm = """
          837 SN   /Users/x/.pyenv/versions/3.12.3/bin/python3.12
          946 T    /Applications/Epic Games Launcher.app/Contents/MacOS/EpicGamesLauncher
    """
    let command = """
          837 /Users/x/.pyenv/versions/3.12.3/bin/python3 live_receiver.py --port 8787
          946 /Applications/Epic Games Launcher.app/Contents/MacOS/EpicGamesLauncher -silent
    """
    let m = ServiceScanner.mergePsOutputs(stateComm: stateComm, command: command)
    check("merge: both pids present", m.count == 2)
    check("merge: paused state detected", m[946]?.state == "T")
    check("merge: comm with spaces kept whole", m[946]?.comm == "/Applications/Epic Games Launcher.app/Contents/MacOS/EpicGamesLauncher")
    check("merge: full command with args", m[837]?.command.hasSuffix("--port 8787") == true)
    check("merge: pid only in command output survives", ServiceScanner.mergePsOutputs(stateComm: "", command: "  99 /bin/thing")[99]?.command == "/bin/thing")

    // Dead pid dropped: in snapshot but lsof-only pids with no ps info are skipped.
    let procs = ServiceScanner.buildProcesses([1234: [8080]], snap: [:], excludePids: [])
    check("pid that died mid-scan is dropped, no crash", procs.isEmpty)

    // Exclusion actually excludes.
    let excluded = ServiceScanner.buildProcesses(
        [837: [8787]],
        snap: [837: ServiceScanner.ProcInfo(state: "S", comm: "/x/python3", command: "python3 x.py")],
        excludePids: [837])
    check("excluded pid not listed", excluded.isEmpty)

    // And a live one builds a row with ports sorted.
    let built = ServiceScanner.buildProcesses(
        [837: [9000, 8787]],
        snap: [837: ServiceScanner.ProcInfo(state: "S", comm: "/x/python3", command: "python3 live_receiver.py")],
        excludePids: [])
    check("row built with sorted ports", built.first?.ports == [8787, 9000])
    check("row classified dev", built.first?.procType == "dev")
}

// ─────────────────── Unit: which buttons show ───────────────────

func testEligibility() {
    print("\n• Unit — button eligibility")

    let dev = svc(kind: .process, state: .running, pid: 8460, procType: "dev")
    check("dev proc: stop+pause+restart, no disable", dev.showStop && dev.canPause && dev.canRestart && !dev.canDisable)

    let app = svc(kind: .process, state: .running, pid: 1, procType: "app")
    check("app proc: needs confirm, no restart", app.needsConfirm && !app.canRestart)

    let run = svc(kind: .launchAgent, state: .running, pid: 1, label: "a")
    check("running agent: stop+pause+restart+disable, no start", run.showStop && run.canPause && run.canRestart && run.canDisable && !run.showStart)

    let off = svc(kind: .launchAgent, state: .unloaded, label: "a")
    check("off agent: start yes, stop no, disable yes", off.showStart && !off.showStop && off.canDisable)

    let idle = svc(kind: .launchAgent, state: .loaded, label: "a")
    check("idle agent: stop yes, start no, pause no", idle.showStop && !idle.showStart && !idle.canPause)

    let disabled = svc(kind: .launchAgent, state: .disabled, label: "a")
    check("disabled agent: enable yes, disable no", disabled.canEnable && !disabled.canDisable)

    let brew = svc(kind: .brewService, state: .running, brew: "redis")
    check("brew running: stop+restart, no pause", brew.showStop && brew.canRestart && !brew.canPause)
}

// ───────────────────────── Unit: v1.1 additions ─────────────────────────

func testDisabledParsing() {
    print("\n• Unit — launchctl print-disabled parsing")
    let sample = """
    \tdisabled services = {
    \t\t"com.docker.helper" => enabled
    \t\t"com.apple.ManagedClientAgent.enrollagent" => disabled
    \t\t"com.foo.bar" => disabled
    \t}
    """
    let d = ServiceScanner.parseDisabledLabels(sample)
    check("disabled labels extracted", d == Set(["com.apple.ManagedClientAgent.enrollagent", "com.foo.bar"]))
    check("enabled labels not included", !d.contains("com.docker.helper"))
    check("garbage input -> empty", ServiceScanner.parseDisabledLabels("nope").isEmpty)
}

func testEtimeAndShorten() {
    print("\n• Unit — uptime formatting + middle truncation")
    check("etime days", ServiceScanner.prettyEtime("02-23:00:54") == "2d 23h")
    check("etime hours", ServiceScanner.prettyEtime("23:13:12") == "23h 13m")
    check("etime sub-hour", ServiceScanner.prettyEtime("00:17:55") == "17m")
    check("etime minutes", ServiceScanner.prettyEtime("17:55") == "17m")
    let long = "/Users/shreshth/.pyenv/versions/3.12.3/bin/python3 /Users/shreshth/Desktop/live_receiver.py --port 8787"
    let cut = ServiceScanner.middleShorten(long, 44)
    check("middleShorten keeps the informative tail", cut.count <= 44 && cut.hasSuffix("--port 8787") && cut.contains("…"))
    check("middleShorten leaves short strings alone", ServiceScanner.middleShorten("abc", 44) == "abc")
}

func testHogs() {
    print("\n• Unit — resource hogs")
    let out = """
          837  48.0  123456 10-13:32:39 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
          900  28.9  345678 02-23:00:54 /Applications/Wispr Flow.app/Contents/Frameworks/Wispr Flow Helper.app/Contents/MacOS/Wispr Flow Helper
          901   0.1 2097152    23:13:12 /Applications/Big.app/Contents/MacOS/Big
          902   5.0    1024       17:55 /Applications/Quiet.app/Contents/MacOS/Quiet
          903  99.0    2048    01:02:03 /Applications/Excluded.app/Contents/MacOS/Excluded
    """
    let rows = ServiceScanner.parseHogsPs(out)
    check("hog rows parsed, comm with spaces intact", rows.count == 5 && rows[1].comm.hasSuffix("Wispr Flow Helper"))
    let hogs = ServiceScanner.buildHogs(rows, excludePids: [903])
    check("system process never a hog (WindowServer)", !hogs.contains { $0.pid == 837 })
    check("sustained-CPU helper picked up", hogs.contains { $0.pid == 900 })
    check("memory hog picked up (2 GB, idle)", hogs.contains { $0.pid == 901 })
    check("quiet process not flagged", !hogs.contains { $0.pid == 902 })
    check("already-shown pid excluded", !hogs.contains { $0.pid == 903 })
    check("sorted by CPU, worst first", hogs.first?.pid == 900)
    check("hogs offer stop+pause but never restart", hogs.allSatisfy { $0.showStop && $0.canPause && !$0.canRestart })
    check("hog subtitle carries cpu · mem · uptime", hogs.first?.subtitle.contains("29% CPU") == true && hogs.first!.subtitle.contains("up 2d 23h"))
}

func testMachineAgents() {
    print("\n• Unit — machine-wide agents")
    let plist = ServiceScanner.AgentPlist(
        url: URL(fileURLWithPath: "/Library/LaunchAgents/us.zoom.updater.plist"),
        dict: ["Label": "us.zoom.updater", "ProgramArguments": ["/x/zoom", "--check"]],
        label: "us.zoom.updater")
    let none: (loaded: Set<String>, pids: [String: Int]) = ([], [:])
    let a = ServiceScanner.buildAgents([plist], list: none, snap: [:], domain: "machine", disabled: ["us.zoom.updater"])
    check("launchd disable record -> disabled state", a.first?.state == .disabled)
    check("machine domain + 'all users' marker", a.first?.domain == "machine" && a.first!.subtitle.contains("all users"))
    check("disabled machine agent: enable yes, disable no", a.first!.canEnable && !a.first!.canDisable)
    let b = ServiceScanner.buildAgents([plist], list: (["us.zoom.updater"], ["us.zoom.updater": 55]), snap: [:], domain: "machine", disabled: [])
    check("running machine agent has pid + controls", b.first?.state == .running && b.first?.pid == 55 && b.first!.canDisable)
    let c = ServiceScanner.buildAgents([plist], list: none, snap: [:], domain: "user", disabled: [])
    check("user agent unaffected by machine logic", c.first?.state == .unloaded && c.first?.domain == "user")
}

// ───────────────────────── Unit: v1.3 additions ─────────────────────────

func testCron() {
    print("\n• Unit — crontab parsing")
    let tab = """
    # nightly maintenance
    MAILTO=""
    0 0 * * * cd /Users/x/Developer/agents && git pull
    30 9 * * * /usr/local/bin/backup.sh --fast
    15 * * * * echo tick
    @reboot /Users/x/startup.sh
    @daily /Users/x/daily.sh
    not a cron line
    """
    let jobs = ServiceScanner.parseCrontab(tab)
    check("cron: comments/env/garbage skipped, 5 entries", jobs.count == 5)
    check("cron: daily schedule humanized", jobs[0].name == "daily at 0:00")
    check("cron: 9:30 humanized", jobs[1].name == "daily at 9:30")
    check("cron: hourly humanized", jobs[2].name == "hourly at :15")
    check("cron: @reboot humanized", jobs[3].name == "at boot")
    check("cron: @daily humanized", jobs[4].name == "daily at 0:00")
    check("cron: command preserved", jobs[1].command == "/usr/local/bin/backup.sh --fast")
    check("cron: read-only — no buttons at all", jobs.allSatisfy { !$0.showStop && !$0.showStart && !$0.canPause && !$0.canRestart && !$0.canDisable && !$0.canTrash })
    check("cron: empty crontab -> empty", ServiceScanner.parseCrontab("").isEmpty)
}

func testVersionCompare() {
    print("\n• Unit — version comparison")
    check("1.3.0 newer than 1.2.1", isNewerVersion("1.3.0", than: "1.2.1"))
    check("v-prefix handled", isNewerVersion("v1.10.0", than: "1.9.9"))
    check("numeric not lexicographic", isNewerVersion("1.10.0", than: "1.9.0"))
    check("equal is not newer", !isNewerVersion("1.2.1", than: "1.2.1"))
    check("older is not newer", !isNewerVersion("1.2.0", than: "1.2.1"))
    check("longer equal prefix", isNewerVersion("1.2.1.1", than: "1.2.1"))
}

func testListenerDiff() {
    print("\n• Unit — new-listener diff (alerts)")
    func listener(_ pid: Int, _ name: String, _ ports: [Int], type: String = "dev") -> BackgroundService {
        BackgroundService(id: "proc:\(pid)", name: name, subtitle: "", kind: .process,
                          state: .running, pid: pid, command: name, ports: ports, procType: type)
    }
    let first = [listener(1, "demo.py", [8091]), listener(2, "Spotify", [7768], type: "app")]
    let r1 = ServiceScanner.newDevListeners(previous: [], current: first)
    check("baseline records dev listeners only", r1.keys == ["8091|demo.py"])
    check("first sighting reported as fresh", r1.fresh.map { $0.pid } == [1])
    check("app listeners never alert", !r1.fresh.contains { $0.name == "Spotify" })

    let second = [listener(9, "demo.py", [8091]), listener(3, "next-server", [3000])]
    let r2 = ServiceScanner.newDevListeners(previous: r1.keys, current: second)
    check("same server+port after restart: no re-alert", !r2.fresh.contains { $0.name == "demo.py" })
    check("genuinely new server alerts", r2.fresh.map { $0.name } == ["next-server"])
    check("keys roll forward", r2.keys == ["8091|demo.py", "3000|next-server"])
}

func testTrashEligibility() {
    print("\n• Unit — trash eligibility")
    let parked = svc(kind: .launchAgent, state: .disabled, label: "a",
                     plist: "/Users/x/Library/LaunchAgents/Disabled by bgviewer/a.plist")
    check("parked agent can be trashed", parked.canTrash)
    let unparked = svc(kind: .launchAgent, state: .disabled, label: "a",
                       plist: "/Library/LaunchAgents/a.plist")
    check("non-parked disabled agent cannot", !unparked.canTrash)
    let active = svc(kind: .launchAgent, state: .running, pid: 1, label: "a",
                     plist: "/Users/x/Library/LaunchAgents/Disabled by bgviewer/a.plist")
    check("running agent cannot be trashed", !active.canTrash)
}

// ───────────────────────── Unit: storage pane ─────────────────────────

func testDiskScanner() {
    print("\n• Unit — storage pane (big files)")
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("bgviewer-disk-test-\(ProcessInfo.processInfo.processIdentifier)")
    let sub = tmp.appendingPathComponent("nested")
    try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    // Sizes are tiny; the threshold is injected so the test stays fast.
    fm.createFile(atPath: tmp.appendingPathComponent("big.dmg").path, contents: Data(count: 3000))
    fm.createFile(atPath: tmp.appendingPathComponent("small.txt").path, contents: Data(count: 500))
    fm.createFile(atPath: sub.appendingPathComponent("huge.mp4").path, contents: Data(count: 5000))
    fm.createFile(atPath: tmp.appendingPathComponent(".hidden.zip").path, contents: Data(count: 9000))

    let found = DiskScanner.scanBigFiles(in: [tmp], minBytes: 1000, limit: 10)
    check("finds files over threshold, recursing", found.count == 2)
    check("sorted biggest first", found.first?.name == "huge.mp4" && found.first?.sizeBytes == 5000)
    check("below-threshold file skipped", !found.contains { $0.name == "small.txt" })
    check("hidden files skipped", !found.contains { $0.name.contains("hidden") })

    let capped = DiskScanner.scanBigFiles(in: [tmp], minBytes: 1000, limit: 1)
    check("limit respected", capped.count == 1 && capped.first?.name == "huge.mp4")

    check("missing dir -> empty, no crash", DiskScanner.scanBigFiles(in: [tmp.appendingPathComponent("nope")], minBytes: 1).isEmpty)

    let t = DiskScanner.top([
        BigFile(path: "/a", sizeBytes: 10, modified: nil),
        BigFile(path: "/b", sizeBytes: 30, modified: nil),
        BigFile(path: "/c", sizeBytes: 20, modified: nil),
    ], limit: 2)
    check("top(): sorts desc and caps", t.map { $0.path } == ["/b", "/c"])

    if let space = DiskScanner.diskSpace() {
        check("diskSpace(): sane values", space.free > 0 && space.total >= space.free)
    } else {
        check("diskSpace(): returned nil on a real volume", false)
    }

    check("humanSize formats", DiskScanner.humanSize(5 * 1024 * 1024).contains("MB"))
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    check("shortFolder abbreviates home", DiskScanner.shortFolder("\(home)/Downloads/big.dmg") == "~/Downloads")
    check("icon: dmg", DiskScanner.icon(for: "x.dmg") == "opticaldiscdrive")
    check("icon: video", DiskScanner.icon(for: "movie.MKV") == "film")
    check("icon: model weights", DiskScanner.icon(for: "llama.gguf") == "cpu")
    check("icon: fallback", DiskScanner.icon(for: "weird.xyz") == "doc")
}

// ─────────────── Integration: STOP really stops ───────────────

func testProcessStop() {
    print("\n• Integration — process stop")

    guard let pid = spawnDetached("/bin/sleep 100000") else { check("spawn sleep", false); return }
    let err = ServiceControl.perform(.startStop, on: svc(kind: .process, state: .running, pid: pid, procType: "dev"))
    check("stop a normal process: no error", err == nil)
    check("stop a normal process: it is dead", !ServiceControl.isAlive(pid))

    // A process that traps & ignores SIGTERM must be escalated to SIGKILL.
    guard let stubborn = spawnDetached("/bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done'") else { check("spawn stubborn", false); return }
    let err2 = ServiceControl.perform(.startStop, on: svc(kind: .process, state: .running, pid: stubborn, procType: "dev"))
    check("stop TERM-ignoring process: escalates to KILL and dies", err2 == nil && !ServiceControl.isAlive(stubborn))
}

func testPauseResume() {
    print("\n• Integration — pause / resume")

    guard let pid = spawnDetached("/bin/sleep 100000") else { check("spawn sleep", false); return }
    _ = ServiceControl.perform(.pauseResume, on: svc(kind: .process, state: .running, pid: pid, procType: "dev"))
    usleep(250_000)
    check("pause freezes the process", ServiceScanner.isPaused(pid))
    _ = ServiceControl.perform(.pauseResume, on: svc(kind: .process, state: .paused, pid: pid, procType: "dev"))
    usleep(250_000)
    check("resume unfreezes the process", !ServiceScanner.isPaused(pid))
    Shell.run("/bin/kill", ["-KILL", "\(pid)"])
}

func testAgentLifecycle() {
    print("\n• Integration — launch-agent stop / disable / enable")

    let label = "com.bgviewer.selftest"
    let uid = getuid()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let plistPath = home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
    let parkedPath = ServiceScanner.parkedDir.appendingPathComponent("\(label).plist").path
    let fm = FileManager.default

    // Clean slate.
    Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])
    try? fm.removeItem(atPath: plistPath)
    try? fm.removeItem(atPath: parkedPath)
    try? fm.createDirectory(at: home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)

    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>\(label)</string>
    <key>ProgramArguments</key><array><string>/bin/sleep</string><string>100000</string></array>
    <key>KeepAlive</key><true/>
    <key>RunAtLoad</key><true/>
    </dict></plist>
    """
    try? xml.write(toFile: plistPath, atomically: true, encoding: .utf8)

    // Load and confirm it's running.
    Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath])
    usleep(700_000)
    let pid1 = ServiceScanner.parseLaunchctlList().pids[label]
    check("agent loads and runs (has pid)", pid1 != nil)

    // STOP — and it must NOT come back despite KeepAlive.
    let stopErr = ServiceControl.perform(.startStop, on: svc(kind: .launchAgent, state: .running, pid: pid1, label: label, plist: plistPath))
    check("stop KeepAlive agent: no error", stopErr == nil)
    usleep(500_000)
    check("stop KeepAlive agent: really unloaded (didn't respawn)", !ServiceScanner.parseLaunchctlList().loaded.contains(label))

    // DISABLE — plist gets parked out of LaunchAgents.
    let disErr = ServiceControl.perform(.disable, on: svc(kind: .launchAgent, state: .unloaded, label: label, plist: plistPath))
    check("disable: no error", disErr == nil)
    check("disable: plist moved out of LaunchAgents", !fm.fileExists(atPath: plistPath) && fm.fileExists(atPath: parkedPath))

    // ENABLE — restore and run again.
    let enErr = ServiceControl.perform(.enable, on: svc(kind: .launchAgent, state: .disabled, label: label, plist: parkedPath))
    check("enable: no error", enErr == nil)
    usleep(700_000)
    check("enable: plist back in LaunchAgents", fm.fileExists(atPath: plistPath))
    check("enable: agent runs again", ServiceScanner.parseLaunchctlList().pids[label] != nil)

    // Cleanup — leave the machine exactly as we found it.
    Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])
    try? fm.removeItem(atPath: plistPath)
    try? fm.removeItem(atPath: parkedPath)
    check("cleanup: nothing left behind", !fm.fileExists(atPath: plistPath) && !fm.fileExists(atPath: parkedPath) && !ServiceScanner.parseLaunchctlList().loaded.contains(label))
}

// ─────── Integration: enabling a disabled-but-NOT-parked agent must not eat the plist ───────

func testDisabledOnlyEnable() {
    print("\n• Integration — enable of a disabled-but-not-parked agent")
    let label = "com.bgviewer.selftest2"
    let uid = getuid()
    let fm = FileManager.default
    let plistPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist").path

    // Clean slate.
    Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])
    try? fm.removeItem(atPath: plistPath)

    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>\(label)</string>
    <key>ProgramArguments</key><array><string>/bin/sleep</string><string>100000</string></array>
    <key>RunAtLoad</key><true/>
    </dict></plist>
    """
    try? xml.write(toFile: plistPath, atomically: true, encoding: .utf8)

    // Disabled via launchctl only — the plist stays in LaunchAgents,
    // exactly like a machine agent or an externally-disabled user agent.
    Shell.run("/bin/launchctl", ["disable", "gui/\(uid)/\(label)"])

    let err = ServiceControl.perform(.enable, on: svc(kind: .launchAgent, state: .disabled, label: label, plist: plistPath))
    check("enable non-parked: no error", err == nil)
    check("enable non-parked: plist NOT deleted", fm.fileExists(atPath: plistPath))
    usleep(700_000)
    check("enable non-parked: agent loaded again", ServiceScanner.parseLaunchctlList().loaded.contains(label))

    // Cleanup.
    Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])
    try? fm.removeItem(atPath: plistPath)
    check("cleanup: nothing left behind", !fm.fileExists(atPath: plistPath) && !ServiceScanner.parseLaunchctlList().loaded.contains(label))
}

// ─────────────── Integration: trash a parked agent ───────────────

func testTrashParkedAgent() {
    print("\n• Integration — trash a parked agent")
    let label = "com.bgviewer.selftest3"
    let fm = FileManager.default
    try? fm.createDirectory(at: ServiceScanner.parkedDir, withIntermediateDirectories: true)
    let parkedPath = ServiceScanner.parkedDir.appendingPathComponent("\(label).plist").path
    let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Label</key><string>\(label)</string><key>Program</key><string>/bin/sleep</string></dict></plist>"
    try? xml.write(toFile: parkedPath, atomically: true, encoding: .utf8)
    check("setup: parked plist exists", fm.fileExists(atPath: parkedPath))

    let s = svc(kind: .launchAgent, state: .disabled, label: label, plist: parkedPath)
    let err = ServiceControl.perform(.trash, on: s)
    check("trash: no error", err == nil)
    check("trash: gone from parked dir", !fm.fileExists(atPath: parkedPath))

    // Clean the copy out of the user's Trash so nothing lingers.
    let trashed = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(label).plist")
    let inTrash = fm.fileExists(atPath: trashed.path)
    check("trash: recoverable — found in ~/.Trash", inTrash)
    if inTrash { try? fm.removeItem(at: trashed) }

    // A non-parked path must be refused.
    let refuse = ServiceControl.perform(.trash, on: svc(kind: .launchAgent, state: .disabled, label: label, plist: "/Library/LaunchAgents/\(label).plist"))
    check("trash: refuses non-parked plists", refuse != nil)
}

// ───────────────────────────── run ─────────────────────────────

print("Running bgviewer tests\(unitOnly ? " (unit only)" : "")")
testShell()
testParsing()
testPsMerge()
testEligibility()
testDisabledParsing()
testEtimeAndShorten()
testHogs()
testMachineAgents()
testCron()
testVersionCompare()
testListenerDiff()
testTrashEligibility()
testDiskScanner()
if unitOnly {
    print("\n(skipping integration tests — run ./test.sh without --unit locally)")
} else {
    testProcessStop()
    testPauseResume()
    testAgentLifecycle()
    testDisabledOnlyEnable()
    testTrashParkedAgent()
}

print("\n────────────────────────────")
print("\(passed) passed, \(failed) failed")
if failed > 0 {
    print("Failures:")
    for f in failures { print("  • \(f)") }
}
exit(failed == 0 ? 0 : 1)
