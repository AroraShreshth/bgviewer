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

// ───────────────────────────── run ─────────────────────────────

print("Running bgviewer tests\(unitOnly ? " (unit only)" : "")")
testShell()
testParsing()
testPsMerge()
testEligibility()
if unitOnly {
    print("\n(skipping integration tests — run ./test.sh without --unit locally)")
} else {
    testProcessStop()
    testPauseResume()
    testAgentLifecycle()
}

print("\n────────────────────────────")
print("\(passed) passed, \(failed) failed")
if failed > 0 {
    print("Failures:")
    for f in failures { print("  • \(f)") }
}
exit(failed == 0 ? 0 : 1)
