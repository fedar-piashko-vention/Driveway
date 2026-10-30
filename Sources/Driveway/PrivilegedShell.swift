import Foundation
import DrivewayCore

struct PrivilegedShellError: Error, LocalizedError {
    let status: Int32
    let stderr: String
    var errorDescription: String? {
        stderr.isEmpty ? "Privileged command failed (exit \(status))." : stderr
    }
}

enum PrivilegedShell {
    /// Runs a script as root through the standard macOS administrator prompt.
    static func run(scriptPath: String, arguments: [String]) async throws {
        let script = PrivilegedShellScript.appleScript(scriptPath: scriptPath, arguments: arguments)
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw PrivilegedShellError(status: process.terminationStatus, stderr: text)
            }
        }.value
    }
}
