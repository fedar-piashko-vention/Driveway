import Foundation

/// Builds the AppleScript that runs a bundled shell script with administrator privileges.
public enum PrivilegedShellScript {
    public static func appleScript(scriptPath: String, arguments: [String]) -> String {
        let command = (["/bin/bash", shellQuote(scriptPath)] + arguments.map(shellQuote)).joined(separator: " ")
        return "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
    }

    /// True when osascript's error output says the user canceled the administrator prompt (error -128).
    public static func isUserCanceled(stderr: String) -> Bool {
        stderr.contains("(-128)")
    }

    /// Single-quotes a value for the shell; an embedded single quote becomes `'\''`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Escapes a value for use inside an AppleScript string literal.
    static func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Builds the osascript arguments that open a new Terminal window running a command. The commands come only from
/// `InstallStep` constants; they are still escaped for the AppleScript string literal.
public enum TerminalScript {
    public static func osascriptArguments(command: String) -> [String] {
        let escaped = PrivilegedShellScript.appleScriptEscape(command)
        return [
            "-e", "tell application \"Terminal\" to do script \"\(escaped)\"",
            "-e", "tell application \"Terminal\" to activate",
        ]
    }
}
