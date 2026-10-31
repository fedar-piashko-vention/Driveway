import DrivewayCore
import Foundation
import Synchronization

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(_ c: Command) async throws -> CommandResult
    /// Like `run(_:)`, and also hands each line of stdout to `onOutputLine` as it arrives (lines end in a newline
    /// or a carriage return). The result still carries the whole output.
    func run(_ c: Command, onOutputLine: @escaping @Sendable (String) -> Void) async throws -> CommandResult
}

extension CommandRunning {
    /// Runners that can't stream hand over no lines.
    public func run(_ c: Command, onOutputLine: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        try await run(c)
    }
}

public enum CommandRunnerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The executable does not exist or is not executable (usually a Homebrew tool that isn't installed).
    case toolMissing(String)
    case launchFailed(String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .toolMissing(let path): "\(path) is not installed."
        case .launchFailed(let message): "Couldn't start the tool: \(message)"
        case .timedOut(let path): "\(path) took too long and was stopped."
        }
    }
}

/// Runs a command with `Process`: argv only (never a shell), a fixed environment, stdin from /dev/null,
/// stdout and stderr drained concurrently, and an optional timeout after which the tool is stopped.
public struct ProcessCommandRunner: CommandRunning {
    /// mkntfs converts labels through the locale, so it must be UTF-8. PATH is fixed so tools that
    /// spawn helpers can't pick up anything from the caller's environment.
    public static let environment = [
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]

    /// Nil runs the tool for as long as it takes: check, repair, backup and format of a large drive can take hours.
    public var timeout: Duration?
    /// How long to keep reading output after the tool exits. A tool that daemonises (ntfs-3g) may leave a
    /// child holding the pipe open; this keeps that from hanging the helper.
    var drainGrace: Duration = .seconds(5)

    public init(timeout: Duration? = .seconds(30 * 60)) {
        self.timeout = timeout
    }

    public func run(_ c: Command) async throws -> CommandResult {
        try await run(c, lines: nil)
    }

    public func run(_ c: Command, onOutputLine: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        try await run(c, lines: onOutputLine)
    }

    private func run(_ c: Command, lines: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        guard c.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: c.executable) else {
            throw CommandRunnerError.toolMissing(c.executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: c.executable)
        process.arguments = c.arguments
        process.environment = Self.environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let stdout = PipeCollector(outPipe.fileHandleForReading, lines: lines)
        let stderr = PipeCollector(errPipe.fileHandleForReading)
        let exited = OneShot()
        process.terminationHandler = { _ in exited.fire() }

        do {
            try process.run()
        } catch {
            stdout.finish()
            stderr.finish()
            throw CommandRunnerError.launchFailed("\(c.executable): \(error.localizedDescription)")
        }

        let pid = process.processIdentifier
        let timedOut = Mutex(false)
        let timeout = self.timeout
        let watchdog = Task {
            guard let timeout, (try? await Task.sleep(for: timeout)) != nil, !exited.isFired else { return }
            timedOut.withLock { $0 = true }
            kill(pid, SIGTERM)
            guard (try? await Task.sleep(for: .seconds(10))) != nil, !exited.isFired else { return }
            kill(pid, SIGKILL)
        }
        await exited.wait()
        watchdog.cancel()

        let outData = await stdout.collect(grace: drainGrace)
        let errData = await stderr.collect(grace: drainGrace)
        if timedOut.withLock({ $0 }) { throw CommandRunnerError.timedOut(c.executable) }
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}

/// A one-time signal that any number of tasks can wait for.
final class OneShot: Sendable {
    private let state = Mutex<(fired: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    var isFired: Bool { state.withLock { $0.fired } }

    func fire() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            if s.fired { return [] }
            s.fired = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for w in waiters { w.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let firedAlready = state.withLock { s -> Bool in
                if s.fired { return true }
                s.waiters.append(c)
                return false
            }
            if firedAlready { c.resume() }
        }
    }
}

/// Reads a pipe as data arrives, so a tool writing a lot to both stdout and stderr can't block. With `lines`, each
/// line is also handed over as soon as it is complete.
final class PipeCollector: Sendable {
    private let handle: FileHandle
    private let data = Mutex(Data())
    private let eof = OneShot()
    private let splitter = Mutex(OutputLineSplitter())

    init(_ handle: FileHandle, lines: (@Sendable (String) -> Void)? = nil) {
        self.handle = handle
        // The handler keeps the collector alive until end of file or `finish()`. It runs on a serial queue, so lines
        // arrive in order.
        handle.readabilityHandler = { [self] h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                if let lines, let last = splitter.withLock({ $0.finish() }) { lines(last) }
                eof.fire()
            } else {
                data.withLock { $0.append(chunk) }
                if let lines {
                    for line in splitter.withLock({ $0.lines(in: chunk) }) { lines(line) }
                }
            }
        }
    }

    /// Stops reading.
    func finish() {
        handle.readabilityHandler = nil
        eof.fire()
    }

    /// Waits for end of file, but no longer than `grace`, then returns what was read.
    func collect(grace: Duration) async -> Data {
        let deadline = Task { [self] in
            guard (try? await Task.sleep(for: grace)) != nil else { return }
            finish()
        }
        await eof.wait()
        deadline.cancel()
        return data.withLock { $0 }
    }
}
