import Foundation

enum PrivilegedHelperLauncher {
    static func run(arguments: [String]) async throws {
        let rawExecutable = ProcessInfo.processInfo.arguments[0]
        let executable = URL(
            fileURLWithPath: rawExecutable,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ).standardizedFileURL.path
        let command = ([executable, "--helper"] + arguments)
            .map(shellQuote)
            .joined(separator: " ")
        let appleScriptCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(appleScriptCommand)\" with administrator privileges"

        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try CommandRunner.run("/usr/bin/osascript", ["-e", script])
                    guard output.status == 0 else {
                        let message = String(data: output.stderr, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if message?.contains("User canceled") == true || message?.contains("-128") == true {
                            throw AppError.cancelled
                        }
                        throw AppError.helperFailed(message?.isEmpty == false ? message! : "Служебный процесс завершился с ошибкой.")
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
