# Changelog

## 1.7.0 — 2026-07-17

- **Dev Junk view** (second tab in the Disk Map window, or straight from the
  Storage pane): finds regenerable build folders across your projects —
  node_modules, Python venvs, Rust target, CocoaPods, .next/.turbo caches,
  Xcode DerivedData — with per-project sizes and a total-reclaimable count
- **The one place bgviewer deletes** — because these folders rebuild on the
  next install. Every candidate must pass a guard (node_modules only counts
  with a package.json beside it; .venv only with pyvenv.cfg inside; target
  only with Cargo.toml), the guard is re-checked at delete time, and the
  delete button is two-step. A folder merely *named* node_modules is refused.
- Nested junk pruned (no node_modules-inside-node_modules noise); .git,
  Library and Trash never scanned
- Suggested by a user note — thank you!

## 1.6.0 — 2026-07-17

- **Disk Map**: a full resizable window (from the Storage pane) with a
  clickable pie of what's eating your disk — click a wedge or row to drill
  into folders, breadcrumbs to climb back out, tiny items grouped into an
  "everything else" wedge. Sizes computed lazily per level (`du`), cached per
  session, three at a time
- Scan any folder via a picker; files reveal in Finder; still zero delete
  buttons anywhere
- Test suite grown to 150 checks (pie geometry, hit-testing, du parsing,
  directory listing)

## 1.5.0 — 2026-07-14

- **Storage pane** (💾 drive button in the header): the biggest files sitting in
  Downloads, Desktop, Documents and Movies (over 100 MB), with size, location,
  and how long ago you touched them — plus a free-space bar for your startup
  disk in the pane's top-right corner
- Deliberately **no delete button**: rows only reveal in Finder; removing
  files stays a human decision
- Suggested by a user — thank you!

## 1.4.0 — 2026-07-14

- Settings panel (⚙ in the header): Alerts and Start-at-login moved out of the
  footer, each with a plain-English explanation, plus an Updates section with
  a check-now button and the no-telemetry disclosure
- Footer slimmed back down to "Show all" + status

## 1.3.0 — 2026-07-14

The awareness release.

- **Alerts**: opt-in notification the moment a new dev server starts listening —
  even while the dropdown is closed (1-minute background watch, dev servers
  only, baseline on enable so it never floods)
- **Scheduled (cron)**: read-only section showing `crontab -l` entries with
  humanized schedules ("daily at 0:00")
- **🗑 Trash for parked agents**: completes stop → pause → disable → *delete*;
  moves the plist to the Trash (recoverable), refuses anything not parked
- **Update check**: at most one GitHub API call every 6 hours; a green
  download button appears in the header when a newer release exists — this is
  the app's only network access
- Footer toggles tightened (All · Alerts · Login)
- Test suite grown to 117 checks

## 1.2.1 — 2026-07-14

- Quit is now a power button in the header (top right); footer decluttered

## 1.2.0 — 2026-07-14

- In-app help: an ⓘ button in the header explains every section and button,
  the safety model (nothing is ever deleted), and links to the project

## 1.1.0 — 2026-07-14

Coverage release — bgviewer now sees the background things that don't hold a port.

- **Machine-wide Agents**: `/Library/LaunchAgents` (Zoom/Logitech/AV-style vendor
  agents). Stop/restart work as usual; Disable uses launchd's per-user disable
  record — no admin rights needed, reversible per user
- **Resource Hogs**: background processes with sustained CPU (≥15%) or memory
  (≥1 GB) that hold no port — the "helper app quietly at 25% for days" class
- **Row details** on click: full command, Copy command, Reveal plist, View log,
  open `localhost:<port>` for dev servers
- **Search/filter** across names, ports, and command lines
- **Auto-refresh** every 6 s while the dropdown is open (brew status cached to
  keep ticks cheap)
- **Start at login** toggle in the footer (SMAppService)
- "Show inactive" is now off by default (persisted preference)
- Fixed: interpreter paths like `.pyenv` no longer mislabel `python -m` services;
  `python -m pkg.mod` rows are named by their module
- Safety: enabling an agent that was disabled-but-not-parked can no longer
  delete its plist (regression-tested)
- Test suite grown to 88 checks

## 1.0.2 — 2026-07-13

- New app icon (designed artwork run through the squircle pipeline in
  `assets/png_to_icns.swift`; source art committed as `assets/icon_art.png`)
- Icon shown at the top of the README

## 1.0.1 — 2026-07-13

- App icon (generated from the menu-bar gauge symbol; script in `assets/`)
- Universal binary and one-line installer, introduced just after 1.0.0, are
  now part of a tagged build

## 1.0.0 — 2026-07-13

Initial release.

- Menu-bar dropdown listing user launch agents, Homebrew services, and processes holding TCP ports
- Per-row controls: Stop, Pause/Resume, Restart, Disable, Re-enable
- Stop defeats `KeepAlive` agents (bootout, verified unloaded) and escalates SIGTERM → SIGKILL for stubborn processes
- Disable parks the agent plist in `~/Library/LaunchAgents/Disabled by bgviewer/` — fully reversible, survives login
- Apple/system processes are protected (no destructive actions offered)
- Action failures surface in the footer
- Subprocess runner with concurrent pipe draining and a timeout watchdog
- Single batched `ps` snapshot per scan; `brew`-managed plists deduplicated out of the agents list
- 59-test suite including integration tests against real launchd
