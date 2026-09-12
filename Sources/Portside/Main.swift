import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // Headless one-shot scan, handy for debugging: swift run Portside --scan
        if CommandLine.arguments.contains("--scan") {
            // Same exemptions the app applies, so the table shows what the
            // popover would show — including saved servers on odd ports.
            let saved = ServerStore().load()
            let scan = PortScanner().scan(
                exemptPorts: Set(saved.compactMap(\.port)),
                exemptDirectories: Set(saved.map { Matching.canonicalPath($0.directory) })
            )
            for server in scan ?? [] {
                let cwd = server.cwd.map { $0.abbreviatingHome } ?? "-"
                print("\(server.port)\t\(server.processName)\tpid \(server.pid)\t\(cwd)")
            }
            return
        }
        // flock-based: covers `swift run` and renamed bundles too.
        guard SingleInstance.acquire() else { return }
        PortsideApp.main()
    }
}

struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "server.rack")
            if model.liveCount > 0 {
                Text(String(model.liveCount))
                    .font(.system(size: 11, weight: .medium))
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run as a bare binary (swift run).
        NSApp.setActivationPolicy(.accessory)

        // Single instance: two copies would double-scan and double-adopt.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0 != .current && !$0.isTerminated }
            if !others.isEmpty {
                NSApp.terminate(nil)
            }
        }
    }
}
