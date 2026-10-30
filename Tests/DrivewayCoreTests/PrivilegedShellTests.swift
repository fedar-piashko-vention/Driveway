import Testing
import Foundation
@testable import DrivewayCore

struct PrivilegedShellTests {
    @Test func appleScriptQuotesEveryArgument() {
        #expect(PrivilegedShellScript.appleScript(scriptPath: "/Applications/Driveway.app/Contents/Resources/install-helper.sh",
                                                  arguments: ["/Applications/Driveway.app"])
            == #"do shell script "/bin/bash '/Applications/Driveway.app/Contents/Resources/install-helper.sh' '/Applications/Driveway.app'" with administrator privileges"#)
        #expect(PrivilegedShellScript.appleScript(scriptPath: "/tmp/a'b.sh", arguments: [#"x"y"#])
            == #"do shell script "/bin/bash '/tmp/a'\\''b.sh' 'x\"y'" with administrator privileges"#)
    }

    @Test func appleScriptEscapesSpacesAndBackslashes() {
        // Spaces stay inside single quotes; a backslash is doubled for the AppleScript string.
        #expect(PrivilegedShellScript.appleScript(scriptPath: "/tmp/s.sh", arguments: [#"/Volumes/My Disk\x"#])
            == #"do shell script "/bin/bash '/tmp/s.sh' '/Volumes/My Disk\\x'" with administrator privileges"#)
    }
}
