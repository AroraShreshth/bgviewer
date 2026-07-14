# Changelog

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
