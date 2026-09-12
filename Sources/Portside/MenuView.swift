import AppKit
import ServiceManagement
import SwiftUI

/// Concentric with the panel: container radius minus the 6pt highlight
/// inset, per Apple's nested-corner guidance.
private let rowHighlightRadius = MenuGlassBackground.cornerRadius - 6

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @State private var listHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .padding(.horizontal, 12)
            serverList
            Divider()
                .padding(.horizontal, 12)
            footer
        }
        .frame(width: 340)
        .background(MenuGlassBackground())
        .clipShape(RoundedRectangle(cornerRadius: MenuGlassBackground.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MenuGlassBackground.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .onAppear { model.popoverDidOpen() }
        .onDisappear { model.popoverDidClose() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Portside")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if model.liveCount > 0 {
                Text("\(model.liveCount) running")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Menu {
                Button("Stop all servers") { model.stopAll() }
                    .disabled(model.liveCount == 0)
                Divider()
                LaunchAtLoginToggle()
                Button("Open logs folder") {
                    NSWorkspace.shared.open(model.store.logsDir)
                }
                Button("Copy diagnostics") { model.copyDiagnostics() }
                Divider()
                Button("Report an issue…") { model.reportIssue() }
                Button("Check for updates…") { Support.checkForUpdates() }
                Divider()
                Button("Quit Portside") { NSApp.terminate(nil) }
                Divider()
                Text("Portside \(AppVersion.current)")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 8)
    }

    private var serverList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if model.servers.isEmpty && model.ghostServers.isEmpty && model.projects.isEmpty {
                    EmptyHint(
                        text: "No active servers. Once a server is started, "
                            + "it will appear here automatically"
                    )
                }
                ForEach(model.projects) { project in
                    ProjectRow(project: project)
                    if !project.collapsed {
                        ForEach(model.members(of: project)) { server in
                            ServerRow(server: server)
                                .padding(.leading, 20)
                        }
                    }
                }
                ForEach(model.ungroupedServers) { server in
                    ServerRow(server: server)
                }
                ForEach(model.ghostServers) { server in
                    GhostRow(server: server)
                }
            }
            .padding(.vertical, 5)
            .animation(.easeOut(duration: 0.15), value: model.projects)
            .animation(.easeOut(duration: 0.15), value: model.servers.map(\.projectID))
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                }
            )
        }
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
        .frame(height: min(max(listHeight, 60), 440))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            AddServerRow {
                model.openEditor(ServerDraft())
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Rows

private struct ServerRow: View {
    @EnvironmentObject var model: AppModel
    let server: Server
    @State private var hovered = false

    private var status: ServerStatus { model.status(of: server) }

    var body: some View {
        HStack(spacing: 9) {
            StatusChip(
                status: status,
                help: status.isUp ? "Stop \(server.name)" : "Start \(server.name)"
            ) {
                if status.isUp {
                    model.stop(server)
                } else {
                    model.start(server)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(server.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let port = model.livePort(for: server) {
                        Text(":\(String(port))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if hovered, status.isUp,
                       let bytes = model.memory(for: server) {
                        MemoryBadge(bytes: bytes)
                    }
                }
            }
            overflowMenu
                .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: rowHighlightRadius, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onTapGesture {
            if status.isUp { model.open(server) }
        }
    }

    private var caption: String {
        if case .stopped = status, let code = model.lastExit[server.id], code != 0 {
            return "exited (\(code)) · \(server.command)"
        }
        return server.command
    }

    private var overflowMenu: some View {
        Menu {
            if model.url(for: server) != nil {
                Button("Open in browser") { model.open(server) }
            }
            Button("Edit…") { model.openEditor(ServerDraft(from: server)) }
            Button("View log") { model.openLog(server) }
            Button("Reveal in Finder") { model.revealInFinder(server) }
            if let url = model.url(for: server) {
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Divider()
            if model.projects.contains(where: { $0.id == server.projectID }) {
                Button("Remove from project") { model.assign(server, to: nil) }
            } else {
                // nil OR dangling id (project deleted / corrupt file): the
                // server must never be wedged out of both menu states.
                Menu("Add to project") {
                    ForEach(model.projects) { project in
                        Button(project.name) { model.assign(server, to: project) }
                    }
                    if !model.projects.isEmpty { Divider() }
                    Button("New project…") { model.promptNewProject(startingWith: server) }
                }
            }
            Divider()
            if status.isUp {
                Button("Stop server") { model.stop(server) }
            } else {
                Button("Start server") { model.start(server) }
            }
            Button("Remove", role: .destructive) { model.remove(server) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A stack occupying one row in the exact style of server rows. The chip
/// aggregates member status and converges toward running; clicking the row
/// unfurls the members inline.
private struct ProjectRow: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var hovered = false

    var body: some View {
        let aggregate = model.aggregate(of: project)
        let orchestrating = model.isOrchestrating(project.id)
        let allUp = isAllUp(aggregate)

        let isEmpty = aggregate == .empty

        HStack(spacing: 9) {
            StatusChip(
                status: chipStatus(aggregate, orchestrating: orchestrating),
                help: isEmpty ? "No servers in \(project.name) yet"
                    : allUp ? "Stop \(project.name)" : "Start \(project.name)",
                hoverShowsStop: allUp,
                actionable: !isEmpty
            ) {
                if allUp {
                    model.stopProject(project)
                } else if case .empty = aggregate {
                    // Nothing to start yet.
                } else {
                    model.startProject(project)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(project.collapsed ? 0 : 90))
                }
                HStack(spacing: 8) {
                    Text(caption(aggregate))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if hovered, projectMemory > 0 {
                        MemoryBadge(bytes: projectMemory)
                    }
                }
            }
            overflowMenu
                .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: rowHighlightRadius, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onTapGesture { model.toggleCollapsed(project) }
    }

    private func isAllUp(_ aggregate: ProjectAggregate) -> Bool {
        if case .allRunning = aggregate { return true }
        return false
    }

    private func chipStatus(
        _ aggregate: ProjectAggregate, orchestrating: Bool
    ) -> ServerStatus {
        switch aggregate {
        case .allRunning: return .running(external: false)
        case .partial: return .starting
        case .empty, .allStopped: return orchestrating ? .starting : .stopped
        }
    }

    /// Combined footprint of every running member's process tree.
    private var projectMemory: UInt64 {
        model.members(of: project)
            .compactMap { model.memory(for: $0) }
            .reduce(0, +)
    }

    private func caption(_ aggregate: ProjectAggregate) -> String {
        switch aggregate {
        case .empty:
            return "no servers yet — use a server's ⋯ menu"
        case .allStopped:
            let total = model.members(of: project).count
            return "\(total) server\(total == 1 ? "" : "s") · stopped"
        case .partial(let up, let total):
            return "\(total) servers · \(up) running"
        case .allRunning(let total):
            return "\(total) server\(total == 1 ? "" : "s") · running"
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("Start all servers") { model.startProject(project) }
            Button("Stop all servers") { model.stopProject(project) }
            Divider()
            Toggle("Start in order", isOn: Binding(
                get: { project.orderedStart },
                set: { _ in model.toggleOrderedStart(project) }
            ))
            Button("Rename…") { model.promptRename(project) }
            Divider()
            Button("Remove project", role: .destructive) {
                model.removeProject(project)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A running server with no restart recipe — visible while alive, gone when
/// stopped. Chip stops it; clicking the row opens it.
private struct GhostRow: View {
    @EnvironmentObject var model: AppModel
    let server: DetectedServer
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 9) {
            StatusChip(
                status: .running(external: true),
                help: "Stop \(server.displayName)"
            ) {
                model.stopDetected(server)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(server.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(":\(String(server.port))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(server.commandLine ?? "pid \(server.pid)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if hovered, let bytes = model.memoryByGroup[server.pgid] {
                        MemoryBadge(bytes: bytes)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: rowHighlightRadius, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onTapGesture { model.open(server) }
    }
}

// MARK: - Bits

/// Battery-style circular state chip: filled color when active, quiet gray
/// when not. Doubles as the start/stop control — hovering swaps the state
/// glyph for the action it will perform.
private struct StatusChip: View {
    let status: ServerStatus
    let help: String
    var hoverShowsStop: Bool? = nil // projects: mixed state hovers as "start"
    var actionable: Bool = true     // empty projects: chip is display-only
    let action: () -> Void
    @State private var hovered = false

    private var stopOnHover: Bool { hoverShowsStop ?? status.isUp }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fill)
                    .frame(width: 26, height: 26)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(glyphColor)
                    .opacity(hovered && actionable ? 0 : 1)
                Image(systemName: stopOnHover ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(glyphColor)
                    // Play triangles sit optically left of center.
                    .offset(x: stopOnHover ? 0 : 0.5)
                    .opacity(hovered && actionable ? 1 : 0)
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChipButtonStyle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .help(help)
    }

    private var fill: Color {
        switch status {
        case .running: return hovered && stopOnHover && actionable ? .orange : .green // hover = "will stop"
        case .starting: return .orange
        case .stopped: return Color.primary.opacity(0.09)
        }
    }

    private var glyphColor: Color {
        status.isUp ? .white : .secondary
    }
}

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// "Add server" in the same visual language as server rows: a quiet chip
/// with a plus glyph, one row, full-row click target.
private struct AddServerRow: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(hovered ? 0.13 : 0.09))
                        .frame(width: 26, height: 26)
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 32, height: 32)
                Text("Add server")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: rowHighlightRadius, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .padding(.horizontal, 6)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Quiet trailing memory readout: invisible below notice, amber past
/// 2 GB, red past 6 GB — a 14 GB dev server should be impossible to miss.
private struct MemoryBadge: View {
    let bytes: UInt64

    var body: some View {
        Text(MemoryDisplay.format(bytes))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .help("Memory used by this server's process tree")
    }

    private var color: AnyShapeStyle {
        if bytes >= MemoryDisplay.alarmBytes { return AnyShapeStyle(.red) }
        if bytes >= MemoryDisplay.warnBytes { return AnyShapeStyle(.orange) }
        return AnyShapeStyle(.secondary)
    }
}

private struct EmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 52)
            .padding(.vertical, 28)
    }
}

private struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status

    var body: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { status == .enabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    // Fails outside a .app bundle (swift run) — fall through
                    // and report whatever the real status is.
                }
                // Never assume the request took: registration can land in
                // .requiresApproval, where macOS waits for the user in
                // System Settings and the toggle would otherwise lie.
                status = SMAppService.mainApp.status
            }
        ))
        if status == .requiresApproval {
            Button("Approve in Login Items…") {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
