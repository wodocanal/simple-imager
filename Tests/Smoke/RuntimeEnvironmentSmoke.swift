import Foundation

@main
enum RuntimeEnvironmentSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeError.failed("Pass the path to Simple Imager.app")
        }

        let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let report = RuntimeEnvironment.audit(bundleURL: bundleURL)
        for check in report.checks {
            print("[" + check.state.rawValue + "] " + check.title + ": " + check.detail)
        }
        guard report.isReady else {
            throw SmokeError.failed("Runtime readiness check failed")
        }
    }
}

private enum SmokeError: Error {
    case failed(String)
}
