import Darwin
import Foundation

struct BackendProcessResult: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
}

/// Both pipes drain independently, even after the capture limit is reached.
enum BackendProcess {
    static func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval = 300) async throws -> BackendProcessResult {
        let state = RunningProcess()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try state.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout) })
                }
            }
        } onCancel: { state.cancel() }
    }
}

private final class BoundedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    func drain(_ handle: FileHandle) {
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            lock.lock()
            let remaining = max(0, 8 * 1024 * 1024 - bytes.count)
            bytes.append(data.prefix(remaining))
            overflow = overflow || data.count > remaining
            lock.unlock()
        }
        try? handle.close()
    }
    func result() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { throw ConversionBackendError.invalidResponse("백엔드 출력이 안전 한도를 초과했습니다.") }
        return bytes
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        stop(running)
    }

    private func timeout() {
        lock.lock()
        timedOut = true
        cancelled = true
        let running = process
        lock.unlock()
        stop(running)
    }

    private func stop(_ running: Process?) {
        guard let running, running.isRunning else { return }
        let pid = running.processIdentifier
        // Foundation starts a separate group on macOS. Verify ownership before signalling descendants.
        let signalTarget = getpgid(pid) == pid ? -pid : pid
        // The .NET CLI handles SIGINT by cancelling its queue and engine subprocesses.
        kill(signalTarget, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if signalTarget < 0 || running.isRunning { kill(signalTarget, SIGTERM) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            if signalTarget < 0 || running.isRunning { kill(signalTarget, SIGKILL) }
        }
    }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> BackendProcessResult {
        let task = Process()
        let output = Pipe(), errors = Pipe()
        task.executableURL = executable
        task.arguments = arguments
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = errors
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try task.run() } catch { lock.unlock(); throw error }
        process = task
        lock.unlock()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let stdout = BoundedCapture(), stderr = BoundedCapture(), readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async { stdout.drain(output.fileHandleForReading); readers.leave() }
        readers.enter()
        DispatchQueue.global().async { stderr.drain(errors.fileHandleForReading); readers.leave() }
        let deadline = DispatchWorkItem { self.timeout() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        task.waitUntilExit()
        deadline.cancel()
        readers.wait()
        lock.lock()
        let wasCancelled = cancelled
        let exceededDeadline = timedOut
        process = nil
        lock.unlock()
        if exceededDeadline { throw ConversionBackendError.timedOut }
        if wasCancelled { throw CancellationError() }
        return BackendProcessResult(status: task.terminationStatus, standardOutput: try stdout.result(), standardError: try stderr.result())
    }
}
