import Foundation

enum ServiceKind: String, Sendable {
    case launchAgent   // ~/Library/LaunchAgents/*.plist  (can auto-restart)
    case brewService   // managed by `brew services`
    case process       // a loose process holding a listening TCP port
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
        }
    }

    var showStart: Bool {
        switch kind {
        case .process:                 return false
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
        }
    }

    var canDisable: Bool { kind == .launchAgent && state != .disabled }
    var canEnable: Bool  { kind == .launchAgent && state == .disabled }

    /// Ask before killing something that isn't obviously a throwaway dev server.
    var needsConfirm: Bool {
        kind == .process && (procType == "app" || procType == "other")
    }
}
