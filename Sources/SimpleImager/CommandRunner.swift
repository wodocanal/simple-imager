import Foundation

struct CommandOutput {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw AppError.commandFailed("Не удалось запустить \(executable): \(error.localizedDescription)")
        }

        process.waitUntilExit()
        return CommandOutput(
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile(),
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
