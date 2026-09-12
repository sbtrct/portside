import XCTest
@testable import Portside

final class ScannerParsingTests: XCTestCase {

    /// Builds lsof -F…0 style output: NUL after each field, NL set separators.
    private func lsofData(_ fields: [String]) -> Data {
        var data = Data()
        for field in fields {
            if field == "\n" {
                data.append(0x0A)
            } else {
                data.append(Data(field.utf8))
                data.append(0)
            }
        }
        return data
    }

    func testParsesRealWorldFormat() {
        // Mirrors observed output: p, c, then f/n pairs, NL between sets.
        let data = lsofData([
            "p943", "crapportd", "\n", "f12", "n*:61023", "\n",
            "p1518", "cnode", "\n", "f22", "n127.0.0.1:3000", "\n",
        ])
        let listeners = PortScanner.parseListeners(data)
        XCTAssertEqual(listeners.count, 2)
        XCTAssertEqual(listeners[0].pid, 943)
        XCTAssertEqual(listeners[0].name, "rapportd")
        XCTAssertEqual(listeners[0].port, 61023)
        XCTAssertEqual(listeners[1].pid, 1518)
        XCTAssertEqual(listeners[1].name, "node")
        XCTAssertEqual(listeners[1].port, 3000)
    }

    /// A process name containing newlines and lsof-like syntax must stay DATA —
    /// NUL termination means it can't forge extra records.
    func testEmbeddedNewlineInFieldCannotForgeRecords() {
        let data = lsofData([
            "p10", "cevil\np99\nn*:1337", "\n", "f5", "n127.0.0.1:3000", "\n",
        ])
        let listeners = PortScanner.parseListeners(data)
        XCTAssertEqual(listeners.count, 1)
        XCTAssertEqual(listeners[0].pid, 10)
        XCTAssertEqual(listeners[0].port, 3000)
        XCTAssertFalse(listeners.contains { $0.port == 1337 })
    }

    func testIPv6AndWildcardAddresses() {
        let data = lsofData([
            "p1", "cnode", "n[::1]:5432", "p2", "cgo", "n*:8080",
        ])
        let listeners = PortScanner.parseListeners(data)
        XCTAssertEqual(listeners.map(\.port), [5432, 8080])
    }

    func testMalformedFieldsAreSkipped() {
        let data = lsofData([
            "p1", "cnode",
            "nno-colon-here",     // no port
            "n*:99999",           // out of range
            "n*:0",               // out of range
            "n*:abc",             // not a number
            "n*:443",             // valid
        ])
        let listeners = PortScanner.parseListeners(data)
        XCTAssertEqual(listeners.map(\.port), [443])
    }

    func testNameResetsBetweenProcessSets() {
        // Second process has no c field — must not inherit "node".
        let data = lsofData(["p1", "cnode", "n*:3000", "p2", "n*:4000"])
        let listeners = PortScanner.parseListeners(data)
        XCTAssertEqual(listeners[0].name, "node")
        XCTAssertEqual(listeners[1].name, "")
    }

    func testEmptyAndGarbageInput() {
        XCTAssertTrue(PortScanner.parseListeners(Data()).isEmpty)
        XCTAssertTrue(PortScanner.parseListeners(Data([0, 0, 0x0A, 0])).isEmpty)
    }

    func testParsePidsOnly() {
        let data = lsofData(["p10", "cx", "n*:1", "\n", "p20", "n*:2"])
        XCTAssertEqual(PortScanner.parsePidsOnly(data), [10, 20])
    }

    func testEphemeralFloorIsSane() {
        XCTAssertGreaterThanOrEqual(PortScanner.ephemeralFloor, 1024)
        XCTAssertLessThanOrEqual(PortScanner.ephemeralFloor, 65535)
    }

    // MARK: - Admission policy

    func testOrdinaryListenersAreAdmitted() {
        XCTAssertTrue(PortScanner.shouldInclude(
            port: 3000, processName: "node", pgid: 10,
            exemptPorts: [], managedPgids: []
        ))
    }

    func testEphemeralPortsAreDroppedUnlessExempt() {
        XCTAssertFalse(PortScanner.shouldInclude(
            port: 55000, processName: "node", pgid: 10,
            exemptPorts: [], managedPgids: []
        ))
        XCTAssertTrue(PortScanner.shouldInclude(
            port: 55000, processName: "node", pgid: 10,
            exemptPorts: [55000], managedPgids: []
        ))
    }

    func testExemptPortNeverBypassesTheDenylist() {
        // Regression: a saved Flask server on port 5000 must NOT re-admit
        // ControlCenter (AirPlay) — its row could then claim and kill it.
        XCTAssertFalse(PortScanner.shouldInclude(
            port: 5000, processName: "ControlCenter", pgid: 10,
            exemptPorts: [5000], managedPgids: []
        ))
        XCTAssertFalse(PortScanner.shouldInclude(
            port: 7000, processName: "ControlCe", pgid: 10,
            exemptPorts: [7000], managedPgids: []
        ))
    }

    func testManagedRunsBypassEverything() {
        // Our own child is always visible, whatever it's called or wherever
        // its port drifted.
        XCTAssertTrue(PortScanner.shouldInclude(
            port: 55000, processName: "Figma", pgid: 42,
            exemptPorts: [], managedPgids: [42]
        ))
    }
}

// MARK: - App-internal listeners

final class AppInternalTests: XCTestCase {
    func testKnownPlumbingIsHidden() {
        // The cases that motivated the rule.
        XCTAssertTrue(PortScanner.isAppInternal(
            executable: "/Applications/Warp.app/Contents/MacOS/stable"))
        XCTAssertTrue(PortScanner.isAppInternal(
            executable: "/Users/x/Library/Developer/Xcode/DerivedData/A/B/PackageTests.xctest/C"))
        XCTAssertTrue(PortScanner.deniedByName("xctest"))
        XCTAssertTrue(PortScanner.isAppInternal(
            executable: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"))
        XCTAssertTrue(PortScanner.isAppInternal(
            executable: "/System/Library/CoreServices/something"))
        XCTAssertTrue(PortScanner.isAppInternal(executable: "/usr/libexec/some-daemon"))
    }

    /// Regressions the release audit caught: these are all real dev servers
    /// that a blanket ".app" or "/Library" rule hid.
    func testRealServersInsideBundlesAndLibraryAreVisible() {
        // Every framework-build Python rewrites argv[0] to its Python.app stub.
        XCTAssertFalse(PortScanner.isAppInternal(
            executable: "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"))
        XCTAssertFalse(PortScanner.isAppInternal(
            executable: "/opt/homebrew/Cellar/python@3.12/3.12.4/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"))
        // .pkg JDKs, as IntelliJ / Gradle / Maven exec them.
        XCTAssertFalse(PortScanner.isAppInternal(
            executable: "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/bin/java"))
        // Apps whose purpose is the ports they hold.
        XCTAssertFalse(PortScanner.isAppInternal(
            executable: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"))
        XCTAssertFalse(PortScanner.isAppInternal(
            executable: "/Applications/OrbStack.app/Contents/MacOS/OrbStack Helper"))
        XCTAssertFalse(PortScanner.isAppInternal(
            executable: "/Applications/Postgres.app/Contents/Versions/16/bin/postgres"))
        XCTAssertFalse(PortScanner.isAppInternal(
            executable: "/Library/PostgreSQL/16/bin/postgres"))
        // Ordinary interpreters and project binaries.
        XCTAssertFalse(PortScanner.isAppInternal(executable: "/usr/local/bin/node"))
        XCTAssertFalse(PortScanner.isAppInternal(executable: "/opt/homebrew/bin/node"))
        XCTAssertFalse(PortScanner.isAppInternal(
            executable: "/Users/x/.nvm/versions/node/v22.0.0/bin/node"))
        XCTAssertFalse(PortScanner.isAppInternal(executable: "/Users/x/Code/myapp/server"))
        XCTAssertFalse(PortScanner.isAppInternal(executable: nil))
        XCTAssertFalse(PortScanner.isAppInternal(executable: "node"))
    }

    func testHomeDirectoryIsNotUsedAsAServerName() {
        let home = NSHomeDirectory()
        let atHome = DetectedServer(
            pid: 1, port: 9277, pgid: 1, processName: "stable",
            commandLine: nil, cwd: home, adoption: nil)
        XCTAssertEqual(atHome.displayName, "stable",
                       "a server in $HOME must not be named after the user")

        let inProject = DetectedServer(
            pid: 2, port: 3000, pgid: 2, processName: "node",
            commandLine: nil, cwd: home + "/Code/flatland", adoption: nil)
        XCTAssertEqual(inProject.displayName, "flatland")
    }
}
