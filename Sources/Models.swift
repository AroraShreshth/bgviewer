import Foundation

enum ServiceKind: String, Sendable {
    case launchAgent   // ~/Library/LaunchAgents/*.plist  (can auto-restart)
    case brewService   // managed by `brew services`
    case process       // a loose process holding a listening TCP port
    case cron          // a crontab entry — read-only
}

enum RunState: String, Sendable {
    case running       // active, has a live pid
    case paused        // SIGSTOP'd (frozen)
    case loaded        // registered with launchd but idle right now
    case unloaded      // installed but not registered / off
    case disabled      // parked by bgviewer so it can't auto-start
}

enum ControlAction: Sendable {
    case startStop
    case pauseResume
    case restart
    case disable
    case enable
    case trash      // parked agents only: move the plist to the Trash
}

struct BackgroundService: Identifiable, Sendable {
    var id: String
    var name: String
    var subtitle: String
    var kind: ServiceKind
    var state: RunState
    var pid: Int? = nil
    var label: String? = nil        // launchd label
    var plistPath: String? = nil    // launch-agent plist location (current)
    var brewName: String? = nil     // homebrew formula
    var command: String? = nil      // full argv, used for tooltip + process restart
    var ports: [Int] = []
    var protected: Bool = false     // Apple/system process — destructive actions disabled
    var procType: String = ""       // "dev" | "app" | "system" | "other" (hogs get a "hog-" prefix)
    var domain: String = "user"     // launch agents: "user" (~/Library) or "machine" (/Library)
    var logPath: String? = nil      // agent StandardOutPath, when declared
}

struct ServiceGroup: Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var services: [BackgroundService]
}

// MARK: - Which controls apply to a given service

extension BackgroundService {
    var isActive: Bool { state == .running || state == .paused }

    var showStop: Bool {
        switch kind {
        case .process:                 return isActive
        case .launchAgent, .brewService: return isActive || state == .loaded
        case .cron:                    return false
        }
    }

    var showStart: Bool {
        switch kind {
        case .process, .cron:          return false
        case .launchAgent, .brewService: return state == .unloaded
        }
    }

    var canPause: Bool {
        (kind == .process || kind == .launchAgent) && pid != nil && isActive
    }

    var canRestart: Bool {
        switch kind {
        case .launchAgent: return isActive || state == .loaded
        case .brewService: return isActive
        case .process:     return procType == "dev" && isActive
        case .cron:        return false
        }
    }

    var canDisable: Bool { kind == .launchAgent && state != .disabled }
    var canEnable: Bool  { kind == .launchAgent && state == .disabled }

    /// Parked agents only — the plist is ours to remove, and Trash is recoverable.
    var canTrash: Bool {
        kind == .launchAgent && state == .disabled
            && (plistPath?.contains("Disabled by bgviewer") ?? false)
    }

    /// Ask before killing something that isn't obviously a throwaway dev server.
    var needsConfirm: Bool {
        kind == .process && (procType == "app" || procType == "other")
    }
}

/// Numeric semver comparison: is `a` strictly newer than `b`?
func isNewerVersion(_ a: String, than b: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".").map { Int($0) ?? 0 }
    }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let xi = i < x.count ? x[i] : 0
        let yi = i < y.count ? y[i] : 0
        if xi != yi { return xi > yi }
    }
    return false
}
