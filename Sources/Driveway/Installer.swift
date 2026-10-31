import AppKit
import DrivewayCore
import Foundation
import Observation

enum InstallerError: Error, LocalizedError {
    case notInApplications
    case missingScript(String)
    case couldNotOpen(URL)
    case terminalFailed(command: String, detail: String)
    case brewFailed(Int32)
    /// The user canceled brew or the administrator prompt. Nothing to report.
    case canceled

    var errorDescription: String? {
        switch self {
        case .notInApplications: Copy.moveToApplications
        case .missingScript(let name): "\(name) is missing from Driveway.app. Download Driveway again."
        case .couldNotOpen(let url): "Couldn't open \(url.absoluteString)."
        case .terminalFailed(let command, let detail):
            "Couldn't open Terminal (\(detail)). Run this in Terminal yourself: \(command)"
        case .brewFailed(let status): "Homebrew stopped with exit status \(status). The output above says why."
        case .canceled: "Canceled."
        }
    }
}

/// Carries out the Setup screen's install steps. `brew` runs as the user, with its output streamed to the caller;
/// the helper scripts run as root through the administrator prompt.
@MainActor
@Observable
final class Installer {
    static let applicationsPath = "/Applications/Driveway.app"

    /// The brew run in progress, which Continue and Cancel act on.
    private(set) var isBrewRunning = false
    /// Brew's unfinished last line, typically a question waiting for Continue.
    private(set) var pendingLine = ""

    @ObservationIgnored private let paths: ToolPaths
    @ObservationIgnored private var brew: LineProcess?
    @ObservationIgnored private var canceled = false

    init(paths: ToolPaths = ToolPaths()) {
        self.paths = paths
    }

    func perform(_ step: InstallStep, log: @escaping @MainActor (String) -> Void) async throws {
        switch step {
        case .openURL(let url), .openSettings(let url):
            guard NSWorkspace.shared.open(url) else { throw InstallerError.couldNotOpen(url) }
        case .runBrew(let arguments):
            try await runBrew(arguments, log: log)
        case .runInTerminal(let command):
            try await runInTerminal(command)
        case .installHelper:
            try await runHelperScript("install-helper.sh")
        }
    }

    func uninstallHelper() async throws {
        try await runHelperScript("uninstall-helper.sh")
    }

    /// Answers brew's question (the untrusted-tap prompt) with yes. Driveway never answers it by itself.
    func answerYes() {
        brew?.write("y\n")
    }

    func cancelBrew() {
        guard let brew else { return }
        canceled = true
        brew.terminate()
    }

    // MARK: - Private

    private func runBrew(_ arguments: [String], log: @escaping @MainActor (String) -> Void) async throws {
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        log("$ brew " + arguments.joined(separator: " "))
        let run = try LineProcess(
            executable: paths.brew, arguments: arguments, environment: environment, includeStderr: true,
            pipeStdin: true)
        brew = run
        canceled = false
        isBrewRunning = true
        defer {
            brew = nil
            isBrewRunning = false
            pendingLine = ""
        }
        for await output in run.output {
            switch output {
            case .line(let line): log(line)
            case .tail(let tail): pendingLine = tail
            }
        }
        run.closeInput()
        if canceled { throw InstallerError.canceled }
        guard run.exitStatus == 0 else { throw InstallerError.brewFailed(run.exitStatus) }
    }

    /// Opens a Terminal window running the command: cask installs ask for the user's password there.
    private func runInTerminal(_ command: String) async throws {
        let run = try LineProcess(
            executable: "/usr/bin/osascript", arguments: TerminalScript.osascriptArguments(command: command),
            includeStderr: true)
        var lines: [String] = []
        for await output in run.output {
            if case .line(let line) = output { lines.append(line) }
        }
        guard run.exitStatus == 0 else {
            throw InstallerError.terminalFailed(command: command, detail: lines.joined(separator: " "))
        }
    }

    /// Runs a bundled helper script as root. The scripts only accept the copy in /Applications.
    private func runHelperScript(_ name: String) async throws {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath == Self.applicationsPath else { throw InstallerError.notInApplications }
        guard let resources = Bundle.main.resourcePath else { throw InstallerError.missingScript(name) }
        let script = (resources as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: script) else { throw InstallerError.missingScript(name) }
        do {
            try await PrivilegedShell.run(scriptPath: script, arguments: [bundlePath])
        } catch let error as PrivilegedShellError where PrivilegedShellScript.isUserCanceled(stderr: error.stderr) {
            throw InstallerError.canceled
        }
    }
}
