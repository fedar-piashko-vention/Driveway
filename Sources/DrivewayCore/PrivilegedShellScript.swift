import Foundation

/// Builds the AppleScript that runs a bundled shell script with administrator privileges.
public enum PrivilegedShellScript {
    public static func appleScript(scriptPath: String, arguments: [String]) -> String {
        let command = (["/bin/bash", shellQuote(scriptPath)] + arguments.map(shellQuote)).joined(separator: " ")
        return "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
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
