import DrivewayCore
import DrivewayHelperKit
import Foundation
import Testing

@Test func processRunnerCapturesOutputAndExitCode() async throws {
    let runner = ProcessCommandRunner()
    let ok = try await runner.run(Command(executable: "/bin/echo", arguments: ["hello world"]))
    #expect(ok == CommandResult(exitCode: 0, stdout: "hello world\n", stderr: ""))

    // argv, never a shell: metacharacters reach the program untouched.
    let literal = try await runner.run(Command(executable: "/bin/echo", arguments: ["$HOME; ls"]))
    #expect(literal.stdout == "$HOME; ls\n")

    let failed = try await runner.run(Command(executable: "/bin/ls", arguments: ["/definitely/not/here"]))
    #expect(failed.exitCode != 0)
    #expect(!failed.stderr.isEmpty)
}

@Test func processRunnerUsesFixedEnvironment() async throws {
    let result = try await ProcessCommandRunner().run(Command(executable: "/usr/bin/env", arguments: []))
    let lines = Set(result.stdout.split(separator: "\n").map(String.init))
    #expect(lines == ["LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
}

@Test func processRunnerDrainsLargeOutputOnBothPipes() async throws {
    // 1 MiB on stdout and a status line on stderr: far more than a pipe buffer holds.
    let result = try await ProcessCommandRunner().run(
        Command(executable: "/bin/dd", arguments: ["if=/dev/zero", "bs=1024", "count=1024"]))
    #expect(result.exitCode == 0)
    #expect(result.stdout.utf8.count == 1024 * 1024)
    #expect(result.stderr.contains("1048576 bytes"))
}

@Test func processRunnerTimesOut() async {
    let runner = ProcessCommandRunner(timeout: .milliseconds(300))
    await #expect(throws: CommandRunnerError.self) {
        _ = try await runner.run(Command(executable: "/bin/sleep", arguments: ["10"]))
    }
}

@Test func processRunnerDefaultTimeoutIsThirtyMinutes() {
    #expect(ProcessCommandRunner().timeout == .seconds(30 * 60))
}

@Test func processRunnerReportsMissingTool() async {
    await #expect(throws: CommandRunnerError.toolMissing("/opt/nowhere/bin/ntfs-3g")) {
        _ = try await ProcessCommandRunner().run(Command(executable: "/opt/nowhere/bin/ntfs-3g", arguments: []))
    }
}
