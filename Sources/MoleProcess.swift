//
//  MoleProcess.swift
//  Burrow
//
//  Capture-style subprocess runner used by small command invocations.
//

import Foundation

struct MoleProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol MoleProcessPort {
    func capture(executable: String,
                 args: [String],
                 stdin: String?,
                 environment: [String: String]?,
                 timeout: TimeInterval) throws -> MoleProcessResult
}

struct SystemMoleProcess: MoleProcessPort {
    func capture(executable: String,
                 args: [String],
                 stdin: String?,
                 environment: [String: String]? = nil,
                 timeout: TimeInterval = 10) throws -> MoleProcessResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        if let environment {
            task.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe {
            task.standardInput = inPipe
        }

        try task.run()

        // Drain stderr concurrently while stdout is read on the caller's
        // thread so neither pipe can fill and block the child process.
        var errData = Data()
        let errQueue = DispatchQueue(label: "dev.caezium.burrow.process.err")
        errQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // Write canned input and close the write end so the child sees EOF.
        // Ignore failures: a child that exits early can make this EPIPE.
        if let inPipe, let stdin, let data = stdin.data(using: .utf8) {
            let handle = inPipe.fileHandleForWriting
            try? handle.write(contentsOf: data)
            try? handle.close()
        }

        let killer = DispatchWorkItem { [weak task] in
            if let task, task.isRunning { task.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()
        errQueue.sync {}

        return MoleProcessResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: task.terminationStatus
        )
    }
}

enum MoleProcess {
    static func capture(executable: String,
                        args: [String],
                        stdin: String? = nil,
                        environment: [String: String]? = nil,
                        timeout: TimeInterval = 10,
                        port: MoleProcessPort = SystemMoleProcess()) throws -> MoleProcessResult {
        try port.capture(
            executable: executable,
            args: args,
            stdin: stdin,
            environment: environment,
            timeout: timeout
        )
    }
}
