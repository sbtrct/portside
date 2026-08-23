import AppKit
import Foundation

/// Links out to the project's public pages.
///
/// Portside makes no network calls of its own — these hand a URL to the
/// user's browser, which is the only thing that talks to the network, and
/// only when the user picks the menu item.
enum Support {
    static let repository = URL(string: "https://github.com/sbtrct/portside")!
    static let releases = repository.appendingPathComponent("releases/latest")

    /// Opens a pre-structured issue and puts the diagnostics on the clipboard
    /// so the user can paste them into the fenced block — rather than
    /// smuggling machine details into a public URL they never got to read.
    static func reportIssue(diagnostics: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)

        let body = """
        **What happened?**


        **What did you expect instead?**


        **Steps to reproduce**
        1.

        ---
        <details><summary>Diagnostics</summary>

        ```
        (paste here — Portside copied these to your clipboard: version,
        macOS, hardware, server counts, listening ports. No paths to your
        projects, no environment variable values.)
        ```
        </details>
        """

        var components = URLComponents(
            url: repository.appendingPathComponent("issues/new"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "body", value: body)]

        // Fall back to the plain issues page if the template ever fails to
        // encode — a broken URL should not swallow a bug report.
        NSWorkspace.shared.open(
            components?.url ?? repository.appendingPathComponent("issues")
        )
    }

    static func checkForUpdates() {
        NSWorkspace.shared.open(releases)
    }
}
