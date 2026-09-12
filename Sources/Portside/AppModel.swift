import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var servers: [Server] = []
    @Published var projects: [Project] = []
    @Published var allServers: [DetectedServer] = []
    @Published var runs: [UUID: ManagedRun] = [:]
    @Published var lastExit: [UUID: Int32] = [:]
    @Published var memoryByGroup: [pid_t: UInt64] = [:]
    /// Runs the user asked to stop. Their death by SIGTERM/SIGKILL is the
    /// requested outcome, so reapRuns must not record it as "exited (143)".
    private var stoppingRuns: Set<UUID> = []
    @Published var editorDraft: ServerDraft?
    @Published var lastError: String?

    let store = ServerStore()
    private let scanner = PortScanner()
    private var timer: AnyCancellable?
    private var scanInFlight = false
    private var tick = 0
    private var popoverOpen = false
    /// Pids whose servers were just removed; blocks re-adoption until the
    /// process actually dies (pruned when the pid stops listening).
    private var suppressedPids: Set<pid_t> = []
    /// Removed recipes — never auto-adopted again (supervised servers respawn
    /// with new pids, so pid suppression alone can't make Remove stick).
    private var tombstones: [ServerStore.Tombstone] = []
    /// Canonical-path memo; bounded, cleared if it ever grows past 512 entries.
    private var canonicalCache: [String: String] = [:]
    /// User's login-shell environment, captured once at startup off-main.
    private var capturedEnvironment: [String: String]?
    /// Watchdog anchor: a scan wedged on a dead mount must not freeze
    /// scanning forever.
    private var scanStartedAt = Date.distantPast
    private var lastSoonBurst = Date.distantPast

    /// In-flight ordered-start sequencers, cancellable by stopProject.
    private var projectOrchestrations: [UUID: Task<Void, Never>] = [:]
    /// Observable orchestration state — separate from the task dict so
    /// SwiftUI updates when a sequence starts AND when it ends.
    @Published private(set) var orchestratingProjects: Set<UUID> = []

    init() {
        servers = store.load()
        projects = store.loadProjects()
        tombstones = store.loadTombstones()
        timer = Timer.publish(every: 4, tolerance: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.timerTick() }
        Task.detached(priority: .utility) {
            let environment = EnvResolver.capture()
            await MainActor.run { self.capturedEnvironment = environment }
        }
        refresh()
    }

    // MARK: - Derived state

    /// Servers with no recipe to restart from — visible while running, gone
    /// when they stop. Everything else becomes a saved entry automatically.
    var ghostServers: [DetectedServer] {
        allServers.filter { server in
            claimant(of: server) == nil &&
            !allServers.contains { $0.pid == server.pid && claimant(of: $0) != nil }
        }
    }

    var liveCount: Int {
        ghostServers.count + servers.filter { status(of: $0).isUp }.count
    }

    func claimant(of detected: DetectedServer) -> Server? {
        guard let id = Matching.claimant(
            of: detected, saved: servers,
            managedPgids: managedPgids, canonical: canonical(_:)
        ) else { return nil }
        return servers.first { $0.id == id }
    }

    private var managedPgids: [pid_t: UUID] {
        var map: [pid_t: UUID] = [:]
        for (id, run) in runs { map[run.pid] = id }
        return map
    }

    /// All detected listeners this saved server actually owns (by pgid for
    /// runs we started, by corroborated port or directory otherwise). Every
    /// status/kill decision goes through this — Portside never signals a
    /// process it can't attribute to the row the user clicked.
    func claimedListeners(for server: Server) -> [DetectedServer] {
        allServers.filter { claimant(of: $0)?.id == server.id }
    }

    func status(of server: Server) -> ServerStatus {
        let claimed = claimedListeners(for: server)
        if let run = runs[server.id] {
            if claimed.contains(where: { $0.pgid == run.pid }) {
                return .running(external: false)
            }
            if kill(run.pid, 0) == 0 {
                guard server.port != nil else { return .running(external: false) }
                return claimed.isEmpty ? .starting : .running(external: false)
            }
        }
        return claimed.isEmpty ? .stopped : .running(external: true)
    }

    /// The port to display and open: the actual port of a run we started,
    /// else the configured port, else an owned listener's port.
    /// Resident memory of the server's process tree, when it's up.
    func memory(for server: Server) -> UInt64? {
        if let run = runs[server.id], let bytes = memoryByGroup[run.pid] {
            return bytes
        }
        if let pgid = claimedListeners(for: server).first?.pgid {
            return memoryByGroup[pgid]
        }
        return nil
    }

    func livePort(for server: Server) -> Int? {
        let claimed = claimedListeners(for: server)
        if let run = runs[server.id],
           let matched = claimed.first(where: { $0.pgid == run.pid }) {
            return matched.port
        }
        if let port = server.port { return port }
        return claimed.map(\.port).min()
    }

    func url(for server: Server) -> URL? {
        // Only web schemes: the globe must never launch an arbitrary handler,
        // and an unusable override falls back to the port URL rather than
        // leaving a button that silently does nothing.
        if let override = server.urlOverride, let url = URL(string: override),
           ["http", "https"].contains(url.scheme?.lowercased()) {
            return url
        }
        if let port = livePort(for: server) {
            return URL(string: "http://localhost:\(port)")
        }
        return nil
    }

    private func canonical(_ path: String) -> String {
        if let cached = canonicalCache[path] { return cached }
        if canonicalCache.count > 512 { canonicalCache.removeAll(keepingCapacity: true) }
        let result = Matching.canonicalPath(path)
        canonicalCache[path] = result
        return result
    }

    // MARK: - Scanning

    private func timerTick() {
        tick += 1
        // Watchdog: a scan thread wedged on a dead mount must not block
        // scanning forever (the stuck thread is leaked, the app stays alive).
        if scanInFlight, Date().timeIntervalSince(scanStartedAt) > 30 {
            scanInFlight = false
        }
        // Half cadence while the popover is closed; full while it's open.
        if popoverOpen || tick % 2 == 0 { refresh() }
    }

    func popoverDidOpen() {
        popoverOpen = true
        refresh()
    }

    func popoverDidClose() {
        popoverOpen = false
    }

    func refresh() {
        guard !scanInFlight else { return }
        scanInFlight = true
        scanStartedAt = Date()
        let scanner = self.scanner
        let exemptPorts = Set(servers.compactMap(\.port))
        let exemptDirs = Set(servers.map { canonical($0.directory) })
        let managedPgids = Set(runs.values.map(\.pid))
        Task.detached(priority: .utility) {
            let detected = scanner.scan(
                exemptPorts: exemptPorts,
                exemptDirectories: exemptDirs,
                managedPgids: managedPgids
            )
            // Piggyback memory sampling on the scan, off the main thread:
            // one group walk per visible server tree, every scan cycle.
            var memory: [pid_t: UInt64] = [:]
            for pgid in Set((detected ?? []).map(\.pgid)).union(managedPgids) {
                memory[pgid] = ProcInfo.groupResidentBytes(pgid: pgid)
            }
            let sampled = memory
            await MainActor.run {
                if let detected {
                    self.memoryByGroup = sampled
                    self.apply(detected)
                } else {
                    // A previous (wedged) scan still holds the scanner — skip.
                    self.scanInFlight = false
                }
            }
        }
    }

    /// Extra refreshes shortly after a start/stop so the UI feels immediate.
    /// Coalesced: rapid clicks share one burst instead of stacking timers.
    func refreshSoon() {
        guard Date().timeIntervalSince(lastSoonBurst) > 1 else { return }
        lastSoonBurst = Date()
        for delay in [0.5, 2.0, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    private func apply(_ detected: [DetectedServer]) {
        scanInFlight = false
        reapRuns()
        if allServers != detected {
            allServers = detected
        }
        // Suppression lives exactly as long as the removed process listens.
        suppressedPids.formIntersection(detected.map(\.pid))
        autoAdopt(from: detected)
    }

    /// Collect exit codes of finished managed runs (also prevents zombies).
    private func reapRuns() {
        for (id, run) in runs {
            var status: Int32 = 0
            let result = waitpid(run.pid, &status, WNOHANG)
            if result == run.pid {
                runs[id] = nil
                lastExit[id] = stoppingRuns.remove(id) == nil
                    ? Self.decodeExitStatus(status) : nil
            } else if result == -1 && errno == ECHILD {
                runs[id] = nil
                stoppingRuns.remove(id)
            }
        }
    }

    /// wait(2) semantics: exit code for normal exits, 128+signal for deaths.
    nonisolated static func decodeExitStatus(_ status: Int32) -> Int32 {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    /// Every newly detected server with a pre-built recipe becomes a saved
    /// entry. Recipes were computed off-main during the scan; the selection
    /// logic itself is pure (Matching.adoptionSelections) and unit-tested.
    private func autoAdopt(from detected: [DetectedServer]) {
        let selections = Matching.adoptionSelections(
            detected: detected,
            isClaimed: { self.claimant(of: $0) != nil },
            suppressedPids: suppressedPids,
            isTombstoned: { self.isTombstoned($0) },
            isDuplicate: { recipe in
                self.servers.contains {
                    self.canonical($0.directory) == self.canonical(recipe.directory)
                        && $0.command == recipe.command
                }
            }
        )
        guard !selections.isEmpty else { return }
        for selection in selections {
            servers.append(Server(
                name: selection.recipe.name,
                directory: selection.recipe.directory,
                command: selection.recipe.command,
                port: selection.port,
                urlOverride: nil
            ))
        }
        store.save(servers)
    }

    // MARK: - Start / stop

    func start(_ server: Server) {
        lastError = nil
        reapRuns() // clear zombies so a quick stop→start isn't dropped
        guard !status(of: server).isUp else { return }
        let directory = server.expandedDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            lastError = "\(server.name): directory not found"
            return
        }
        do {
            let logURL = store.logURL(for: server)
            let environment = capturedEnvironment ?? ProcessInfo.processInfo.environment
            let pid = try Launcher.spawnShell(
                command: server.command,
                directory: directory,
                logURL: logURL,
                environment: environment
            )
            runs[server.id] = ManagedRun(pid: pid, logURL: logURL, startedAt: Date())
            lastExit[server.id] = nil
        } catch {
            lastError = "\(server.name): \(error.localizedDescription)"
        }
        refreshSoon()
    }

    func stop(_ server: Server) {
        lastError = nil
        reapRuns()
        if let run = runs[server.id],
           kill(run.pid, 0) == 0 || allServers.contains(where: { $0.pgid == run.pid }) {
            stoppingRuns.insert(server.id)
            Launcher.terminateGroup(run.pid)
            escalateGroup(run.pid)
        } else if status(of: server).isUp {
            stopExternal(pids: claimedListeners(for: server).map(\.pid))
        }
        refreshSoon()
    }

    func stopDetected(_ server: DetectedServer) {
        lastError = nil
        stopExternal(pids: [server.pid])
        refreshSoon()
    }

    func stopAll() {
        servers.filter { status(of: $0).isUp }.forEach(stop)
        stopExternal(pids: ghostServers.map(\.pid))
    }

    /// Stopping a process Portside did not start: re-verify each pid still
    /// holds a listening socket at signal time (a scan snapshot is up to 8s
    /// stale — the pid could have died and been reused), SIGTERM, then give
    /// a longer 10s grace before a verified SIGKILL. External processes may
    /// be databases mid-checkpoint; they get more patience than our own runs.
    private func stopExternal(pids: [pid_t]) {
        guard !pids.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let verified = PortScanner.listeningPids(among: pids)
            await MainActor.run {
                verified.forEach { kill($0, SIGTERM) }
                self.escalatePids(Array(verified), after: 10)
            }
        }
    }

    /// SIGKILL a process group we own if any member survives SIGTERM by 3s.
    /// pgid reuse would require the entire group to die AND the leader pid to
    /// be handed to a brand-new group leader within 3s — not realistic with
    /// macOS's ascending pid allocation.
    private func escalateGroup(_ pgid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if kill(-pgid, 0) == 0 {
                kill(-pgid, SIGKILL)
            }
            self?.refresh()
        }
    }

    /// SIGKILL external pids only after re-verifying they still hold a
    /// listening socket — guards against pid reuse during the grace window.
    private func escalatePids(_ pids: [pid_t], after grace: TimeInterval) {
        guard !pids.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            Task.detached(priority: .utility) {
                let survivors = PortScanner.listeningPids(among: pids)
                await MainActor.run {
                    for pid in survivors { kill(pid, SIGKILL) }
                    self?.refresh()
                }
            }
        }
    }

    // MARK: - Projects

    func members(of project: Project) -> [Server] {
        servers.filter { $0.projectID == project.id }
    }

    /// Servers with no project, or whose project no longer exists (tolerant
    /// of dangling ids — they render as ordinary rows).
    var ungroupedServers: [Server] {
        servers.filter { server in
            guard let projectID = server.projectID else { return true }
            return !projects.contains { $0.id == projectID }
        }
    }

    func aggregate(of project: Project) -> ProjectAggregate {
        ProjectAggregate.compute(members(of: project).map { status(of: $0) })
    }

    func isOrchestrating(_ projectID: UUID) -> Bool {
        orchestratingProjects.contains(projectID)
    }

    /// Converge toward running: starts every member that isn't up. Ordered
    /// mode sequences members, gating each on TCP readiness of the previous.
    func startProject(_ project: Project) {
        cancelOrchestration(project.id)
        let pending = members(of: project).filter { !status(of: $0).isUp }
        guard !pending.isEmpty else { return }

        guard project.orderedStart else {
            pending.forEach(start)
            return
        }
        let projectID = project.id
        let pendingIDs = pending.map(\.id)
        orchestratingProjects.insert(projectID)
        projectOrchestrations[projectID] = Task { @MainActor [weak self] in
            defer {
                // A cancelled task's bookkeeping was already removed — and
                // possibly REPLACED by a newer sequence — in
                // cancelOrchestration. A stale defer must never clear the
                // replacement's entry, or the new sequence becomes
                // uncancellable and members launch after Stop.
                if !Task.isCancelled {
                    self?.projectOrchestrations[projectID] = nil
                    self?.orchestratingProjects.remove(projectID)
                }
            }
            for id in pendingIDs {
                guard let self, !Task.isCancelled else { return }
                // Re-resolve every iteration — membership and config may
                // have changed since the sequence began.
                guard let current = self.servers.first(where: { $0.id == id }),
                      current.projectID == projectID,
                      !self.status(of: current).isUp
                else { continue }
                self.start(current)
                // A failed spawn must not burn the 30s readiness timeout.
                guard self.runs[current.id] != nil else { continue }
                if let port = current.port {
                    _ = await PortReadiness.waitUntilAccepting(port: port, timeout: 30)
                } else {
                    // No port to probe — fixed grace before the next member.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
    }

    /// Reverse order, after cancelling any in-flight sequencer — otherwise
    /// stop races the orchestration, which keeps launching members.
    func stopProject(_ project: Project) {
        cancelOrchestration(project.id)
        for server in members(of: project).reversed() where status(of: server).isUp {
            stop(server)
        }
    }

    private func cancelOrchestration(_ projectID: UUID) {
        projectOrchestrations[projectID]?.cancel()
        projectOrchestrations[projectID] = nil
        orchestratingProjects.remove(projectID)
    }

    func assign(_ server: Server, to project: Project?) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index].projectID = project?.id
        store.save(servers)
    }

    func toggleCollapsed(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].collapsed.toggle()
        store.saveProjects(projects)
    }

    func toggleOrderedStart(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].orderedStart.toggle()
        store.saveProjects(projects)
    }

    /// Removing a project only ungroups — member servers are untouched.
    func removeProject(_ project: Project) {
        cancelOrchestration(project.id)
        for index in servers.indices where servers[index].projectID == project.id {
            servers[index].projectID = nil
        }
        projects.removeAll { $0.id == project.id }
        store.save(servers)
        store.saveProjects(projects)
    }

    @discardableResult
    func createProject(named name: String) -> Project {
        let project = Project(name: name)
        projects.append(project)
        store.saveProjects(projects)
        return project
    }

    func promptNewProject(startingWith server: Server?) {
        MenuGlassBackground.currentPanel?.close()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "New project"
        alert.informativeText = "Group servers to start and stop them together."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "my-stack"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmed
        guard !name.isEmpty else { return }
        let project = createProject(named: name)
        if let server { assign(server, to: project) }
    }

    func promptRename(_ project: Project) {
        MenuGlassBackground.currentPanel?.close()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename project"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = project.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmed
        guard !name.isEmpty,
              let index = projects.firstIndex(where: { $0.id == project.id })
        else { return }
        projects[index].name = name
        store.saveProjects(projects)
    }

    var environmentCaptureSummary: String {
        capturedEnvironment == nil
            ? "fallback (process env)"
            : "login shell (\(URL(fileURLWithPath: EnvResolver.loginShell()).lastPathComponent))"
    }

    func reportIssue() {
        Support.reportIssue(diagnostics: Diagnostics.report(model: self))
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.report(model: self), forType: .string)
    }

    // MARK: - Open

    func open(_ server: Server) {
        guard let url = url(for: server),
              ["http", "https"].contains(url.scheme?.lowercased())
        else { return }
        NSWorkspace.shared.open(url)
    }

    func open(_ server: DetectedServer) {
        if let url = URL(string: "http://localhost:\(server.port)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLog(_ server: Server) {
        let url = runs[server.id]?.logURL ?? store.logURL(for: server)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ server: Server) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: server.expandedDirectory)]
        )
    }

    // MARK: - Editing

    func openEditor(_ draft: ServerDraft) {
        var draft = draft
        if let projectID = draft.projectID,
           !projects.contains(where: { $0.id == projectID }) {
            draft.projectID = nil
        }
        editorDraft = draft
        EditorPresenter.present(model: self)
    }

    /// Returns an error message, or nil on success.
    func commit(_ draft: ServerDraft) -> String? {
        let directory = draft.directory.trimmed
        let expanded = (directory as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !directory.isEmpty,
              FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return "Directory doesn't exist." }

        let command = draft.command.trimmed
        guard !command.isEmpty else { return "Command is required." }

        var port: Int? = nil
        let portText = draft.portText.trimmed
        if !portText.isEmpty {
            guard let parsed = Int(portText), (1...65535).contains(parsed) else {
                return "Port must be a number between 1 and 65535."
            }
            port = parsed
        }

        let name = draft.name.trimmed.isEmpty
            ? URL(fileURLWithPath: expanded).lastPathComponent
            : draft.name.trimmed
        let urlOverride = draft.urlOverride.trimmed.isEmpty ? nil : draft.urlOverride.trimmed

        // Manually adding a recipe back is the explicit undo of Remove.
        let canonicalDirectory = canonical(directory)
        let hadTombstone = tombstones.contains {
            canonical($0.directory) == canonicalDirectory && $0.command == command
        }
        if hadTombstone {
            tombstones.removeAll {
                canonical($0.directory) == canonicalDirectory && $0.command == command
            }
            store.saveTombstones(tombstones)
        }

        if let serverID = draft.serverID,
           let index = servers.firstIndex(where: { $0.id == serverID }) {
            servers[index].name = name
            servers[index].directory = directory
            servers[index].command = command
            servers[index].port = port
            servers[index].urlOverride = urlOverride
            // Only write membership if the user actually touched the picker —
            // a stale draft must not clobber changes made via the row menus.
            if draft.projectID != draft.initialProjectID {
                servers[index].projectID = draft.projectID
            }
        } else {
            servers.append(Server(
                name: name, directory: directory, command: command,
                port: port, urlOverride: urlOverride, projectID: draft.projectID
            ))
        }
        store.save(servers)
        editorDraft = nil
        return nil
    }

    /// Stop (if running) and forget — permanently. A tombstone keeps
    /// auto-adoption from resurrecting the recipe (supervisors respawn with
    /// new pids), and pid suppression covers the shutdown grace period.
    func remove(_ server: Server) {
        var pids = claimedListeners(for: server).map(\.pid)
        if let run = runs[server.id] {
            pids.append(run.pid)
            pids += allServers.filter { $0.pgid == run.pid }.map(\.pid)
        }
        suppressedPids.formUnion(pids)

        tombstones.append(ServerStore.Tombstone(
            directory: server.directory, command: server.command
        ))
        // If the user edited the command, adoption would regenerate the row
        // with the *guessed* command — tombstone that identity too.
        if let guessed = CommandGuess.guess(directory: server.expandedDirectory),
           guessed != server.command {
            tombstones.append(ServerStore.Tombstone(
                directory: server.directory, command: guessed
            ))
        }
        store.saveTombstones(tombstones)

        if status(of: server).isUp {
            stop(server)
        }
        servers.removeAll { $0.id == server.id }
        lastExit[server.id] = nil
        store.save(servers)

        // Logs are Portside's own files about this entry; clean them up so
        // the logs directory can't grow without bound.
        try? FileManager.default.removeItem(at: store.logURL(for: server))
        try? FileManager.default.removeItem(at: store.oldLogURL(for: server))
    }

    private func isTombstoned(_ recipe: AdoptionRecipe) -> Bool {
        let directory = canonical(recipe.directory)
        return tombstones.contains {
            canonical($0.directory) == directory && $0.command == recipe.command
        }
    }
}
