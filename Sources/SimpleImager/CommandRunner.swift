import Foundation

struct CommandOutput {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let process = Process()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simple-imager-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw AppError.commandFailed("Не удалось создать файлы вывода служебной команды.")
        }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            try? stdout.close()
            try? stderr.close()
            throw AppError.commandFailed("Не удалось запустить \(executable): \(error.localizedDescription)")
        }

        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        return CommandOutput(
            stdout: (try? Data(contentsOf: stdoutURL)) ?? Data(),
            stderr: (try? Data(contentsOf: stderrURL)) ?? Data(),
            status: process.terminationStatus
        )
    }

    static func requireSuccess(_ executable: String, _ arguments: [String]) throws -> Data {
        let output = try run(executable, arguments)
        guard output.status == 0 else {
            let details = String(data: output.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.commandFailed(details?.isEmpty == false ? details! : "Команда завершилась с кодом \(output.status).")
        }
        return output.stdout
    }
}
