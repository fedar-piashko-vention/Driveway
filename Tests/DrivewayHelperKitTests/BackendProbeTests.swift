import DrivewayCore
import DrivewayHelperKit
import Foundation
import Testing

private let bputil = "3rd Party Kexts Status:      Enabled    (smb2): 1\n"
private let policy = """
    team_id|bundle_id|allowed|developer_name|flags
    3T5GSNBU6W|io.macfuse.filesystems.macfuse.23|1|Benjamin Fleischer|1
    """
private let pluginkit = "     io.macfuse.app.fsmodule.macfuse-local((null))\tX\tY\tZ\n"

private func scripted() -> FakeRunner {
    let r = FakeRunner()
    r.script("/usr/bin/bputil", "-d", exit: 0, stdout: bputil)
    r.script("/usr/bin/sqlite3", "-readonly", exit: 0, stdout: policy)
    r.script("/usr/bin/kmutil", "showloaded", exit: 0, stdout: "")
    r.script("/usr/bin/pluginkit", "-m", exit: 0, stdout: pluginkit)
    return r
}

@Test func backendProbeRunsTheFourTools() async {
    let runner = scripted()
    let probe = BackendProbe(runner: runner)
    let p = await probe.probe()
    #expect(p.kextsAllowed && p.kextApproved && p.fskitEnabled)
    #expect(runner.commands.count == 4)
    for c in [
        cmd("/usr/bin/bputil", "-d"),
        cmd("/usr/bin/sqlite3", "-readonly", "-header", "/var/db/SystemPolicyConfiguration/KextPolicy", "select * from kext_policy;"),
        cmd("/usr/bin/kmutil", "showloaded", "--list-only"),
        cmd("/usr/bin/pluginkit", "-m", "-v", "-p", "com.apple.fskit.fsmodule"),
    ] {
        #expect(runner.commands.contains(c))
    }
}

@Test func backendProbeCachesForSixtySeconds() async {
    let runner = scripted()
    let start = ContinuousClock.now
    let clock = Box(start)
    let probe = BackendProbe(runner: runner, now: { clock.value })
    _ = await probe.probe()
    #expect(runner.commands.count == 4)
    clock.value = start + .seconds(59)
    _ = await probe.probe()
    #expect(runner.commands.count == 4)
    clock.value = start + .seconds(61)
    _ = await probe.probe()
    #expect(runner.commands.count == 8)
}

@Test func backendProbeLoadedKextCountsAsApproved() async {
    let runner = scripted()
    runner.script("/usr/bin/sqlite3", "-readonly", exit: 1, stderr: "unable to open database")
    runner.script("/usr/bin/kmutil", "showloaded", exit: 0, stdout: "io.macfuse.filesystems.macfuse.23 (5.5.0)\n")
    let p = await BackendProbe(runner: runner).probe()
    #expect(p.kextApproved)
}

@Test func backendProbeFailuresCountAsFalse() async {
    let runner = FakeRunner()
    // Non-zero exits, even with output that would otherwise say yes.
    runner.script("/usr/bin/bputil", "-d", exit: 1, stdout: bputil)
    runner.script("/usr/bin/sqlite3", "-readonly", exit: 1, stdout: policy)
    runner.script("/usr/bin/kmutil", "showloaded", exit: 1, stdout: "io.macfuse.filesystems.macfuse.23 (5.5.0)\n")
    runner.script("/usr/bin/pluginkit", "-m", exit: 1, stdout: pluginkit)
    let p = await BackendProbe(runner: runner).probe()
    #expect(!p.kextsAllowed && !p.kextApproved && !p.fskitEnabled)

    // Tools that can't run at all.
    let missing = FakeRunner()
    for (tool, arg) in [("/usr/bin/bputil", "-d"), ("/usr/bin/sqlite3", "-readonly"), ("/usr/bin/kmutil", "showloaded"),
                        ("/usr/bin/pluginkit", "-m")] {
        missing.fail(tool, arg, with: CommandRunnerError.toolMissing(tool))
    }
    let q = await BackendProbe(runner: missing).probe()
    #expect(!q.kextsAllowed && !q.kextApproved && !q.fskitEnabled)
}
