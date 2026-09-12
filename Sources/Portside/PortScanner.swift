import Darwin
import Foundation

/// Discovers listening TCP servers. One lsof spawn per scan; everything else
/// (cwd, argv, pgid) comes from cached syscalls. Owned by AppModel; scan() is
/// only ever called from one in-flight task at a time.
final class PortScanner {

    /// Per-pid metadata resolved once and reused until the pid disappears.
    struct PidMeta: Equatable {
        var processName: String
        var cwd: String?
        var displayCommand: String?
        /// argv[0] — what the process actually runs, which is how an app's
        /// internal helper is told apart from a dev server. Its cwd can't do
        /// that job: Warp's agent reports $HOME, and an Xcode test bundle
        /// reports whichever repo the tests were launched from.
        var executable: String?
        var pgid: pid_t
        var adoption: AdoptionRecipe?
    }

    /// User-session daemons and app helpers that listen on ports but aren't dev servers.
    static let denylist = [
        "rapportd", "sharingd", "ControlCe", "ControlCenter", "AirPlay",
        "identityservicesd", "assistantd", "Spotify", "Dropbox", "OneDrive",
        "CoreSync", "Creative Cloud", "Adobe", "Figma", "figma_agent",
        "Raycast", "Cursor Helper", "Code Helper", "JetBrains", "xctest",
    ]

    /// App bundles whose helper processes hold ports for the app's own use
    /// (Warp's agent, Slack's IPC). Matched against the executable path,
    /// lower-cased, because these helpers have unhelpful process names
    /// ("stable"). Kept deliberately short: an app that serves ports ON
    /// PURPOSE — Docker Desktop, OrbStack, Postgres.app — must never be here.
    static let helperBundles = [
        "/warp.app/", "/slack.app/", "/discord.app/", "/zoom.us.app/",
        "/microsoft teams", "/notion.app/", "/1password",
    ]

    /// Ports in the OS ephemeral range are never dev servers. Read from sysctl
    /// so custom portrange configs are respected; defaults to 49152.
    static let ephemeralFloor: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("net.inet.ip.portrange.first", &value, &size, nil, 0) == 0,
           value > 1024 {
            return Int(value)
        }
        return 49152
    }()

    private var metaCache: [pid_t: PidMeta] = [:]
    private let scanLock = NSLock()

    /// Admission policy, extracted for tests. A run Portside started bypasses
    /// everything (it's our own child). Everything else: the denylist is
    /// UNCONDITIONAL — a saved server's port must never re-admit a system
    /// process squatting it (ControlCenter listens on 5000/7000 for AirPlay);
    /// exempt ports bypass only the ephemeral floor.
    static func shouldInclude(
        port: Int, processName: String, pgid: pid_t,
        cwd: String? = nil, executable: String? = nil,
        exemptPorts: Set<Int> = [], exemptDirectories: Set<String> = [],
        managedPgids: Set<pid_t> = []
    ) -> Bool {
        // Our own child: admitted whatever it looks like.
        if managedPgids.contains(pgid) { return true }
        if deniedByName(processName) { return false }
        if isAppInternal(executable: executable) { return false }
        if port < ephemeralFloor || exemptPorts.contains(port) { return true }
        // An odd-numbered port is still this server if it is working out of a
        // saved server's directory — a dev server handed an OS-assigned port
        // lands in the ephemeral range and would otherwise be invisible.
        if let cwd, exemptDirectories.contains(Matching.canonicalPath(cwd)) {
            return true
        }
        return false
    }

    static func deniedByName(_ processName: String) -> Bool {
        denylist.contains(where: { processName.hasPrefix($0) })
    }

    /// Listeners that are some app's own plumbing rather than a server the
    /// user runs: test bundles, Apple's session daemons, and a short list of
    /// known helper bundles. Deliberately NOT a generic "anything under a
    /// .app or /Library" rule — that hides real servers:
    ///
    /// - Every framework-build Python (Apple's /usr/bin/python3, Homebrew's
    ///   python@3.x, python.org) rewrites argv[0] to
    ///   `…/Python.app/Contents/MacOS/Python`, so a `.app/` test hides every
    ///   Django / Flask / uvicorn dev server on the machine.
    /// - .pkg JDKs live in /Library/Java/…; IntelliJ, Gradle and Maven exec
    ///   `java` by that absolute path, so a `/Library/` test hides Spring apps.
    /// - Docker Desktop, OrbStack and Postgres.app are .app bundles whose
    ///   whole point is the ports they hold.
    ///
    /// Anything Portside launched bypasses this check before it is reached.
    static func isAppInternal(executable: String?) -> Bool {
        guard let executable, executable.hasPrefix("/") else { return false }
        let path = executable.lowercased()
        if path.contains(".xctest/") { return true }
        if path.hasPrefix("/system/") || path.hasPrefix("/usr/libexec/") { return true }
        return helperBundles.contains(where: { path.contains($0) })
    }

    /// Returns nil when a previous scan is still running (wedged on a dead
    /// mount, say) — callers skip the tick instead of racing the cache.
    func scan(
        exemptPorts: Set<Int> = [],
        exemptDirectories: Set<String> = [],
        managedPgids: Set<pid_t> = []
    ) -> [DetectedServer]? {
        guard scanLock.try() else { return nil }
        defer { scanLock.unlock() }

        // A failed or timed-out lsof is "unknown", not "nothing is listening":
        // reporting it as zero listeners would flip every row to stopped and
        // evict the metadata cache. Skip the tick instead; the next one retries.
        guard let data = shellData("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn0"])
        else { return nil }
        let listeners = Self.parseListeners(data)

        // Evict metadata for pids that are no longer listening.
        let livePids = Set(listeners.map(\.pid))
        metaCache = metaCache.filter { livePids.contains($0.key) }

        var seen = Set<String>()
        var result: [DetectedServer] = []
        for listener in listeners {
            guard seen.insert("\(listener.pid):\(listener.port)").inserted
            else { continue }

            // Metadata before admission: the policy needs argv[0] and the
            // working directory. Cached per pid, so the syscalls happen once
            // per process, not once per scan.
            let meta: PidMeta
            if let cached = metaCache[listener.pid] {
                meta = cached
            } else {
                meta = Self.fetchMeta(pid: listener.pid, fallbackName: listener.name)
                metaCache[listener.pid] = meta
            }

            guard Self.shouldInclude(
                port: listener.port, processName: meta.processName,
                pgid: meta.pgid, cwd: meta.cwd, executable: meta.executable,
                exemptPorts: exemptPorts, exemptDirectories: exemptDirectories,
                managedPgids: managedPgids
            ) else { continue }

            result.append(DetectedServer(
                pid: listener.pid,
                port: listener.port,
                pgid: meta.pgid,
                processName: meta.processName,
                commandLine: meta.displayCommand,
                cwd: meta.cwd,
                adoption: meta.adoption
            ))
        }
        return result.sorted { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
    }

    /// One-shot check used before SIGKILL escalation: which of these pids are
    /// still listening? Stateless — safe to call from any queue.
    static func listeningPids(among pids: [pid_t]) -> Set<pid_t> {
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        // nil = lsof unavailable: report no survivors, so the SIGKILL
        // escalation that depends on this stands down rather than firing blind.
        guard let data = shellData(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", list, "-Fp0"]
        ) else { return [] }
        return Set(parseListeners(data).map(\.pid)).union(
            Set(parsePidsOnly(data))
        )
    }

    // MARK: - Parsing (pure, testable)

    /// Parses `lsof -F…0` output: NUL-terminated fields, with a newline set
    /// separator following the NUL. NUL termination means file paths or names
    /// containing newlines cannot forge extra fields.
    static func parseListeners(_ data: Data) -> [(pid: pid_t, name: String, port: Int)] {
        var result: [(pid: pid_t, name: String, port: Int)] = []
        var pid: pid_t = 0
        var name = ""

        for chunk in data.split(separator: 0) {
            var field = chunk
            while field.first == 0x0A { field = field.dropFirst() }
            guard let tag = field.first else { continue }
            let rest = String(decoding: field.dropFirst(), as: UTF8.self)
            switch tag {
            case UInt8(ascii: "p"):
                pid = pid_t(rest) ?? 0
                name = ""
            case UInt8(ascii: "c"):
                name = rest
            case UInt8(ascii: "n"):
                guard pid > 0,
                      let colon = rest.lastIndex(of: ":"),
                      let port = Int(rest[rest.index(after: colon)...]),
                      (1...65535).contains(port)
                else { continue }
                result.append((pid, name, port))
            default:
                break
            }
        }
        return result
    }

    static func parsePidsOnly(_ data: Data) -> [pid_t] {
        var pids: [pid_t] = []
        for chunk in data.split(separator: 0) {
            var field = chunk
            while field.first == 0x0A { field = field.dropFirst() }
            guard field.first == UInt8(ascii: "p") else { continue }
            if let pid = pid_t(String(decoding: field.dropFirst(), as: UTF8.self)), pid > 0 {
                pids.append(pid)
            }
        }
        return pids
    }

    // MARK: - Metadata

    static func fetchMeta(pid: pid_t, fallbackName: String) -> PidMeta {
        let argv = ProcInfo.arguments(of: pid)
        let cwd = ProcInfo.workingDirectory(of: pid)
        let pgid = ProcInfo.processGroup(of: pid)

        var name = fallbackName
        if name.isEmpty, let first = argv?.first {
            name = URL(fileURLWithPath: first).lastPathComponent
        }

        return PidMeta(
            processName: name,
            cwd: cwd,
            displayCommand: argv?.joined(separator: " "),
            executable: argv?.first,
            pgid: pgid,
            adoption: adoptionRecipe(cwd: cwd, argv: argv)
        )
    }

    /// Builds the persisted restart recipe. package.json / project-file guess
    /// first (trusted: it's the user's own repo); otherwise the process's
    /// argv, shell-quoted so argv contents can never be reinterpreted as
    /// shell syntax — and only if argv[0] actually resolves to an executable,
    /// which rejects proctitle-rewritten garbage (puma, pm2, process.title).
    static func adoptionRecipe(cwd: String?, argv: [String]?) -> AdoptionRecipe? {
        guard let cwd, Matching.isAdoptableDirectory(cwd) else { return nil }
        let command: String
        if let guessed = CommandGuess.guess(directory: cwd) {
            command = guessed
        } else if let argv, let first = argv.first,
                  resolvesExecutable(first, cwd: cwd) {
            command = ShellQuoting.join(argv)
        } else {
            return nil
        }
        return AdoptionRecipe(
            name: URL(fileURLWithPath: cwd).lastPathComponent,
            directory: cwd.abbreviatingHome,
            command: command
        )
    }

    /// Can this argv[0] be launched again from `cwd`? Absolute paths must
    /// exist; relative paths resolve against cwd; bare names against the
    /// standard + version-manager bin directories.
    static func resolvesExecutable(_ candidate: String, cwd: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        let fm = FileManager.default
        if candidate.hasPrefix("/") {
            return fm.isExecutableFile(atPath: candidate)
        }
        if candidate.contains("/") {
            return fm.isExecutableFile(atPath: cwd + "/" + candidate)
        }
        let home = NSHomeDirectory()
        var searchDirs = [
            "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin",
            "/usr/sbin", "/sbin",
            home + "/.volta/bin", home + "/.bun/bin", home + "/.deno/bin",
            home + "/.cargo/bin", home + "/.local/bin",
        ]
        if let nvmBin = Launcher.latestNvmBin(home: home) {
            searchDirs.append(nvmBin)
        }
        return searchDirs.contains { fm.isExecutableFile(atPath: $0 + "/" + candidate) }
    }
}
