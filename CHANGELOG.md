# Changelog

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
