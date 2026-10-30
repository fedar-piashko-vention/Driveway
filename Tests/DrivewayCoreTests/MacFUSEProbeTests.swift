import DrivewayCore
import Testing

// Samples from docs/spike-results.md.
private let pluginkitEnabled =
    "     io.macfuse.app.fsmodule.macfuse-local((null))\t6F1A2B3C-0000-4000-8000-000000000001\t2026-10-30 15:20:00 +0000\t/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/Extensions/io.macfuse.app.fsmodule.macfuse-local.appex\n"
private let kmutilLoaded = "io.macfuse.filesystems.macfuse.23 (5.5.0)\n"
private let bputilEnabled = """
    Security Mode:               Reduced    (smb0): 1
    3rd Party Kexts Status:      Enabled    (smb2): 1
    SIP Status:                  Enabled    (sip0): absent
    """
private let kextPolicyRows = """
    team_id|bundle_id|allowed|developer_name|flags
    3T5GSNBU6W|io.macfuse.filesystems.macfuse.21|1|Benjamin Fleischer|5
    3T5GSNBU6W|io.macfuse.filesystems.macfuse.23|1|Benjamin Fleischer|1
    PPNVCC9Z68|com.tuxera.filesystems.tuxera_ntfs|1|Tuxera Inc.|1
    """

@Test func pluginkitApproval() {
    #expect(MacFUSEProbe.isApproved(pluginkitOutput: pluginkitEnabled))
    // A "+" marker also means enabled.
    #expect(MacFUSEProbe.isApproved(pluginkitOutput: "+    io.macfuse.app.fsmodule.macfuse-local((null))\tX\n"))
    // A "-" marker means disabled, even after leading spaces.
    #expect(!MacFUSEProbe.isApproved(pluginkitOutput: "-    io.macfuse.app.fsmodule.macfuse-local((null))\tX\n"))
    #expect(!MacFUSEProbe.isApproved(pluginkitOutput: "  -  io.macfuse.app.fsmodule.macfuse-local((null))\tX\n"))
    // Missing line, other modules, empty output.
    #expect(!MacFUSEProbe.isApproved(pluginkitOutput: "     com.example.fsmodule((null))\tX\n"))
    #expect(!MacFUSEProbe.isApproved(pluginkitOutput: ""))
}

@Test func kmutilKextLoaded() {
    #expect(MacFUSEProbe.kextLoaded(kmutilOutput: "com.apple.foo (1.0)\n" + kmutilLoaded))
    #expect(!MacFUSEProbe.kextLoaded(kmutilOutput: "com.apple.foo (1.0)\ncom.tuxera.filesystems.tuxera_ntfs (2024)\n"))
    #expect(!MacFUSEProbe.kextLoaded(kmutilOutput: ""))
}

@Test func bputilKextsAllowed() {
    #expect(MacFUSEProbe.kextsAllowed(bputilOutput: bputilEnabled))
    let disabled = bputilEnabled.replacingOccurrences(of: "Enabled    (smb2)", with: "Disabled   (smb2)")
    #expect(!MacFUSEProbe.kextsAllowed(bputilOutput: disabled))
    // The line is missing (Full Security) or the tool printed an error.
    #expect(!MacFUSEProbe.kextsAllowed(bputilOutput: "Security Mode:               Full       (smb0): absent\n"))
    #expect(!MacFUSEProbe.kextsAllowed(bputilOutput: "The tool requires running as root\n"))
    #expect(!MacFUSEProbe.kextsAllowed(bputilOutput: ""))
}

@Test func kextPolicyApproval() {
    #expect(MacFUSEProbe.kextApproved(kextPolicyRows: kextPolicyRows))
    // allowed = 0.
    #expect(!MacFUSEProbe.kextApproved(kextPolicyRows: """
        team_id|bundle_id|allowed|developer_name|flags
        3T5GSNBU6W|io.macfuse.filesystems.macfuse.23|0|Benjamin Fleischer|1
        """))
    // Another team using macFUSE's bundle id.
    #expect(!MacFUSEProbe.kextApproved(kextPolicyRows: """
        team_id|bundle_id|allowed|developer_name|flags
        ABCDE12345|io.macfuse.filesystems.macfuse.23|1|Someone Else|1
        """))
    // Only other kexts, only the header, nothing.
    #expect(!MacFUSEProbe.kextApproved(kextPolicyRows: """
        team_id|bundle_id|allowed|developer_name|flags
        PPNVCC9Z68|com.tuxera.filesystems.tuxera_ntfs|1|Tuxera Inc.|1
        """))
    #expect(!MacFUSEProbe.kextApproved(kextPolicyRows: "team_id|bundle_id|allowed|developer_name|flags\n"))
    #expect(!MacFUSEProbe.kextApproved(kextPolicyRows: ""))
    // Columns in another order are found by the header.
    #expect(MacFUSEProbe.kextApproved(kextPolicyRows: """
        bundle_id|allowed|team_id
        io.macfuse.filesystems.macfuse.24|1|3T5GSNBU6W
        """))
}
