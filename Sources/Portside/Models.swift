import Foundation

/// A stack of servers started/stopped as one unit. Occupies one row in the
/// popover; clicking unfurls its members inline.
struct Project: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var collapsed: Bool = false
    var orderedStart: Bool = false // gate each member on TCP readiness
}

/// Pure aggregate of a project's member statuses — drives the project chip.
enum ProjectAggregate: Equatable {
    case empty
    case allStopped
    case partial(up: Int, total: Int)
    case allRunning(total: Int)

    static func compute(_ statuses: [ServerStatus]) -> ProjectAggregate {
        guard !statuses.isEmpty else { return .empty }
        let up = statuses.filter(\.isUp).count
        let anyStarting = statuses.contains {
            if case .starting = $0 { return true }
            return false
        }
        if up == 0 { return .allStopped }
        // A member still binding its port is not steady state — the chip
        // must stay orange until everything is actually running.
        if up == statuses.count && !anyStarting { return .allRunning(total: up) }
        return .partial(up: up, total: statuses.count)
    }
}

/// A saved, user-configured local server: a directory + command you can start/stop.
struct Server: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var directory: String          // may contain "~"
    var command: String            // e.g. "npm run dev"
    var port: Int?                 // expected port; used for matching + open-in-browser
    var urlOverride: String?       // e.g. "https://localhost:8443"
    var projectID: UUID? = nil     // membership in a Project (stack)
    var expandedDirectory: String {
        (directory as NSString).expandingTildeInPath
    }
}

/// A restart recipe pre-computed off the main thread during a scan.
struct AdoptionRecipe: Equatable, Hashable {
    var name: String
    var directory: String   // abbreviated with ~
    var command: String
}

/// A listening TCP server discovered via lsof + syscalls.
struct DetectedServer: Identifiable, Equatable, Hashable {
    let pid: Int32
    let port: Int
    let pgid: Int32
    let processName: String
    let commandLine: String?      // argv joined for display
    let cwd: String?
    let adoption: AdoptionRecipe? // nil when there's nothing safe to restart

    var id: String { "\(pid):\(port)" }

    /// Best human-readable identity: server folder name if we know the cwd.
    /// Resolved once: this runs in every row's body, and realpath(3) is a
    /// syscall chain, not a string operation.
    private static let canonicalHome = Matching.canonicalPath(NSHomeDirectory())

    var displayName: String {
        // $HOME is not a project, and a row named after the user's home
        // folder is a row named after the user. Fall back to the process.
        if let cwd, cwd != "/", !cwd.isEmpty,
           Matching.canonicalPath(cwd) != Self.canonicalHome {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return processName
    }
}

/// A process we launched ourselves (leader of its own process group).
struct ManagedRun {
    let pid: pid_t
    let logURL: URL
    let startedAt: Date
}

enum ServerStatus: Equatable {
    case stopped
    case starting                  // we launched it, port not listening yet
    case running(external: Bool)   // external = someone else started it

    var isUp: Bool {
        if case .stopped = self { return false }
        return true
    }
}

/// Editable form state for the add/edit window.
struct ServerDraft: Identifiable, Equatable {
    let id = UUID()
    var serverID: UUID? = nil
    var name = ""
    var directory = ""
    var command = ""
    var portText = ""
    var urlOverride = ""
    var projectID: UUID? = nil
    /// Membership at draft creation — commit() only writes projectID when
    /// the picker actually changed, so stale drafts can't clobber it.
    var initialProjectID: UUID? = nil

    init() {}

    init(from server: Server) {
        serverID = server.id
        name = server.name
        directory = server.directory
        command = server.command
        portText = server.port.map(String.init) ?? ""
        urlOverride = server.urlOverride ?? ""
        projectID = server.projectID
        initialProjectID = server.projectID
    }
}

/// Compact memory readout for server rows: "512 MB", "1.2 GB", "14 GB".
enum MemoryDisplay {
    static let warnBytes: UInt64 = 2 << 30   // 2 GB — worth a glance
    static let alarmBytes: UInt64 = 6 << 30  // 6 GB — restart me

    static func format(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 10 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return "\(Int(mb.rounded())) MB"
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Replace the home directory prefix with "~" for display. Component
    /// boundary respected: a sibling like /Users/alice2 is NOT ~2.
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        if self == home { return "~" }
        if hasPrefix(home + "/") {
            return "~" + dropFirst(home.count)
        }
        return self
    }
}
